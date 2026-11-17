BEGIN;

-- Keep ordinary users confined to assigned classes. Explicit operators and
-- report staff keep the global attendance scope granted in their profiles.
CREATE FUNCTION private.attendance_is_admin()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = (SELECT auth.uid()) AND p.approved
      AND p.role = 'admin' AND (SELECT auth.jwt() ->> 'aal') = 'aal2'
  );
$$;

CREATE FUNCTION private.attendance_global_permission(permission_id text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = (SELECT auth.uid()) AND p.approved AND p.role <> 'admin'
      AND jsonb_typeof(p.permissions -> 'allowed') = 'array'
      AND (p.permissions -> 'allowed') ? permission_id
  );
$$;

CREATE OR REPLACE FUNCTION private.attendance_can_read_class(target_class_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    JOIN public.bes_extra_classes c ON c.id = target_class_id
    WHERE p.id = (SELECT auth.uid()) AND p.approved
      AND (
        (p.role = 'admin' AND (SELECT auth.jwt() ->> 'aal') = 'aal2')
        OR (p.role <> 'admin' AND (
          private.attendance_global_permission('attendance:quick')
          OR private.attendance_global_permission('attendance:report')
          OR c.teacher_id = p.id
          OR (c.teacher_id IS NULL AND lower(nullif(btrim(c.teacher_email), '')) = lower(btrim(p.email)))
          OR EXISTS (
            SELECT 1 FROM public.bes_extra_class_teachers t
            WHERE t.class_id = c.id
              AND (t.teacher_id = p.id
                OR (t.teacher_id IS NULL AND lower(nullif(btrim(t.teacher_email), '')) = lower(btrim(p.email))))
          )
        ))
      )
  );
$$;

CREATE FUNCTION private.attendance_can_write()
RETURNS boolean LANGUAGE sql STABLE SET search_path = ''
AS $$
  SELECT private.attendance_is_admin()
    OR private.attendance_global_permission('attendance:quick')
    OR private.attendance_global_permission('attendance:report');
$$;

CREATE FUNCTION private.bes_attendance_access_decision(class_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  settings public.bes_attendance_access_settings%rowtype;
  local_time time := (clock_timestamp() AT TIME ZONE 'Asia/Ho_Chi_Minh')::time;
  in_window boolean;
BEGIN
  IF NOT private.attendance_can_write()
    OR NOT EXISTS (SELECT 1 FROM public.bes_extra_classes c WHERE c.id = class_id AND c.active)
  THEN
    RETURN jsonb_build_object('allowed', false, 'reason', 'missing_permission');
  END IF;
  IF private.attendance_is_admin() OR private.attendance_global_permission('attendance:report') THEN
    RETURN jsonb_build_object('allowed', true, 'reason', 'privileged', 'bypass', true);
  END IF;
  SELECT * INTO settings FROM public.bes_attendance_access_settings WHERE id = 1;
  IF settings.enforce_teacher_time_window IS NOT TRUE THEN
    RETURN jsonb_build_object('allowed', true, 'reason', 'restriction_disabled', 'bypass', false);
  END IF;
  IF settings.teacher_start_time = settings.teacher_end_time THEN
    RETURN jsonb_build_object('allowed', false, 'reason', 'invalid_time');
  ELSIF settings.teacher_start_time < settings.teacher_end_time THEN
    in_window := local_time BETWEEN settings.teacher_start_time AND settings.teacher_end_time;
  ELSE
    in_window := local_time >= settings.teacher_start_time OR local_time <= settings.teacher_end_time;
  END IF;
  RETURN jsonb_build_object('allowed', coalesce(in_window, false),
    'reason', CASE WHEN in_window THEN 'within_window' ELSE 'outside_time' END,
    'window_start', to_char(settings.teacher_start_time, 'HH24:MI'),
    'window_end', to_char(settings.teacher_end_time, 'HH24:MI'));
END;
$$;

CREATE TABLE public.bes_attendance_global_settings (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  allow_teacher_period_selection boolean NOT NULL DEFAULT false,
  updated_by text NOT NULL DEFAULT '',
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.bes_attendance_global_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL PRIVILEGES ON public.bes_attendance_global_settings FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE ON public.bes_attendance_global_settings TO authenticated;
CREATE POLICY attendance_period_policy_read ON public.bes_attendance_global_settings
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = (SELECT auth.uid()) AND p.approved));
CREATE POLICY attendance_period_policy_insert ON public.bes_attendance_global_settings
  FOR INSERT TO authenticated WITH CHECK ((SELECT private.attendance_is_admin()));
CREATE POLICY attendance_period_policy_update ON public.bes_attendance_global_settings
  FOR UPDATE TO authenticated USING ((SELECT private.attendance_is_admin()))
  WITH CHECK ((SELECT private.attendance_is_admin()));
INSERT INTO public.bes_attendance_global_settings (id) VALUES (true);

CREATE FUNCTION private.attendance_can_stage_proof(object_name text)
RETURNS boolean LANGUAGE sql STABLE SET search_path = ''
AS $$
  SELECT private.attendance_can_write() AND EXISTS (
    SELECT 1 FROM public.bes_extra_attendance_sessions s
    WHERE s.checked_by = (SELECT auth.uid()) AND s.session_status = 'completed'
      AND s.proof_path IS NULL
      AND object_name ~ ('^' || s.id::text || '/[0-9]+-attendance-proof[.]jpg$')
  );
$$;
CREATE POLICY attendance_write_own_session_proof ON storage.objects
  FOR INSERT TO authenticated WITH CHECK (
    bucket_id = 'attendance-session-proofs' AND private.attendance_can_stage_proof(name)
  );
CREATE POLICY attendance_read_own_unattached_proof ON storage.objects
  FOR SELECT TO authenticated USING (
    bucket_id = 'attendance-session-proofs' AND owner_id = (SELECT auth.uid())::text
    AND private.attendance_can_stage_proof(name)
  );
CREATE POLICY attendance_remove_own_unattached_proof ON storage.objects
  FOR DELETE TO authenticated USING (
    bucket_id = 'attendance-session-proofs' AND owner_id = (SELECT auth.uid())::text
    AND private.attendance_can_stage_proof(name)
  );


CREATE OR REPLACE FUNCTION private.bes_attendance_settings_snapshot()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_profile public.profiles%rowtype;
  v_enabled boolean := false;
  v_start time without time zone := time '16:40';
  v_end time without time zone := time '17:15';
  v_is_admin boolean := false;
  v_has_report boolean := false;
begin
  if v_uid is null then
    raise exception 'Bạn chưa đăng nhập.' using errcode = '42501';
  end if;

  select *
  into v_profile
  from public.profiles p
  where p.id = v_uid
    and p.approved = true;

  if not found then
    raise exception 'Bạn không có quyền truy cập phân hệ điểm danh.' using errcode = '42501';
  end if;

  select
    coalesce(s.enforce_teacher_time_window, false),
    s.teacher_start_time,
    s.teacher_end_time
  into v_enabled, v_start, v_end
  from public.bes_attendance_access_settings s
  where s.id = 1;

  v_start := coalesce(v_start, time '16:40');
  v_end := coalesce(v_end, time '17:15');
  v_is_admin := private.attendance_is_admin();
  v_has_report := private.attendance_global_permission('attendance:report');

  return jsonb_build_object(
    'enforce_teacher_time_window', coalesce(v_enabled, false),
    'teacher_start_time', to_char(v_start, 'HH24:MI'),
    'teacher_end_time', to_char(v_end, 'HH24:MI'),
    'can_administer', v_is_admin,
    'bypass_time_window', v_is_admin or v_has_report,
    'server_now', clock_timestamp(),
    'time_zone', 'Asia/Ho_Chi_Minh'
  );
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_extra_attendance_edit_decision(p_session_id uuid, p_now timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_profile public.profiles%rowtype;
  v_session public.bes_extra_attendance_sessions%rowtype;
  v_now timestamptz := coalesce(p_now, clock_timestamp());
  v_expires_at timestamptz;
  v_is_admin boolean := false;
  v_has_report boolean := false;
  v_remaining_seconds integer := 0;
begin
  if v_uid is null then
    return jsonb_build_object('allowed', false, 'reason', 'not_authenticated');
  end if;

  select * into v_profile
  from public.profiles p
  where p.id = v_uid
    and p.approved = true;

  if not found then
    return jsonb_build_object('allowed', false, 'reason', 'profile_not_approved');
  end if;

  select * into v_session
  from public.bes_extra_attendance_sessions s
  where s.id = p_session_id;

  if not found or not private.attendance_can_read_class(v_session.class_id) then
    return jsonb_build_object('allowed', false, 'reason', 'session_not_found');
  end if;

  if v_session.session_status <> 'completed' then
    return jsonb_build_object(
      'allowed', false,
      'reason', 'not_completed',
      'session_id', v_session.id,
      'server_now', v_now
    );
  end if;

  if v_session.checked_at is null then
    return jsonb_build_object(
      'allowed', false,
      'reason', 'invalid_checked_at',
      'session_id', v_session.id,
      'server_now', v_now
    );
  end if;

  v_expires_at := v_session.checked_at + interval '30 minutes';
  v_remaining_seconds := greatest(0, floor(extract(epoch from (v_expires_at - v_now)))::integer);
  v_is_admin := private.attendance_is_admin();
  v_has_report := private.attendance_global_permission('attendance:report');

  if v_is_admin then
    return jsonb_build_object(
      'allowed', true,
      'reason', 'admin_bypass',
      'bypass', true,
      'session_id', v_session.id,
      'checked_at', v_session.checked_at,
      'expires_at', v_expires_at,
      'remaining_seconds', v_remaining_seconds,
      'server_now', v_now
    );
  end if;

  if v_has_report then
    return jsonb_build_object(
      'allowed', true,
      'reason', 'report_bypass',
      'bypass', true,
      'session_id', v_session.id,
      'checked_at', v_session.checked_at,
      'expires_at', v_expires_at,
      'remaining_seconds', v_remaining_seconds,
      'server_now', v_now
    );
  end if;

  if not private.attendance_global_permission('attendance:quick') then
    return jsonb_build_object(
      'allowed', false,
      'reason', 'missing_permission',
      'session_id', v_session.id,
      'expires_at', v_expires_at,
      'remaining_seconds', v_remaining_seconds,
      'server_now', v_now
    );
  end if;

  if v_now > v_expires_at then
    return jsonb_build_object(
      'allowed', false,
      'reason', 'edit_window_expired',
      'session_id', v_session.id,
      'checked_at', v_session.checked_at,
      'expires_at', v_expires_at,
      'remaining_seconds', 0,
      'server_now', v_now
    );
  end if;

  return jsonb_build_object(
    'allowed', true,
    'reason', 'within_edit_window',
    'bypass', false,
    'session_id', v_session.id,
    'checked_at', v_session.checked_at,
    'expires_at', v_expires_at,
    'remaining_seconds', v_remaining_seconds,
    'server_now', v_now
  );
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_confirm_extra_class_attendance(p_class_id uuid, p_attendance_date date, p_teacher_name text, p_lesson_periods numeric, p_absence_details jsonb, p_note text, p_teaching_room text, p_teaching_time_range text, p_late_member_keys text[] DEFAULT '{}'::text[])
 RETURNS public.bes_extra_attendance_sessions
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_class public.bes_extra_classes%rowtype;
  v_session public.bes_extra_attendance_sessions%rowtype;
  v_teacher_conflict public.bes_extra_attendance_sessions%rowtype;
  v_checked_at timestamptz := clock_timestamp();
  v_today date := (clock_timestamp() at time zone 'Asia/Ho_Chi_Minh')::date;
  v_teacher_name text := trim(coalesce(p_teacher_name, ''));
  v_checked_by_name text := '';
  v_room text := trim(coalesce(p_teaching_room, ''));
  v_time text := trim(coalesce(p_teaching_time_range, ''));
  v_details jsonb := coalesce(p_absence_details, '[]'::jsonb);
  v_absent_keys text[] := '{}'::text[];
  v_late_keys text[] := '{}'::text[];
  v_total integer := 0;
  v_absent integer := 0;
  v_unknown integer := 0;
  v_detail_count integer := 0;
  v_distinct_count integer := 0;
  v_late_input_count integer := 0;
  v_late_distinct_count integer := 0;
begin
  if not coalesce((private.bes_attendance_access_decision(p_class_id) ->> 'allowed')::boolean, false) then
    raise exception 'Bạn không có quyền điểm danh lớp phụ đạo/bồi dưỡng.' using errcode = '42501';
  end if;

  select coalesce(nullif(trim(p.full_name), ''), nullif(trim(p.email), ''), auth.uid()::text, '')
    into v_checked_by_name
  from public.profiles p
  where p.id = auth.uid()
    and p.approved = true;
  v_checked_by_name := coalesce(v_checked_by_name, auth.uid()::text, '');

  if p_attendance_date is null then
    raise exception 'Vui lòng chọn ngày điểm danh.' using errcode = '22004';
  end if;
  if p_attendance_date > v_today then
    raise exception 'Không thể điểm danh cho ngày tương lai theo giờ Việt Nam.' using errcode = '22008';
  end if;
  if v_teacher_name = '' then
    raise exception 'Vui lòng chọn giáo viên dạy hôm nay.' using errcode = '22023';
  end if;
  if p_lesson_periods is null or p_lesson_periods not in (1, 1.5, 2) then
    raise exception 'Số tiết phải là 1, 1,5 hoặc 2.' using errcode = '22023';
  end if;
  if v_room = '' then
    raise exception 'Vui lòng nhập phòng học.' using errcode = '22023';
  end if;
  if v_time = '' then
    raise exception 'Vui lòng nhập thời gian dạy.' using errcode = '22023';
  end if;
  if jsonb_typeof(v_details) <> 'array' then
    raise exception 'Dữ liệu lý do vắng không hợp lệ.' using errcode = '22023';
  end if;

  select * into v_class
  from public.bes_extra_classes
  where id = p_class_id
    and active = true
  for update;
  if not found then
    raise exception 'Không tìm thấy lớp phụ đạo/bồi dưỡng đang hoạt động.' using errcode = 'P0002';
  end if;

  if not private.attendance_is_admin()
    and not coalesce((select allow_teacher_period_selection from public.bes_attendance_global_settings where id), false)
    and p_lesson_periods <> (case when v_class.class_type = 'gifted' then 2 else 1.5 end)
  then
    raise exception 'Số tiết phải đúng với loại lớp đang điểm danh.' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.bes_extra_class_teachers t
    where t.class_id = p_class_id
      and lower(trim(t.teacher_name)) = lower(v_teacher_name)
  ) and not exists (
    select 1
    from regexp_split_to_table(coalesce(v_class.teacher_name, ''), '\s*,\s*') as fallback_teacher(name)
    where lower(trim(fallback_teacher.name)) = lower(v_teacher_name)
  ) then
    raise exception 'Giáo viên không thuộc phân công của lớp.' using errcode = '22023';
  end if;

  select s.* into v_teacher_conflict
  from public.bes_extra_attendance_sessions s
  where s.attendance_date = p_attendance_date
    and s.session_status = 'completed'
    and lower(trim(s.teacher_name)) = lower(v_teacher_name)
    and s.class_id <> p_class_id
  order by s.checked_at asc
  limit 1;
  if found then
    raise exception 'Giáo viên % đã được điểm danh tại lớp % ngày %.',
      v_teacher_name, v_teacher_conflict.class_name, to_char(p_attendance_date, 'DD/MM/YYYY')
      using errcode = '23505';
  end if;

  if exists (
    select 1 from public.bes_extra_attendance_sessions s
    where s.class_id = p_class_id and s.attendance_date = p_attendance_date
  ) then
    raise exception 'Lớp này đã được xử lý điểm danh ngày %.', to_char(p_attendance_date, 'DD/MM/YYYY') using errcode = '23505';
  end if;

  select count(*), count(distinct trim(x.member_key))
    into v_detail_count, v_distinct_count
  from jsonb_to_recordset(v_details) as x(member_key text, reason_code text, note text);
  if v_detail_count <> v_distinct_count then
    raise exception 'Danh sách vắng có học sinh bị lặp.' using errcode = '22023';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(v_details) as x(member_key text, reason_code text, note text)
    where trim(coalesce(x.member_key, '')) = ''
      or trim(coalesce(x.reason_code, '')) not in ('excused', 'unexcused', 'sick', 'family', 'other')
      or (trim(coalesce(x.reason_code, '')) = 'other' and trim(coalesce(x.note, '')) = '')
  ) then
    raise exception 'Mỗi học sinh vắng phải có lý do hợp lệ; lý do Khác phải có ghi chú.' using errcode = '22023';
  end if;

  select count(*)::integer into v_unknown
  from jsonb_to_recordset(v_details) as x(member_key text, reason_code text, note text)
  where not exists (
    select 1 from public.bes_extra_class_members m
    where m.class_id = p_class_id and m.active = true and m.member_key = trim(x.member_key)
  );
  if v_unknown > 0 then
    raise exception 'Danh sách vắng có học sinh không còn thuộc lớp. Hãy tải lại danh sách trước khi điểm danh.' using errcode = '40001';
  end if;

  select coalesce(array_agg(trim(x.member_key)), '{}'::text[])
    into v_absent_keys
  from jsonb_to_recordset(v_details) as x(member_key text, reason_code text, note text);

  select count(*)::integer, count(distinct trim(k))::integer
    into v_late_input_count, v_late_distinct_count
  from unnest(coalesce(p_late_member_keys, '{}'::text[])) as late(k)
  where trim(coalesce(k, '')) <> '';

  if v_late_input_count <> v_late_distinct_count then
    raise exception 'Danh sách đi trễ có học sinh bị lặp.' using errcode = '22023';
  end if;

  select coalesce(array_agg(trim(k)), '{}'::text[])
    into v_late_keys
  from unnest(coalesce(p_late_member_keys, '{}'::text[])) as late(k)
  where trim(coalesce(k, '')) <> '';

  if exists (
    select 1 from unnest(v_late_keys) as late(member_key)
    where late.member_key = any(v_absent_keys)
  ) then
    raise exception 'Một học sinh không thể đồng thời Đi trễ và Vắng.' using errcode = '22023';
  end if;

  select count(*)::integer into v_unknown
  from unnest(v_late_keys) as late(member_key)
  where not exists (
    select 1 from public.bes_extra_class_members m
    where m.class_id = p_class_id and m.active = true and m.member_key = late.member_key
  );
  if v_unknown > 0 then
    raise exception 'Danh sách đi trễ có học sinh không còn thuộc lớp. Hãy tải lại danh sách trước khi điểm danh.' using errcode = '40001';
  end if;

  select count(*)::integer into v_total
  from public.bes_extra_class_members m
  where m.class_id = p_class_id and m.active = true;
  v_absent := coalesce(array_length(v_absent_keys, 1), 0);

  begin
    insert into public.bes_extra_attendance_sessions (
      class_id, class_type, class_name, subject,
      teacher_id, teacher_name, teacher_email,
      attendance_date, checked_at, checked_by, checked_by_name,
      total_students, present_count, absent_count,
      note, session_status, lesson_periods, cancellation_reason,
      teaching_room, teaching_time_range
    ) values (
      v_class.id, v_class.class_type, v_class.class_name, v_class.subject,
      null, v_teacher_name, '',
      p_attendance_date, v_checked_at, auth.uid(), v_checked_by_name,
      v_total, v_total - v_absent, v_absent,
      coalesce(trim(p_note), ''), 'completed', p_lesson_periods, '',
      v_room, v_time
    ) returning * into v_session;
  exception when unique_violation then
    select s.* into v_teacher_conflict
    from public.bes_extra_attendance_sessions s
    where s.attendance_date = p_attendance_date
      and s.session_status = 'completed'
      and lower(trim(s.teacher_name)) = lower(v_teacher_name)
      and s.class_id <> p_class_id
    order by s.checked_at asc limit 1;
    if found then
      raise exception 'Giáo viên % đã được điểm danh tại lớp % ngày %.',
        v_teacher_name, v_teacher_conflict.class_name, to_char(p_attendance_date, 'DD/MM/YYYY')
        using errcode = '23505';
    end if;
    raise exception 'Lớp này đã được xử lý điểm danh ngày %.', to_char(p_attendance_date, 'DD/MM/YYYY') using errcode = '23505';
  end;

  insert into public.bes_extra_attendance_records (
    session_id, class_id, member_id, member_key,
    student_code, student_full_name, school_class_name,
    status, recorded_at, absence_reason_code, absence_note
  )
  select
    v_session.id, m.class_id, m.id, m.member_key,
    m.student_code, m.student_full_name, m.school_class_name,
    case
      when d.member_key is not null then 'absent'
      when m.member_key = any(v_late_keys) then 'late'
      else 'present'
    end,
    v_checked_at,
    case when d.member_key is null then '' else trim(d.reason_code) end,
    case when d.member_key is null then '' else trim(coalesce(d.note, '')) end
  from public.bes_extra_class_members m
  left join lateral (
    select x.member_key, x.reason_code, x.note
    from jsonb_to_recordset(v_details) as x(member_key text, reason_code text, note text)
    where trim(x.member_key) = m.member_key
    limit 1
  ) d on true
  where m.class_id = p_class_id and m.active = true;

  return v_session;
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_cancel_extra_class_session(p_class_id uuid, p_attendance_date date, p_cancellation_reason text, p_teaching_room text, p_teaching_time_range text)
 RETURNS public.bes_extra_attendance_sessions
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_class public.bes_extra_classes%rowtype;
  v_session public.bes_extra_attendance_sessions%rowtype;
  v_checked_at timestamptz := clock_timestamp();
  v_today date := (clock_timestamp() at time zone 'Asia/Ho_Chi_Minh')::date;
  v_reason text := trim(coalesce(p_cancellation_reason, ''));
  v_room text := trim(coalesce(p_teaching_room, ''));
  v_time text := trim(coalesce(p_teaching_time_range, ''));
  v_checked_by_name text := '';
begin
  if not coalesce((private.bes_attendance_access_decision(p_class_id) ->> 'allowed')::boolean, false) then
    raise exception 'Bạn không có quyền hủy buổi học.' using errcode = '42501';
  end if;

  select coalesce(nullif(trim(p.full_name), ''), nullif(trim(p.email), ''), auth.uid()::text, '')
    into v_checked_by_name
  from public.profiles p
  where p.id = auth.uid() and p.approved = true;
  v_checked_by_name := coalesce(v_checked_by_name, auth.uid()::text, '');

  if p_attendance_date is null then raise exception 'Vui lòng chọn ngày học.' using errcode = '22004'; end if;
  if p_attendance_date > v_today then raise exception 'Không thể hủy buổi học ở ngày tương lai theo giờ Việt Nam.' using errcode = '22008'; end if;
  if v_reason = '' then raise exception 'Vui lòng nhập lý do hủy buổi học.' using errcode = '22023'; end if;

  select * into v_class from public.bes_extra_classes where id = p_class_id and active = true for update;
  if not found then raise exception 'Không tìm thấy lớp đang hoạt động.' using errcode = 'P0002'; end if;
  if exists (select 1 from public.bes_extra_attendance_sessions s where s.class_id = p_class_id and s.attendance_date = p_attendance_date) then
    raise exception 'Lớp này đã được xử lý điểm danh ngày %.', to_char(p_attendance_date, 'DD/MM/YYYY') using errcode = '23505';
  end if;
  if v_room = '' then v_room := trim(coalesce(v_class.room, '')); end if;
  if v_time = '' then v_time := trim(coalesce(v_class.time_range, '')); end if;

  begin
    insert into public.bes_extra_attendance_sessions (
      class_id, class_type, class_name, subject,
      teacher_id, teacher_name, teacher_email,
      attendance_date, checked_at, checked_by, checked_by_name,
      total_students, present_count, absent_count,
      note, session_status, lesson_periods, cancellation_reason,
      teaching_room, teaching_time_range
    ) values (
      v_class.id, v_class.class_type, v_class.class_name, v_class.subject,
      null, '', '',
      p_attendance_date, v_checked_at, auth.uid(), v_checked_by_name,
      0, 0, 0, '', 'cancelled', 0, v_reason, v_room, v_time
    ) returning * into v_session;
  exception when unique_violation then
    raise exception 'Lớp này đã được xử lý điểm danh ngày %.', to_char(p_attendance_date, 'DD/MM/YYYY') using errcode = '23505';
  end;
  return v_session;
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_update_extra_attendance_session(p_session_id uuid, p_records jsonb, p_note text DEFAULT ''::text)
 RETURNS public.bes_extra_attendance_sessions
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_profile public.profiles%rowtype;
  v_session public.bes_extra_attendance_sessions%rowtype;
  v_decision jsonb;
  v_records jsonb := coalesce(p_records, '[]'::jsonb);
  v_record public.bes_extra_attendance_records%rowtype;
  v_item record;
  v_input_count integer := 0;
  v_distinct_count integer := 0;
  v_actual_count integer := 0;
  v_unknown_count integer := 0;
  v_present integer := 0;
  v_absent integer := 0;
  v_new_status text;
  v_new_reason text;
  v_new_note text;
  v_session_note_before text := '';
  v_session_note_after text := trim(coalesce(p_note, ''));
  v_changed_at timestamptz := clock_timestamp();
begin
  v_decision := private.bes_extra_attendance_edit_decision(p_session_id, v_changed_at);
  if not coalesce((v_decision ->> 'allowed')::boolean, false) then
    case coalesce(v_decision ->> 'reason', '')
      when 'edit_window_expired' then
        raise exception 'Đã hết 30 phút điều chỉnh kể từ lúc chốt điểm danh.' using errcode = '42501';
      when 'not_session_teacher' then
        raise exception 'Chỉ giáo viên đã chốt buổi điểm danh này mới được điều chỉnh.' using errcode = '42501';
      when 'missing_permission' then
        raise exception 'Bạn không có quyền Điểm danh nhanh.' using errcode = '42501';
      when 'not_completed' then
        raise exception 'Chỉ buổi đã điểm danh mới có thể điều chỉnh.' using errcode = '22023';
      else
        raise exception 'Bạn không có quyền điều chỉnh buổi điểm danh này.' using errcode = '42501';
    end case;
  end if;

  select * into v_profile
  from public.profiles p
  where p.id = v_uid
    and p.approved = true;

  if not found then
    raise exception 'Tài khoản chưa được duyệt.' using errcode = '42501';
  end if;

  select * into v_session
  from public.bes_extra_attendance_sessions s
  where s.id = p_session_id
  for update;

  if not found then
    raise exception 'Không tìm thấy buổi điểm danh.' using errcode = 'P0002';
  end if;

  if jsonb_typeof(v_records) <> 'array' then
    raise exception 'Danh sách điều chỉnh không hợp lệ.' using errcode = '22023';
  end if;

  select count(*)::integer into v_actual_count
  from public.bes_extra_attendance_records r
  where r.session_id = p_session_id;

  select count(*)::integer,
         count(distinct x.record_id)::integer
    into v_input_count, v_distinct_count
  from jsonb_to_recordset(v_records) as x(
    record_id uuid,
    status text,
    reason_code text,
    note text
  );

  if v_input_count <> v_actual_count or v_input_count <> v_distinct_count then
    raise exception 'Danh sách điều chỉnh phải chứa đúng một trạng thái cho mỗi học sinh của buổi học.' using errcode = '22023';
  end if;

  select count(*)::integer into v_unknown_count
  from jsonb_to_recordset(v_records) as x(record_id uuid, status text, reason_code text, note text)
  where x.record_id is null
     or not exists (
       select 1
       from public.bes_extra_attendance_records r
       where r.id = x.record_id
         and r.session_id = p_session_id
     );

  if v_unknown_count > 0 then
    raise exception 'Danh sách điều chỉnh có học sinh không thuộc buổi điểm danh này.' using errcode = '22023';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(v_records) as x(record_id uuid, status text, reason_code text, note text)
    where trim(coalesce(x.status, '')) not in ('present', 'late', 'absent')
       or (
         trim(coalesce(x.status, '')) = 'absent'
         and trim(coalesce(x.reason_code, '')) not in ('excused', 'unexcused', 'sick', 'family', 'other', 'unspecified')
       )
       or (
         trim(coalesce(x.status, '')) = 'absent'
         and trim(coalesce(x.reason_code, '')) = 'other'
         and trim(coalesce(x.note, '')) = ''
       )
       or (
         trim(coalesce(x.status, '')) in ('present', 'late')
         and (trim(coalesce(x.reason_code, '')) <> '' or trim(coalesce(x.note, '')) <> '')
       )
  ) then
    raise exception 'Trạng thái hoặc lý do vắng không hợp lệ; Đi trễ không thể đồng thời là Vắng.' using errcode = '22023';
  end if;

  v_session_note_before := coalesce(v_session.note, '');

  for v_item in
    select *
    from jsonb_to_recordset(v_records) as x(record_id uuid, status text, reason_code text, note text)
  loop
    select * into v_record
    from public.bes_extra_attendance_records r
    where r.id = v_item.record_id
      and r.session_id = p_session_id
    for update;

    v_new_status := trim(coalesce(v_item.status, ''));
    if v_new_status in ('present', 'late') then
      v_new_reason := '';
      v_new_note := '';
    else
      v_new_reason := trim(coalesce(v_item.reason_code, ''));
      v_new_note := trim(coalesce(v_item.note, ''));
    end if;

    if v_record.status is distinct from v_new_status
       or coalesce(v_record.absence_reason_code, '') is distinct from v_new_reason
       or coalesce(v_record.absence_note, '') is distinct from v_new_note then
      insert into public.bes_extra_attendance_record_changes (
        session_id, record_id, class_id, member_key, student_full_name,
        change_kind, changed_by, changed_by_name, changed_at,
        old_status, new_status,
        old_absence_reason_code, new_absence_reason_code,
        old_absence_note, new_absence_note,
        session_note_before, session_note_after
      ) values (
        v_session.id, v_record.id, v_session.class_id, v_record.member_key, v_record.student_full_name,
        'record', v_uid, coalesce(v_profile.full_name, v_profile.email, ''), v_changed_at,
        v_record.status, v_new_status,
        coalesce(v_record.absence_reason_code, ''), v_new_reason,
        coalesce(v_record.absence_note, ''), v_new_note,
        v_session_note_before, v_session_note_after
      );

      update public.bes_extra_attendance_records
      set status = v_new_status,
          absence_reason_code = v_new_reason,
          absence_note = v_new_note
      where id = v_record.id;
    end if;
  end loop;

  if v_session_note_before is distinct from v_session_note_after then
    insert into public.bes_extra_attendance_record_changes (
      session_id, record_id, class_id, member_key, student_full_name,
      change_kind, changed_by, changed_by_name, changed_at,
      old_status, new_status,
      old_absence_reason_code, new_absence_reason_code,
      old_absence_note, new_absence_note,
      session_note_before, session_note_after
    ) values (
      v_session.id, null, v_session.class_id, '', '',
      'session_note', v_uid, coalesce(v_profile.full_name, v_profile.email, ''), v_changed_at,
      '', '', '', '', '', '',
      v_session_note_before, v_session_note_after
    );
  end if;

  select
    count(*) filter (where r.status in ('present', 'late'))::integer,
    count(*) filter (where r.status = 'absent')::integer
  into v_present, v_absent
  from public.bes_extra_attendance_records r
  where r.session_id = p_session_id;

  update public.bes_extra_attendance_sessions
  set total_students = v_present + v_absent,
      present_count = v_present,
      absent_count = v_absent,
      note = v_session_note_after
  where id = p_session_id
  returning * into v_session;

  return v_session;
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_set_extra_attendance_proof(p_session_id uuid, p_proof_path text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_path text := btrim(coalesce(p_proof_path, ''));
  v_updated integer := 0;
begin
  if not private.attendance_can_stage_proof(v_path) then
    raise exception 'Bạn không có quyền lưu minh chứng điểm danh.';
  end if;
  if v_path = '' or length(v_path) > 500 or v_path not like p_session_id::text || '/%' then
    raise exception 'Đường dẫn ảnh minh chứng không hợp lệ.';
  end if;

  update public.bes_extra_attendance_sessions
  set proof_path = v_path
  where id = p_session_id
    and session_status = 'completed'
    and checked_by = auth.uid()
    and proof_path is null
    and exists (
      select 1 from storage.objects o
      where o.bucket_id = 'attendance-session-proofs' and o.name = v_path
        and o.owner_id = auth.uid()::text
    );
  get diagnostics v_updated = row_count;

  if v_updated <> 1 then
    raise exception 'Không tìm thấy buổi điểm danh đã chốt thuộc người dùng hiện tại.';
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_list_attendance_archive()
 RETURNS TABLE(archive_id uuid, source_type text, source_session_id uuid, class_name text, subject text, teacher_name text, attendance_date date, checked_at timestamp with time zone, session_status text, proof_path text, archived_by uuid, archived_by_name text, archived_at timestamp with time zone, delete_request_status text, delete_requested_by uuid, delete_requested_at timestamp with time zone, delete_request_reason text, delete_reviewed_by uuid, delete_reviewed_at timestamp with time zone, delete_review_note text, can_review boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not (private.attendance_is_admin() OR private.attendance_global_permission('attendance:delete')) then
    raise exception 'Bạn không có quyền xem Kho lưu trữ điểm danh.' using errcode = '42501';
  end if;

  return query
  select
    a.id, a.source_type, a.source_session_id, a.class_name, a.subject, a.teacher_name,
    a.attendance_date, a.checked_at, a.session_status, a.proof_path,
    a.archived_by, a.archived_by_name, a.archived_at,
    a.delete_request_status, a.delete_requested_by, a.delete_requested_at,
    a.delete_request_reason, a.delete_reviewed_by, a.delete_reviewed_at,
    a.delete_review_note, private.attendance_is_admin()
  from public.bes_attendance_archive a
  order by a.archived_at desc, a.attendance_date desc;
end;
$function$;

CREATE FUNCTION public.bes_confirm_extra_class_attendance(p_class_id uuid, p_attendance_date date, p_teacher_name text, p_lesson_periods numeric, p_absence_details jsonb, p_note text, p_teaching_room text, p_teaching_time_range text, p_late_member_keys text[] DEFAULT '{}'::text[]) RETURNS public.bes_extra_attendance_sessions
LANGUAGE sql SET search_path = '' AS $$ SELECT private.bes_confirm_extra_class_attendance(p_class_id,p_attendance_date,p_teacher_name,p_lesson_periods,p_absence_details,p_note,p_teaching_room,p_teaching_time_range,p_late_member_keys); $$;
REVOKE ALL ON FUNCTION public.bes_confirm_extra_class_attendance(uuid,date,text,numeric,jsonb,text,text,text,text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_confirm_extra_class_attendance(uuid,date,text,numeric,jsonb,text,text,text,text[]) TO authenticated;

CREATE FUNCTION public.bes_cancel_extra_class_session(p_class_id uuid, p_attendance_date date, p_cancellation_reason text, p_teaching_room text, p_teaching_time_range text) RETURNS public.bes_extra_attendance_sessions
LANGUAGE sql SET search_path = '' AS $$ SELECT private.bes_cancel_extra_class_session(p_class_id,p_attendance_date,p_cancellation_reason,p_teaching_room,p_teaching_time_range); $$;
REVOKE ALL ON FUNCTION public.bes_cancel_extra_class_session(uuid,date,text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_cancel_extra_class_session(uuid,date,text,text,text) TO authenticated;

CREATE FUNCTION public.bes_update_extra_attendance_session(p_session_id uuid, p_records jsonb, p_note text DEFAULT '') RETURNS public.bes_extra_attendance_sessions
LANGUAGE sql SET search_path = '' AS $$ SELECT private.bes_update_extra_attendance_session(p_session_id,p_records,p_note); $$;
REVOKE ALL ON FUNCTION public.bes_update_extra_attendance_session(uuid,jsonb,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_update_extra_attendance_session(uuid,jsonb,text) TO authenticated;

CREATE FUNCTION public.bes_set_extra_attendance_proof(p_session_id uuid,p_proof_path text) RETURNS void
LANGUAGE sql SET search_path = '' AS $$ SELECT private.bes_set_extra_attendance_proof(p_session_id,p_proof_path); $$;
REVOKE ALL ON FUNCTION public.bes_set_extra_attendance_proof(uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_set_extra_attendance_proof(uuid,text) TO authenticated;

CREATE FUNCTION public.bes_list_attendance_archive() RETURNS TABLE(archive_id uuid, source_type text, source_session_id uuid, class_name text, subject text, teacher_name text, attendance_date date, checked_at timestamp with time zone, session_status text, proof_path text, archived_by uuid, archived_by_name text, archived_at timestamp with time zone, delete_request_status text, delete_requested_by uuid, delete_requested_at timestamp with time zone, delete_request_reason text, delete_reviewed_by uuid, delete_reviewed_at timestamp with time zone, delete_review_note text, can_review boolean)
LANGUAGE sql SET search_path = '' AS $$ SELECT * FROM private.bes_list_attendance_archive(); $$;
REVOKE ALL ON FUNCTION public.bes_list_attendance_archive() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_list_attendance_archive() TO authenticated;


CREATE FUNCTION public.bes_get_extra_attendance_edit_access(p_session_id uuid)
RETURNS jsonb LANGUAGE sql SET search_path = ''
AS $$ SELECT private.bes_extra_attendance_edit_decision(p_session_id, clock_timestamp()); $$;
CREATE FUNCTION public.bes_get_extra_class_attendance_access(p_class_id uuid,p_teacher_name text)
RETURNS jsonb LANGUAGE sql SET search_path = ''
AS $$ SELECT private.bes_attendance_access_decision(p_class_id); $$;
CREATE FUNCTION public.bes_get_attendance_access_settings()
RETURNS jsonb LANGUAGE sql SET search_path = ''
AS $$ SELECT private.bes_attendance_settings_snapshot(); $$;


REVOKE ALL ON FUNCTION private.attendance_is_admin() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.attendance_is_admin() TO authenticated;
REVOKE ALL ON FUNCTION private.attendance_global_permission(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.attendance_global_permission(text) TO authenticated;
REVOKE ALL ON FUNCTION private.attendance_can_write() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.attendance_can_write() TO authenticated;
REVOKE ALL ON FUNCTION private.bes_attendance_access_decision(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_attendance_access_decision(uuid) TO authenticated;
REVOKE ALL ON FUNCTION private.attendance_can_stage_proof(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.attendance_can_stage_proof(text) TO authenticated;
REVOKE ALL ON FUNCTION private.bes_extra_attendance_edit_decision(uuid,timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_extra_attendance_edit_decision(uuid,timestamptz) TO authenticated;
REVOKE ALL ON FUNCTION private.bes_attendance_settings_snapshot() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_attendance_settings_snapshot() TO authenticated;
REVOKE ALL ON FUNCTION private.bes_confirm_extra_class_attendance(uuid,date,text,numeric,jsonb,text,text,text,text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_confirm_extra_class_attendance(uuid,date,text,numeric,jsonb,text,text,text,text[]) TO authenticated;
REVOKE ALL ON FUNCTION private.bes_cancel_extra_class_session(uuid,date,text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_cancel_extra_class_session(uuid,date,text,text,text) TO authenticated;
REVOKE ALL ON FUNCTION private.bes_update_extra_attendance_session(uuid,jsonb,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_update_extra_attendance_session(uuid,jsonb,text) TO authenticated;
REVOKE ALL ON FUNCTION private.bes_set_extra_attendance_proof(uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_set_extra_attendance_proof(uuid,text) TO authenticated;
REVOKE ALL ON FUNCTION private.bes_list_attendance_archive() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_list_attendance_archive() TO authenticated;

REVOKE ALL ON FUNCTION public.bes_get_extra_attendance_edit_access(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_get_extra_attendance_edit_access(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.bes_get_extra_class_attendance_access(uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_get_extra_class_attendance_access(uuid,text) TO authenticated;
REVOKE ALL ON FUNCTION public.bes_get_attendance_access_settings() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_get_attendance_access_settings() TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
