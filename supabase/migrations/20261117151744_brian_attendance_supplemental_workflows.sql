BEGIN;
SET LOCAL check_function_bodies = off;

CREATE FUNCTION private.attendance_supplemental_access_decision()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  config public.bes_attendance_access_settings%rowtype;
  vietnam_time time := (clock_timestamp() AT TIME ZONE 'Asia/Ho_Chi_Minh')::time;
  allowed_time boolean;
BEGIN
  IF NOT private.attendance_can_manage_roster() THEN
    RETURN jsonb_build_object('allowed', false, 'reason', 'supplemental_not_allowed');
  END IF;
  IF private.attendance_is_admin() OR private.attendance_global_permission('attendance:report') THEN
    RETURN jsonb_build_object('allowed', true, 'reason', 'privileged');
  END IF;
  SELECT * INTO config FROM public.bes_attendance_access_settings WHERE id = 1;
  IF config.enforce_teacher_time_window IS NOT TRUE THEN
    RETURN jsonb_build_object('allowed', true, 'reason', 'restriction_disabled');
  END IF;
  IF config.teacher_start_time = config.teacher_end_time THEN
    RETURN jsonb_build_object('allowed', false, 'reason', 'invalid_time');
  ELSIF config.teacher_start_time < config.teacher_end_time THEN
    allowed_time := vietnam_time BETWEEN config.teacher_start_time AND config.teacher_end_time;
  ELSE
    allowed_time := vietnam_time >= config.teacher_start_time OR vietnam_time <= config.teacher_end_time;
  END IF;
  RETURN jsonb_build_object('allowed', coalesce(allowed_time, false),
    'reason', CASE WHEN allowed_time THEN 'within_window' ELSE 'outside_time' END);
END;
$$;
REVOKE ALL ON FUNCTION private.attendance_supplemental_access_decision() FROM PUBLIC, anon, authenticated;


CREATE OR REPLACE FUNCTION private.bes_confirm_supplemental_attendance_v2(p_session_id uuid, p_participants jsonb, p_session_note text DEFAULT ''::text, p_proof_path text DEFAULT ''::text, p_lesson_periods numeric DEFAULT 1, p_teacher_name text DEFAULT ''::text, p_room text DEFAULT ''::text, p_start_time time without time zone DEFAULT NULL::time without time zone, p_end_time time without time zone DEFAULT NULL::time without time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.bes_require_supplemental_manager();
  v_result jsonb;
  v_session public.bes_supplemental_sessions%rowtype;
  v_teacher_row public.bes_supplemental_group_teachers%rowtype;
  v_teacher_name text;
  v_room text;
  v_start_time time;
  v_end_time time;
begin
  select * into v_session
  from public.bes_supplemental_sessions s
  where s.id = p_session_id
  for update;

  if not found then
    raise exception 'Không tìm thấy buổi Học bổ sung.' using errcode = 'P0002';
  end if;

  if coalesce(p_lesson_periods, 1) not in (1, 1.5, 2) then
    raise exception 'Số tiết chỉ được là 1, 1.5 hoặc 2.' using errcode = '22023';
  end if;

  v_teacher_name := coalesce(nullif(btrim(coalesce(p_teacher_name, '')), ''), nullif(btrim(v_session.teacher_name), ''));
  v_room := coalesce(nullif(btrim(coalesce(p_room, '')), ''), nullif(btrim(v_session.room), ''));
  v_start_time := coalesce(p_start_time, v_session.start_time);
  v_end_time := coalesce(p_end_time, v_session.end_time);

  if v_teacher_name is null then
    raise exception 'Vui lòng chọn giáo viên dạy hôm nay.' using errcode = '22023';
  end if;
  if v_room is null then
    raise exception 'Vui lòng nhập phòng học.' using errcode = '22023';
  end if;
  if v_start_time is null or v_end_time is null then
    raise exception 'Vui lòng nhập thời gian dạy.' using errcode = '22023';
  end if;
  if v_start_time >= v_end_time then
    raise exception 'Giờ kết thúc phải sau giờ bắt đầu.' using errcode = '22023';
  end if;

  if jsonb_typeof(coalesce(p_participants, '[]'::jsonb)) <> 'array' then
    raise exception 'Danh sách điểm danh không hợp lệ.' using errcode = '22023';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_participants, '[]'::jsonb)) as x(
      "participantId" uuid,
      status text,
      "absenceReasonCode" text,
      "absenceNote" text
    )
    where lower(btrim(coalesce(x.status, ''))) not in ('present', 'tardy', 'absent')
       or (
         lower(btrim(coalesce(x.status, ''))) = 'absent'
         and btrim(coalesce(x."absenceReasonCode", '')) not in ('excused', 'unexcused', 'sick', 'family', 'other', 'unspecified')
       )
       or (
         lower(btrim(coalesce(x.status, ''))) = 'absent'
         and btrim(coalesce(x."absenceReasonCode", '')) = 'other'
         and btrim(coalesce(x."absenceNote", '')) = ''
       )
       or (
         lower(btrim(coalesce(x.status, ''))) in ('present', 'tardy')
         and (btrim(coalesce(x."absenceReasonCode", '')) <> '' or btrim(coalesce(x."absenceNote", '')) <> '')
       )
  ) then
    raise exception 'Trạng thái hoặc lý do vắng không hợp lệ; lý do Khác phải có ghi chú.' using errcode = '22023';
  end if;

  -- If the recurring class has normalized teacher assignments, the chosen teacher
  -- must be one of them. Teacher metadata never grants supplemental access.
  if v_session.group_id is not null and exists (
    select 1 from public.bes_supplemental_group_teachers t where t.group_id = v_session.group_id
  ) then
    select * into v_teacher_row
    from public.bes_supplemental_group_teachers t
    where t.group_id = v_session.group_id
      and lower(btrim(t.teacher_name)) = lower(v_teacher_name)
    order by t.position, t.teacher_name
    limit 1;

    if not found then
      raise exception 'Giáo viên đã chọn không thuộc phân công của lớp Học bổ sung.' using errcode = '22023';
    end if;
  end if;

  -- Match the global teacher/day lock across both attendance sources.
  if exists (
    select 1
    from public.bes_extra_attendance_sessions e
    where e.attendance_date = v_session.attendance_date
      and e.session_status = 'completed'
      and lower(btrim(e.teacher_name)) = lower(v_teacher_name)
  ) or exists (
    select 1
    from public.bes_supplemental_sessions s
    where s.id <> v_session.id
      and s.attendance_date = v_session.attendance_date
      and s.status = 'confirmed'
      and lower(btrim(s.teacher_name)) = lower(v_teacher_name)
  ) then
    raise exception 'Giáo viên % đã được chốt điểm danh ở một lớp khác ngày %.',
      v_teacher_name, to_char(v_session.attendance_date, 'DD/MM/YYYY')
      using errcode = '23505';
  end if;

  -- Reuse the hardened base confirmation for exact-roster validation, counts,
  -- proof semantics, actor snapshots and strict supplemental authorization.
  v_result := private.bes_confirm_supplemental_attendance(
    p_session_id,
    coalesce(p_participants, '[]'::jsonb),
    coalesce(p_session_note, ''),
    coalesce(p_proof_path, '')
  );

  update public.bes_supplemental_sessions
  set lesson_periods = coalesce(p_lesson_periods, 1),
      teacher_id = coalesce(v_teacher_row.teacher_id, teacher_id),
      teacher_name = v_teacher_name,
      teacher_email = case when v_teacher_row.id is not null then coalesce(v_teacher_row.teacher_email, '') else teacher_email end,
      room = v_room,
      start_time = v_start_time,
      end_time = v_end_time,
      updated_by = v_uid,
      updated_at = clock_timestamp()
  where id = p_session_id
  returning * into v_session;

  return jsonb_set(coalesce(v_result, '{}'::jsonb), '{session}', to_jsonb(v_session), true);
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_delete_supplemental_attendance_history(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select private.bes_archive_attendance_history('supplemental', p_session_id);
$function$;

CREATE OR REPLACE FUNCTION private.bes_get_supplemental_attendance_edit_snapshot(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_access jsonb;
  v_session public.bes_supplemental_sessions%rowtype;
  v_records jsonb := '[]'::jsonb;
  v_latest_change jsonb := '{}'::jsonb;
begin
  perform private.bes_require_supplemental_manager();
  v_access := private.bes_supplemental_attendance_edit_decision(p_session_id, clock_timestamp());

  select * into v_session
  from public.bes_supplemental_sessions s
  where s.id = p_session_id;

  if not found then
    return jsonb_build_object('access', v_access, 'session', null, 'records', '[]'::jsonb, 'latestChange', '{}'::jsonb);
  end if;

  if coalesce((v_access ->> 'allowed')::boolean, false) then
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id,
      'session_id', p.session_id,
      'class_id', 'supplemental:' || coalesce(v_session.group_id::text, v_session.id::text),
      'member_id', p.student_id,
      'member_key', p.canonical_student_key,
      'student_code', p.student_code_snapshot,
      'student_full_name', p.full_name_snapshot,
      'school_class_name', p.school_class_snapshot,
      'status', case when p.attendance_status = 'tardy' then 'late' else p.attendance_status end,
      'absence_reason_code', p.absence_reason_code,
      'absence_note', p.absence_note
    ) order by p.full_name_snapshot), '[]'::jsonb)
    into v_records
    from public.bes_supplemental_session_participants p
    where p.session_id = p_session_id;
  end if;

  select coalesce(to_jsonb(c), '{}'::jsonb)
  into v_latest_change
  from public.bes_supplemental_attendance_record_changes c
  where c.session_id = p_session_id
  order by c.changed_at desc
  limit 1;

  return jsonb_build_object(
    'access', v_access,
    'session', jsonb_build_object(
      'id', v_session.id,
      'class_id', 'supplemental:' || coalesce(v_session.group_id::text, v_session.id::text),
      'class_name', coalesce(nullif(v_session.title, ''), 'Học bổ sung'),
      'subject', v_session.subject,
      'teacher_name', v_session.teacher_name,
      'attendance_date', v_session.attendance_date,
      'checked_at', v_session.attendance_confirmed_at,
      'checked_by', v_session.checked_by,
      'checked_by_name', v_session.checked_by_name,
      'total_students', v_session.total_students,
      'present_count', v_session.present_count + v_session.tardy_count,
      'absent_count', v_session.absent_count,
      'note', v_session.session_note,
      'session_status', case when v_session.status = 'confirmed' then 'completed' else v_session.status end
    ),
    'records', v_records,
    'latestChange', coalesce(v_latest_change, '{}'::jsonb)
  );
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_list_supplemental_history(p_from date DEFAULT (CURRENT_DATE - 31), p_to date DEFAULT CURRENT_DATE, p_query text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_q text := lower(btrim(coalesce(p_query, '')));
begin
  perform private.bes_require_supplemental_reader(array['attendance:history','attendance:report']);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', s.id,
      'activityType', 'supplemental',
      'kind', s.kind,
      'title', s.title,
      'groupName', g.group_name,
      'date', s.attendance_date,
      'subject', s.subject,
      'teacherName', s.teacher_name,
      'room', s.room,
      'timeRange', to_char(s.start_time,'HH24:MI') || '–' || to_char(s.end_time,'HH24:MI'),
      'lessonPeriods', coalesce(s.lesson_periods, 1),
      'status', s.status,
      'cancellationReason', s.cancellation_reason,
      'totalStudents', s.total_students,
      'presentCount', s.present_count,
      'absentCount', s.absent_count,
      'tardyCount', s.tardy_count,
      'checkedByName', s.checked_by_name,
      'sessionNote', s.session_note,
      'proofPath', s.proof_path,
      'participants', coalesce((
        select jsonb_agg(jsonb_build_object(
          'studentId', p.student_id,
          'canonicalStudentKey', p.canonical_student_key,
          'studentCode', p.student_code_snapshot,
          'fullName', p.full_name_snapshot,
          'schoolClassName', p.school_class_snapshot,
          'status', p.attendance_status,
          'absenceReasonCode', p.absence_reason_code,
          'absenceNote', p.absence_note
        ) order by p.full_name_snapshot)
        from public.bes_supplemental_session_participants p
        where p.session_id = s.id
      ), '[]'::jsonb)
    ) order by s.attendance_date desc, s.start_time desc)
    from public.bes_supplemental_sessions s
    left join public.bes_supplemental_groups g on g.id = s.group_id
    where s.attendance_date between p_from and p_to
      and s.status in ('confirmed','cancelled')
      and (
        v_q = ''
        or lower(s.title) like '%' || v_q || '%'
        or lower(s.subject) like '%' || v_q || '%'
        or lower(s.teacher_name) like '%' || v_q || '%'
        or lower(coalesce(g.group_name,'')) like '%' || v_q || '%'
        or exists (
          select 1 from public.bes_supplemental_session_participants p
          where p.session_id = s.id and lower(p.full_name_snapshot) like '%' || v_q || '%'
        )
      )
  ), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_list_supplemental_session_teachers(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_session public.bes_supplemental_sessions%rowtype;
  v_rows jsonb := '[]'::jsonb;
begin
  perform private.bes_require_supplemental_manager();

  select * into v_session
  from public.bes_supplemental_sessions s
  where s.id = p_session_id;

  if not found then
    raise exception 'Không tìm thấy buổi Học bổ sung.' using errcode = 'P0002';
  end if;

  if v_session.group_id is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', t.id,
      'teacherId', t.teacher_id,
      'fullName', t.teacher_name,
      'email', t.teacher_email,
      'position', t.position
    ) order by t.position, t.teacher_name), '[]'::jsonb)
    into v_rows
    from public.bes_supplemental_group_teachers t
    where t.group_id = v_session.group_id;
  end if;

  if jsonb_array_length(v_rows) = 0 and nullif(btrim(v_session.teacher_name), '') is not null then
    v_rows := jsonb_build_array(jsonb_build_object(
      'id', null,
      'teacherId', v_session.teacher_id,
      'fullName', btrim(v_session.teacher_name),
      'email', btrim(coalesce(v_session.teacher_email, '')),
      'position', 1
    ));
  end if;

  return v_rows;
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_update_supplemental_attendance_session(p_session_id uuid, p_records jsonb, p_note text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.bes_require_supplemental_manager();
  v_profile public.profiles%rowtype;
  v_session public.bes_supplemental_sessions%rowtype;
  v_decision jsonb;
  v_records jsonb := coalesce(p_records, '[]'::jsonb);
  v_participant public.bes_supplemental_session_participants%rowtype;
  v_item record;
  v_input_count integer := 0;
  v_distinct_count integer := 0;
  v_actual_count integer := 0;
  v_unknown_count integer := 0;
  v_present integer := 0;
  v_tardy integer := 0;
  v_absent integer := 0;
  v_new_status text;
  v_new_reason text;
  v_new_note text;
  v_session_note_before text := '';
  v_session_note_after text := btrim(coalesce(p_note, ''));
  v_changed_at timestamptz := clock_timestamp();
begin
  v_decision := private.bes_supplemental_attendance_edit_decision(p_session_id, v_changed_at);
  if not coalesce((v_decision ->> 'allowed')::boolean, false) then
    case coalesce(v_decision ->> 'reason', '')
      when 'edit_window_expired' then
        raise exception 'Đã hết 30 phút điều chỉnh kể từ lúc chốt điểm danh.' using errcode = '42501';
      when 'not_session_teacher' then
        raise exception 'Chỉ người đã chốt buổi điểm danh này mới được điều chỉnh trong thời gian cho phép.' using errcode = '42501';
      when 'not_completed' then
        raise exception 'Chỉ buổi Học bổ sung đã chốt mới có thể điều chỉnh.' using errcode = '22023';
      else
        raise exception 'Bạn không có quyền điều chỉnh buổi Học bổ sung này.' using errcode = '42501';
    end case;
  end if;

  select * into v_profile
  from public.profiles p
  where p.id = v_uid and p.approved = true;

  if not found then
    raise exception 'Tài khoản chưa được duyệt.' using errcode = '42501';
  end if;

  select * into v_session
  from public.bes_supplemental_sessions s
  where s.id = p_session_id
  for update;

  if not found then
    raise exception 'Không tìm thấy buổi Học bổ sung.' using errcode = 'P0002';
  end if;

  if jsonb_typeof(v_records) <> 'array' then
    raise exception 'Danh sách điều chỉnh không hợp lệ.' using errcode = '22023';
  end if;

  select count(*)::integer into v_actual_count
  from public.bes_supplemental_session_participants p
  where p.session_id = p_session_id;

  select count(*)::integer, count(distinct x."participantId")::integer
  into v_input_count, v_distinct_count
  from jsonb_to_recordset(v_records) as x(
    "participantId" uuid,
    status text,
    "absenceReasonCode" text,
    "absenceNote" text
  );

  if v_input_count <> v_actual_count or v_input_count <> v_distinct_count then
    raise exception 'Danh sách điều chỉnh phải chứa đúng một trạng thái cho mỗi học sinh của buổi học.' using errcode = '22023';
  end if;

  select count(*)::integer into v_unknown_count
  from jsonb_to_recordset(v_records) as x(
    "participantId" uuid,
    status text,
    "absenceReasonCode" text,
    "absenceNote" text
  )
  where x."participantId" is null
     or not exists (
       select 1
       from public.bes_supplemental_session_participants p
       where p.id = x."participantId" and p.session_id = p_session_id
     );

  if v_unknown_count > 0 then
    raise exception 'Danh sách điều chỉnh có học sinh không thuộc buổi Học bổ sung này.' using errcode = '22023';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(v_records) as x(
      "participantId" uuid,
      status text,
      "absenceReasonCode" text,
      "absenceNote" text
    )
    where lower(btrim(coalesce(x.status, ''))) not in ('present', 'tardy', 'absent')
       or (
         lower(btrim(coalesce(x.status, ''))) = 'absent'
         and btrim(coalesce(x."absenceReasonCode", '')) not in ('excused', 'unexcused', 'sick', 'family', 'other', 'unspecified')
       )
       or (
         lower(btrim(coalesce(x.status, ''))) = 'absent'
         and btrim(coalesce(x."absenceReasonCode", '')) = 'other'
         and btrim(coalesce(x."absenceNote", '')) = ''
       )
       or (
         lower(btrim(coalesce(x.status, ''))) in ('present', 'tardy')
         and (btrim(coalesce(x."absenceReasonCode", '')) <> '' or btrim(coalesce(x."absenceNote", '')) <> '')
       )
  ) then
    raise exception 'Trạng thái hoặc lý do vắng không hợp lệ; Đi trễ không thể đồng thời là Vắng.' using errcode = '22023';
  end if;

  v_session_note_before := coalesce(v_session.session_note, '');

  for v_item in
    select *
    from jsonb_to_recordset(v_records) as x(
      "participantId" uuid,
      status text,
      "absenceReasonCode" text,
      "absenceNote" text
    )
  loop
    select * into v_participant
    from public.bes_supplemental_session_participants p
    where p.id = v_item."participantId" and p.session_id = p_session_id
    for update;

    v_new_status := lower(btrim(coalesce(v_item.status, '')));
    if v_new_status in ('present', 'tardy') then
      v_new_reason := '';
      v_new_note := '';
    else
      v_new_reason := btrim(coalesce(v_item."absenceReasonCode", ''));
      v_new_note := btrim(coalesce(v_item."absenceNote", ''));
    end if;

    if coalesce(v_participant.attendance_status, '') is distinct from v_new_status
       or coalesce(v_participant.absence_reason_code, '') is distinct from v_new_reason
       or coalesce(v_participant.absence_note, '') is distinct from v_new_note then
      insert into public.bes_supplemental_attendance_record_changes (
        session_id, participant_id, group_id, canonical_student_key, student_full_name,
        change_kind, changed_by, changed_by_name, changed_at,
        old_status, new_status,
        old_absence_reason_code, new_absence_reason_code,
        old_absence_note, new_absence_note,
        session_note_before, session_note_after
      ) values (
        v_session.id, v_participant.id, v_session.group_id, v_participant.canonical_student_key, v_participant.full_name_snapshot,
        'record', v_uid, coalesce(v_profile.full_name, v_profile.email, ''), v_changed_at,
        coalesce(v_participant.attendance_status, ''), v_new_status,
        coalesce(v_participant.absence_reason_code, ''), v_new_reason,
        coalesce(v_participant.absence_note, ''), v_new_note,
        v_session_note_before, v_session_note_after
      );

      update public.bes_supplemental_session_participants
      set attendance_status = v_new_status,
          absence_reason_code = v_new_reason,
          absence_note = v_new_note,
          updated_at = v_changed_at
      where id = v_participant.id;
    end if;
  end loop;

  if v_session_note_before is distinct from v_session_note_after then
    insert into public.bes_supplemental_attendance_record_changes (
      session_id, participant_id, group_id, canonical_student_key, student_full_name,
      change_kind, changed_by, changed_by_name, changed_at,
      old_status, new_status,
      old_absence_reason_code, new_absence_reason_code,
      old_absence_note, new_absence_note,
      session_note_before, session_note_after
    ) values (
      v_session.id, null, v_session.group_id, '', '',
      'session_note', v_uid, coalesce(v_profile.full_name, v_profile.email, ''), v_changed_at,
      '', '', '', '', '', '',
      v_session_note_before, v_session_note_after
    );
  end if;

  select
    count(*) filter (where p.attendance_status = 'present')::integer,
    count(*) filter (where p.attendance_status = 'tardy')::integer,
    count(*) filter (where p.attendance_status = 'absent')::integer
  into v_present, v_tardy, v_absent
  from public.bes_supplemental_session_participants p
  where p.session_id = p_session_id;

  update public.bes_supplemental_sessions
  set total_students = v_present + v_tardy + v_absent,
      present_count = v_present,
      tardy_count = v_tardy,
      absent_count = v_absent,
      session_note = v_session_note_after,
      updated_by = v_uid,
      updated_at = v_changed_at
  where id = p_session_id
  returning * into v_session;

  -- attendance_confirmed_at is intentionally untouched: a correction must never
  -- restart or extend the original 30-minute edit window.
  return jsonb_build_object('session', to_jsonb(v_session), 'access', v_decision);
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_clear_supplemental_edit_audit_on_reset()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if old.status in ('confirmed', 'cancelled')
     and new.status = 'scheduled'
     and new.attendance_confirmed_at is null then
    delete from public.bes_supplemental_attendance_record_changes c
    where c.session_id = new.id;
  end if;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_require_supplemental_reader(p_permissions text[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform p_permissions;
  return private.bes_require_supplemental_manager();
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_supplemental_attendance_edit_decision(p_session_id uuid, p_now timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_profile public.profiles%rowtype;
  v_session public.bes_supplemental_sessions%rowtype;
  v_now timestamptz := coalesce(p_now, clock_timestamp());
  v_expires_at timestamptz;
  v_remaining_seconds integer := 0;
  v_is_admin boolean := false;
  v_has_report boolean := false;
begin
  if v_uid is null then
    return jsonb_build_object('allowed', false, 'reason', 'not_authenticated', 'server_now', v_now);
  end if;

  if not private.bes_is_supplemental_manager() then
    return jsonb_build_object('allowed', false, 'reason', 'supplemental_not_allowed', 'server_now', v_now);
  end if;

  select * into v_profile
  from public.profiles p
  where p.id = v_uid and p.approved = true;

  if not found then
    return jsonb_build_object('allowed', false, 'reason', 'profile_not_approved', 'server_now', v_now);
  end if;

  select * into v_session
  from public.bes_supplemental_sessions s
  where s.id = p_session_id;

  if not found then
    return jsonb_build_object('allowed', false, 'reason', 'session_not_found', 'server_now', v_now);
  end if;

  if v_session.status <> 'confirmed' then
    return jsonb_build_object('allowed', false, 'reason', 'not_completed', 'session_id', v_session.id, 'server_now', v_now);
  end if;

  if v_session.attendance_confirmed_at is null then
    return jsonb_build_object('allowed', false, 'reason', 'invalid_checked_at', 'session_id', v_session.id, 'server_now', v_now);
  end if;

  v_expires_at := v_session.attendance_confirmed_at + interval '30 minutes';
  v_remaining_seconds := greatest(0, floor(extract(epoch from (v_expires_at - v_now)))::integer);
  v_is_admin := private.attendance_is_admin();
  v_has_report := private.attendance_global_permission('attendance:report');

  if v_is_admin or v_has_report then
    return jsonb_build_object(
      'allowed', true,
      'reason', case when v_is_admin then 'admin_bypass' else 'report_bypass' end,
      'bypass', true,
      'session_id', v_session.id,
      'checked_at', v_session.attendance_confirmed_at,
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
      'checked_at', v_session.attendance_confirmed_at,
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
    'checked_at', v_session.attendance_confirmed_at,
    'expires_at', v_expires_at,
    'remaining_seconds', v_remaining_seconds,
    'server_now', v_now
  );
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_supplemental_canonical_key(p_student_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select case when nullif(btrim(s.linked_official_key),'') is not null then 'official:'||lower(btrim(s.linked_official_key)) when s.source_type='official' and nullif(btrim(s.official_key),'') is not null then 'official:'||lower(btrim(s.official_key)) else 'supplemental:'||s.id::text end from public.bes_supplemental_students s where s.id=p_student_id $function$;

CREATE OR REPLACE FUNCTION private.bes_supplemental_official_candidates()
 RETURNS TABLE(official_key text, student_code text, full_name text, school_class_name text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
with extra_members as (
  select case when nullif(btrim(m.student_code),'') is not null then 'school:'||lower(btrim(m.student_code)) else 'extra-member:'||lower(btrim(m.member_key)) end as official_key,coalesce(m.student_code,'') as student_code,coalesce(m.student_full_name,'') as full_name,coalesce(m.school_class_name,'') as school_class_name
  from public.bes_extra_class_members m where m.active=true and nullif(btrim(m.student_full_name),'') is not null
), combined as (select * from extra_members)
select distinct on(c.official_key) c.official_key,c.student_code,c.full_name,c.school_class_name from combined c where nullif(btrim(c.official_key),'') is not null order by c.official_key,case when nullif(btrim(c.student_code),'') is not null then 0 else 1 end,c.full_name
$function$;

CREATE OR REPLACE FUNCTION private.bes_materialize_supplemental_group_sessions(p_group_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_group public.bes_supplemental_groups%rowtype; v_count integer:=0;
begin
  select * into v_group from public.bes_supplemental_groups g where g.id=p_group_id for update;
  if not found then raise exception 'Không tìm thấy nhóm Học bổ sung.'; end if;
  update public.bes_supplemental_sessions s set status='cancelled',cancellation_reason='Lịch nhóm đã thay đổi',updated_by=v_group.updated_by,updated_at=clock_timestamp()
  where s.group_id=v_group.id and s.kind='recurring' and s.status='scheduled' and s.roster_frozen_at is null and s.attendance_date>=current_date and (v_group.active=false or s.attendance_date<v_group.start_date or s.attendance_date>v_group.end_date or not(extract(isodow from s.attendance_date)::smallint=any(v_group.weekdays)));
  insert into public.bes_supplemental_sessions(group_id,kind,title,attendance_date,subject,teacher_id,teacher_name,teacher_email,room,start_time,end_time,status,cancellation_reason,created_by,updated_by,created_at,updated_at)
  select v_group.id,'recurring',v_group.group_name,d::date,v_group.subject,v_group.teacher_id,v_group.teacher_name,v_group.teacher_email,v_group.room,v_group.start_time,v_group.end_time,'scheduled','',v_group.created_by,v_group.updated_by,clock_timestamp(),clock_timestamp()
  from generate_series(v_group.start_date,v_group.end_date,interval '1 day') d where v_group.active=true and extract(isodow from d)::smallint=any(v_group.weekdays)
  on conflict(group_id,attendance_date) do update set title=excluded.title,subject=excluded.subject,teacher_id=excluded.teacher_id,teacher_name=excluded.teacher_name,teacher_email=excluded.teacher_email,room=excluded.room,start_time=excluded.start_time,end_time=excluded.end_time,status=case when public.bes_supplemental_sessions.status='cancelled' and public.bes_supplemental_sessions.cancellation_reason='Lịch nhóm đã thay đổi' then 'scheduled' else public.bes_supplemental_sessions.status end,cancellation_reason=case when public.bes_supplemental_sessions.status='cancelled' and public.bes_supplemental_sessions.cancellation_reason='Lịch nhóm đã thay đổi' then '' else public.bes_supplemental_sessions.cancellation_reason end,updated_by=excluded.updated_by,updated_at=clock_timestamp()
  where public.bes_supplemental_sessions.roster_frozen_at is null and public.bes_supplemental_sessions.status in('scheduled','cancelled');
  get diagnostics v_count=row_count; return v_count;
end; $function$;

CREATE OR REPLACE FUNCTION private.bes_require_supplemental_admin()
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  return private.bes_require_supplemental_manager();
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_require_supplemental_manager()
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Bạn cần đăng nhập để quản lý Học bổ sung.' using errcode = '42501';
  end if;
  if not private.bes_is_supplemental_manager() then
    raise exception 'Tài khoản không có quyền truy cập Học bổ sung.' using errcode = '42501';
  end if;
  return v_uid;
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_link_supplemental_student(p_student_id uuid, p_official_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$ declare v_uid uuid:=private.bes_require_supplemental_admin(); v_row public.bes_supplemental_students%rowtype; v_target text:=nullif(btrim(p_official_key),''); v_target_canonical text;
begin
 if v_target is null then raise exception 'Hãy chọn học sinh chính thức để liên kết.'; end if;
 if not exists(select 1 from private.bes_supplemental_official_candidates() c where lower(c.official_key)=lower(v_target)) and not exists(select 1 from public.bes_supplemental_students s where s.source_type='official' and lower(s.official_key)=lower(v_target)) then raise exception 'Không tìm thấy học sinh chính thức tương ứng.'; end if;
 select * into v_row from public.bes_supplemental_students s where s.id=p_student_id for update; if not found then raise exception 'Không tìm thấy học sinh Học bổ sung.'; end if; if v_row.source_type<>'manual' then raise exception 'Chỉ học sinh nhập thủ công mới cần liên kết.'; end if; v_target_canonical:='official:'||lower(v_target);
 if exists(select 1 from public.bes_supplemental_session_participants ownp join public.bes_supplemental_session_participants otherp on otherp.session_id=ownp.session_id and otherp.id<>ownp.id where ownp.student_id=p_student_id and private.bes_supplemental_canonical_key(otherp.student_id)=v_target_canonical) then raise exception 'Không thể liên kết vì học sinh chính thức đã xuất hiện trong cùng một buổi học.'; end if;
 if exists(select 1 from public.bes_supplemental_group_memberships ownm join public.bes_supplemental_group_memberships otherm on otherm.group_id=ownm.group_id and otherm.id<>ownm.id where ownm.student_id=p_student_id and private.bes_supplemental_canonical_key(otherm.student_id)=v_target_canonical and daterange(ownm.effective_from,coalesce(ownm.effective_until+1,'infinity'::date),'[)')&&daterange(otherm.effective_from,coalesce(otherm.effective_until+1,'infinity'::date),'[)')) then raise exception 'Không thể liên kết vì sẽ tạo thành viên trùng trong cùng nhóm.'; end if;
 update public.bes_supplemental_students s set linked_official_key=v_target,updated_by=v_uid,updated_at=clock_timestamp() where s.id=p_student_id returning * into v_row;
 return to_jsonb(v_row); end; $function$;

CREATE OR REPLACE FUNCTION private.bes_list_supplemental_admin_data()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$ begin perform private.bes_require_supplemental_admin(); return jsonb_build_object(
 'officialStudents',coalesce((select jsonb_agg(jsonb_build_object('officialKey',c.official_key,'studentCode',c.student_code,'fullName',c.full_name,'schoolClassName',c.school_class_name) order by c.school_class_name,c.full_name) from private.bes_supplemental_official_candidates() c),'[]'::jsonb),
 'students',coalesce((select jsonb_agg(to_jsonb(s) order by s.full_name) from public.bes_supplemental_students s),'[]'::jsonb),
 'groups',coalesce((select jsonb_agg(to_jsonb(g) order by g.active desc,g.group_name) from public.bes_supplemental_groups g),'[]'::jsonb),
 'memberships',coalesce((select jsonb_agg(to_jsonb(m) order by m.effective_from desc) from public.bes_supplemental_group_memberships m),'[]'::jsonb),
 'sessions',coalesce((select jsonb_agg(to_jsonb(s) order by s.attendance_date desc,s.start_time) from public.bes_supplemental_sessions s),'[]'::jsonb),
 'participants',coalesce((select jsonb_agg(to_jsonb(p) order by p.full_name_snapshot) from public.bes_supplemental_session_participants p),'[]'::jsonb)); end; $function$;

CREATE OR REPLACE FUNCTION private.bes_upsert_supplemental_session(p_session_id uuid DEFAULT NULL::uuid, p_group_id uuid DEFAULT NULL::uuid, p_kind text DEFAULT 'adhoc'::text, p_title text DEFAULT ''::text, p_attendance_date date DEFAULT CURRENT_DATE, p_subject text DEFAULT ''::text, p_teacher_id uuid DEFAULT NULL::uuid, p_teacher_name text DEFAULT ''::text, p_teacher_email text DEFAULT ''::text, p_room text DEFAULT ''::text, p_start_time time without time zone DEFAULT '16:45:00'::time without time zone, p_end_time time without time zone DEFAULT '18:00:00'::time without time zone, p_participant_ids uuid[] DEFAULT '{}'::uuid[], p_session_note text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$ declare v_uid uuid:=private.bes_require_supplemental_admin(); v_kind text:=lower(btrim(coalesce(p_kind,'adhoc'))); v_row public.bes_supplemental_sessions%rowtype; v_existing public.bes_supplemental_sessions%rowtype;
begin
 if v_kind not in('recurring','adhoc') then raise exception 'Loại buổi học không hợp lệ.'; end if; if v_kind='recurring' and p_group_id is null then raise exception 'Buổi dài ngày phải thuộc một nhóm.'; end if; if v_kind='adhoc' and p_group_id is not null then raise exception 'Buổi phát sinh không gắn với nhóm dài ngày.'; end if; if nullif(btrim(p_subject),'') is null then raise exception 'Môn học là bắt buộc.'; end if; if p_start_time=p_end_time then raise exception 'Giờ bắt đầu và kết thúc phải khác nhau.'; end if;
 if p_session_id is not null then select * into v_existing from public.bes_supplemental_sessions s where s.id=p_session_id for update; if not found then raise exception 'Không tìm thấy buổi Học bổ sung.'; end if; if v_existing.roster_frozen_at is not null or v_existing.status<>'scheduled' then raise exception 'Buổi đã bắt đầu/chốt hoặc đã hủy nên không thể thay đổi.'; end if; end if;
 if p_session_id is null then insert into public.bes_supplemental_sessions(group_id,kind,title,attendance_date,subject,teacher_id,teacher_name,teacher_email,room,start_time,end_time,status,session_note,created_by,updated_by,created_at,updated_at) values(p_group_id,v_kind,coalesce(nullif(btrim(p_title),''),btrim(p_subject)||' · '||p_attendance_date::text),p_attendance_date,btrim(p_subject),p_teacher_id,btrim(coalesce(p_teacher_name,'')),btrim(coalesce(p_teacher_email,'')),btrim(coalesce(p_room,'')),p_start_time,p_end_time,'scheduled',btrim(coalesce(p_session_note,'')),v_uid,v_uid,clock_timestamp(),clock_timestamp()) returning * into v_row;
 else update public.bes_supplemental_sessions s set group_id=p_group_id,kind=v_kind,title=coalesce(nullif(btrim(p_title),''),btrim(p_subject)||' · '||p_attendance_date::text),attendance_date=p_attendance_date,subject=btrim(p_subject),teacher_id=p_teacher_id,teacher_name=btrim(coalesce(p_teacher_name,'')),teacher_email=btrim(coalesce(p_teacher_email,'')),room=btrim(coalesce(p_room,'')),start_time=p_start_time,end_time=p_end_time,session_note=btrim(coalesce(p_session_note,'')),updated_by=v_uid,updated_at=clock_timestamp() where s.id=p_session_id returning * into v_row; end if;
 if v_kind='adhoc' then
  if cardinality(coalesce(p_participant_ids,'{}'::uuid[]))=0 then raise exception 'Buổi phát sinh cần ít nhất một học sinh.'; end if; if cardinality(p_participant_ids)<>(select count(distinct x) from unnest(p_participant_ids) x) then raise exception 'Danh sách có học sinh bị chọn trùng.'; end if;
  if exists(select 1 from unnest(p_participant_ids) x left join public.bes_supplemental_students st on st.id=x where st.id is null or st.active=false) then raise exception 'Danh sách có học sinh không tồn tại hoặc đã ngừng hoạt động.'; end if;
  if (select count(*) from(select distinct private.bes_supplemental_canonical_key(x) from unnest(p_participant_ids) x) q)<>cardinality(p_participant_ids) then raise exception 'Danh sách có hai hồ sơ cùng một học sinh chính thức.'; end if;
  delete from public.bes_supplemental_session_participants p where p.session_id=v_row.id;
  insert into public.bes_supplemental_session_participants(session_id,student_id,canonical_student_key,student_code_snapshot,full_name_snapshot,school_class_snapshot,updated_at) select v_row.id,st.id,private.bes_supplemental_canonical_key(st.id),st.student_code,st.full_name,st.school_class_name,clock_timestamp() from public.bes_supplemental_students st where st.id=any(p_participant_ids);
 end if; return to_jsonb(v_row); end; $function$;

CREATE OR REPLACE FUNCTION private.bes_can_upload_supplemental_proof(p_object_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select private.bes_is_supplemental_manager()
    and exists (
      select 1
      from public.bes_supplemental_sessions s
      where p_object_name ~ ('^' || s.id::text || '/[0-9]+-attendance-proof[.]jpg$')
        and nullif(btrim(s.proof_path), '') is null
        and s.status = 'confirmed'
        and s.checked_by = auth.uid()
    );
$function$;

CREATE OR REPLACE FUNCTION private.bes_cancel_supplemental_session(p_session_id uuid, p_reason text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$ declare v_uid uuid:=private.bes_require_supplemental_admin(); v_row public.bes_supplemental_sessions%rowtype;
begin select * into v_row from public.bes_supplemental_sessions s where s.id=p_session_id for update; if not found then raise exception 'Không tìm thấy buổi Học bổ sung.'; end if; if v_row.status='confirmed' then raise exception 'Buổi đã chốt điểm danh không thể hủy.'; end if; if v_row.status='cancelled' then return to_jsonb(v_row); end if; update public.bes_supplemental_sessions s set status='cancelled',cancellation_reason=btrim(coalesce(p_reason,'')),updated_by=v_uid,updated_at=clock_timestamp() where s.id=p_session_id returning * into v_row; return to_jsonb(v_row); end; $function$;

CREATE OR REPLACE FUNCTION private.bes_confirm_supplemental_attendance(p_session_id uuid, p_participants jsonb, p_session_note text DEFAULT ''::text, p_proof_path text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid:=private.bes_require_supplemental_manager();
  v_session public.bes_supplemental_sessions%rowtype;
  v_profile public.profiles%rowtype;
  v_access jsonb;
  v_expected integer;
  v_payload_count integer;
  v_present integer;
  v_absent integer;
  v_tardy integer;
begin
  if v_uid is null then
    raise exception 'Bạn cần đăng nhập để điểm danh.';
  end if;

  select * into v_session
  from public.bes_supplemental_sessions s
  where s.id=p_session_id
  for update;

  if not found then raise exception 'Không tìm thấy buổi Học bổ sung.'; end if;
  if v_session.status='cancelled' then raise exception 'Buổi Học bổ sung đã bị hủy.'; end if;
  if v_session.status='confirmed' then raise exception 'Buổi Học bổ sung đã chốt điểm danh.'; end if;
  if v_session.roster_frozen_at is null or v_session.status<>'in_progress' then
    raise exception 'Hãy bắt đầu điểm danh để khóa danh sách học sinh trước.';
  end if;

  v_access:=private.attendance_supplemental_access_decision();
  if coalesce((v_access->>'allowed')::boolean,false) is not true then
    raise exception '%',coalesce(v_access->>'reason','attendance_not_allowed');
  end if;

  if jsonb_typeof(p_participants)<>'array' then
    raise exception 'Dữ liệu điểm danh không hợp lệ.';
  end if;

  select count(*) into v_expected
  from public.bes_supplemental_session_participants p
  where p.session_id=v_session.id;

  select count(*) into v_payload_count
  from jsonb_array_elements(p_participants);

  if v_payload_count<>v_expected then
    raise exception 'Dữ liệu điểm danh phải có đúng toàn bộ học sinh của danh sách đã khóa.';
  end if;

  if (select count(distinct x->>'participantId') from jsonb_array_elements(p_participants) x)<>v_expected then
    raise exception 'Mỗi học sinh chỉ được gửi một trạng thái điểm danh.';
  end if;

  if exists(
    select 1
    from jsonb_array_elements(p_participants) x
    left join public.bes_supplemental_session_participants p
      on p.id::text=x->>'participantId' and p.session_id=v_session.id
    where p.id is null or coalesce(x->>'status','') not in('present','absent','tardy')
  ) then
    raise exception 'Danh sách hoặc trạng thái điểm danh không hợp lệ.';
  end if;

  update public.bes_supplemental_session_participants p
  set attendance_status=x.status,
      absence_reason_code=case when x.status='absent' then x.absence_reason_code else '' end,
      absence_note=case when x.status='absent' then x.absence_note else '' end,
      recorded_at=clock_timestamp(),
      updated_at=clock_timestamp()
  from (
    select (j->>'participantId')::uuid participant_id,
           j->>'status' status,
           coalesce(j->>'absenceReasonCode','') absence_reason_code,
           coalesce(j->>'absenceNote','') absence_note
    from jsonb_array_elements(p_participants) j
  ) x
  where p.id=x.participant_id and p.session_id=v_session.id;

  select count(*) filter(where p.attendance_status='present'),
         count(*) filter(where p.attendance_status='absent'),
         count(*) filter(where p.attendance_status='tardy')
  into v_present,v_absent,v_tardy
  from public.bes_supplemental_session_participants p
  where p.session_id=v_session.id;

  if coalesce(v_present,0)+coalesce(v_absent,0)+coalesce(v_tardy,0)<>v_expected then
    raise exception 'Chưa có trạng thái hợp lệ cho toàn bộ học sinh.';
  end if;

  select * into v_profile from public.profiles p where p.id=v_uid;

  update public.bes_supplemental_sessions s
  set status='confirmed',
      attendance_confirmed_at=clock_timestamp(),
      checked_by=v_uid,
      checked_by_name=coalesce(v_profile.full_name,v_profile.email,''),
      session_note=btrim(coalesce(p_session_note,'')),
      proof_path='',
      total_students=v_expected,
      present_count=coalesce(v_present,0),
      absent_count=coalesce(v_absent,0),
      tardy_count=coalesce(v_tardy,0),
      updated_by=v_uid,
      updated_at=clock_timestamp()
  where s.id=v_session.id
  returning * into v_session;

  return jsonb_build_object(
    'session',to_jsonb(v_session),
    'participants',coalesce((
      select jsonb_agg(to_jsonb(p) order by p.full_name_snapshot)
      from public.bes_supplemental_session_participants p
      where p.session_id=v_session.id
    ),'[]'::jsonb),
    'serverNow',clock_timestamp()
  );
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_set_supplemental_membership(p_membership_id uuid DEFAULT NULL::uuid, p_group_id uuid DEFAULT NULL::uuid, p_student_id uuid DEFAULT NULL::uuid, p_effective_from date DEFAULT CURRENT_DATE, p_effective_until date DEFAULT NULL::date, p_removal_reason text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$ declare v_uid uuid:=private.bes_require_supplemental_admin(); v_row public.bes_supplemental_group_memberships%rowtype; v_canonical text;
begin
 if p_group_id is null or p_student_id is null then raise exception 'Nhóm và học sinh là bắt buộc.'; end if; if p_effective_until is not null and p_effective_until<p_effective_from then raise exception 'Ngày ngừng tham gia không hợp lệ.'; end if;
 if not exists(select 1 from public.bes_supplemental_groups g where g.id=p_group_id) then raise exception 'Không tìm thấy nhóm Học bổ sung.'; end if; if not exists(select 1 from public.bes_supplemental_students s where s.id=p_student_id and s.active=true) then raise exception 'Không tìm thấy học sinh đang hoạt động.'; end if;
 v_canonical:=private.bes_supplemental_canonical_key(p_student_id);
 if exists(select 1 from public.bes_supplemental_group_memberships m where m.group_id=p_group_id and m.id<>coalesce(p_membership_id,'00000000-0000-0000-0000-000000000000'::uuid) and private.bes_supplemental_canonical_key(m.student_id)=v_canonical and daterange(m.effective_from,coalesce(m.effective_until+1,'infinity'::date),'[)')&&daterange(p_effective_from,coalesce(p_effective_until+1,'infinity'::date),'[)')) then raise exception 'Học sinh đã có khoảng thời gian tham gia trùng trong nhóm này.'; end if;
 if p_membership_id is null then insert into public.bes_supplemental_group_memberships(group_id,student_id,effective_from,effective_until,removal_reason,created_by,updated_by,created_at,updated_at) values(p_group_id,p_student_id,p_effective_from,p_effective_until,btrim(coalesce(p_removal_reason,'')),v_uid,v_uid,clock_timestamp(),clock_timestamp()) returning * into v_row;
 else update public.bes_supplemental_group_memberships m set group_id=p_group_id,student_id=p_student_id,effective_from=p_effective_from,effective_until=p_effective_until,removal_reason=btrim(coalesce(p_removal_reason,'')),updated_by=v_uid,updated_at=clock_timestamp() where m.id=p_membership_id returning * into v_row; if not found then raise exception 'Không tìm thấy thành viên nhóm.'; end if; end if; return to_jsonb(v_row); end; $function$;

CREATE OR REPLACE FUNCTION private.bes_supplemental_student_report(p_from date DEFAULT (CURRENT_DATE - 365), p_to date DEFAULT CURRENT_DATE, p_student_key text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$ begin perform private.bes_require_supplemental_reader(array['attendance:report']); return coalesce((with report_rows as(
 select case when nullif(btrim(st.linked_official_key),'') is not null then 'official:'||lower(btrim(st.linked_official_key)) when st.source_type='official' and nullif(btrim(st.official_key),'') is not null then 'official:'||lower(btrim(st.official_key)) else p.canonical_student_key end canonical_key,p.student_code_snapshot,p.full_name_snapshot,p.school_class_snapshot,p.attendance_status,s.id session_id,s.attendance_date,s.subject
 from public.bes_supplemental_session_participants p join public.bes_supplemental_sessions s on s.id=p.session_id and s.status='confirmed' left join public.bes_supplemental_students st on st.id=p.student_id where s.attendance_date between p_from and p_to), grouped as(
 select r.canonical_key,(array_agg(r.student_code_snapshot order by r.attendance_date desc))[1] student_code,(array_agg(r.full_name_snapshot order by r.attendance_date desc))[1] full_name,(array_agg(r.school_class_snapshot order by r.attendance_date desc))[1] school_class_name,count(distinct r.session_id) eligible_session_count,count(*) filter(where r.attendance_status='present') present_count,count(*) filter(where r.attendance_status='absent') absent_count,count(*) filter(where r.attendance_status='tardy') tardy_count,min(r.attendance_date) first_date,max(r.attendance_date) last_date,array_agg(distinct r.subject order by r.subject) subjects from report_rows r where p_student_key is null or r.canonical_key=p_student_key group by r.canonical_key)
 select jsonb_agg(jsonb_build_object('canonicalStudentKey',g.canonical_key,'studentCode',g.student_code,'fullName',g.full_name,'schoolClassName',g.school_class_name,'subjects',to_jsonb(g.subjects),'eligibleSessionCount',g.eligible_session_count,'presentCount',g.present_count,'absentCount',g.absent_count,'tardyCount',g.tardy_count,'attendanceRate',case when g.eligible_session_count=0 then 0 else round(((g.present_count+g.tardy_count)::numeric*100)/g.eligible_session_count,1) end,'firstDate',g.first_date,'lastDate',g.last_date) order by g.school_class_name,g.full_name) from grouped g),'[]'::jsonb); end; $function$;

CREATE OR REPLACE FUNCTION private.bes_upsert_supplemental_group(p_group_id uuid DEFAULT NULL::uuid, p_group_name text DEFAULT ''::text, p_subject text DEFAULT ''::text, p_grade_level text DEFAULT ''::text, p_teacher_id uuid DEFAULT NULL::uuid, p_teacher_name text DEFAULT ''::text, p_teacher_email text DEFAULT ''::text, p_room text DEFAULT ''::text, p_start_date date DEFAULT CURRENT_DATE, p_end_date date DEFAULT CURRENT_DATE, p_weekdays smallint[] DEFAULT ARRAY[(1)::smallint], p_start_time time without time zone DEFAULT '16:45:00'::time without time zone, p_end_time time without time zone DEFAULT '18:00:00'::time without time zone, p_active boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$ declare v_uid uuid:=private.bes_require_supplemental_admin(); v_row public.bes_supplemental_groups%rowtype;
begin
 if nullif(btrim(p_group_name),'') is null or nullif(btrim(p_subject),'') is null then raise exception 'Tên nhóm và môn học là bắt buộc.'; end if; if p_end_date<p_start_date then raise exception 'Ngày kết thúc không hợp lệ.'; end if; if p_start_time=p_end_time then raise exception 'Giờ bắt đầu và kết thúc phải khác nhau.'; end if; if cardinality(p_weekdays)=0 or not(p_weekdays<@array[1,2,3,4,5,6,7]::smallint[]) then raise exception 'Thứ trong tuần không hợp lệ.'; end if;
 if p_group_id is null then insert into public.bes_supplemental_groups(group_name,subject,grade_level,teacher_id,teacher_name,teacher_email,room,start_date,end_date,weekdays,start_time,end_time,active,created_by,updated_by,created_at,updated_at) values(btrim(p_group_name),btrim(p_subject),btrim(coalesce(p_grade_level,'')),p_teacher_id,btrim(coalesce(p_teacher_name,'')),btrim(coalesce(p_teacher_email,'')),btrim(coalesce(p_room,'')),p_start_date,p_end_date,p_weekdays,p_start_time,p_end_time,coalesce(p_active,true),v_uid,v_uid,clock_timestamp(),clock_timestamp()) returning * into v_row;
 else update public.bes_supplemental_groups g set group_name=btrim(p_group_name),subject=btrim(p_subject),grade_level=btrim(coalesce(p_grade_level,'')),teacher_id=p_teacher_id,teacher_name=btrim(coalesce(p_teacher_name,'')),teacher_email=btrim(coalesce(p_teacher_email,'')),room=btrim(coalesce(p_room,'')),start_date=p_start_date,end_date=p_end_date,weekdays=p_weekdays,start_time=p_start_time,end_time=p_end_time,active=coalesce(p_active,g.active),updated_by=v_uid,updated_at=clock_timestamp() where g.id=p_group_id returning * into v_row; if not found then raise exception 'Không tìm thấy nhóm Học bổ sung.'; end if; end if;
 perform private.bes_materialize_supplemental_group_sessions(v_row.id); return to_jsonb(v_row); end; $function$;

CREATE FUNCTION private.bes_is_supplemental_manager()
RETURNS boolean LANGUAGE sql STABLE SET search_path = ''
AS $$ SELECT private.attendance_can_manage_roster(); $$;

CREATE OR REPLACE FUNCTION private.bes_attach_supplemental_proof(p_session_id uuid, p_proof_path text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.bes_require_supplemental_manager();
  v_session public.bes_supplemental_sessions%rowtype;
  v_path text := btrim(coalesce(p_proof_path, ''));
begin
  if v_path !~ ('^' || p_session_id::text || '/[0-9]+-attendance-proof[.]jpg$') then
    raise exception 'Đường dẫn minh chứng không hợp lệ.';
  end if;
  select * into v_session
  from public.bes_supplemental_sessions s
  where s.id = p_session_id
  for update;
  if not found then raise exception 'Không tìm thấy buổi Học bổ sung.'; end if;
  if v_session.status <> 'confirmed' then raise exception 'Chỉ buổi đã chốt mới được gắn minh chứng.'; end if;
  if v_session.checked_by is distinct from v_uid then raise exception 'Chỉ người chốt điểm danh mới được gắn minh chứng.'; end if;
  if nullif(v_session.proof_path, '') is not null then
    raise exception 'Buổi này đã có ảnh minh chứng.' using errcode = '23505';
  end if;
  if not exists (
    select 1 from storage.objects o
    where o.bucket_id = 'attendance-session-proofs' and o.name = v_path and o.owner_id = v_uid::text
  ) then raise exception 'Ảnh minh chứng chưa được tải lên máy chủ.'; end if;

  update public.bes_supplemental_sessions s
  set proof_path = v_path, updated_by = v_uid, updated_at = clock_timestamp()
  where s.id = p_session_id
  returning * into v_session;
  return to_jsonb(v_session);
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_begin_supplemental_attendance(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid:=private.bes_require_supplemental_manager();
  v_session public.bes_supplemental_sessions%rowtype;
  v_access jsonb;
begin
  if v_uid is null then raise exception 'Bạn cần đăng nhập để điểm danh.'; end if;

  select * into v_session
  from public.bes_supplemental_sessions s
  where s.id=p_session_id
  for update;

  if not found then raise exception 'Không tìm thấy buổi Học bổ sung.'; end if;
  if v_session.status='cancelled' then raise exception 'Buổi Học bổ sung đã bị hủy.'; end if;
  if v_session.status='confirmed' then raise exception 'Buổi Học bổ sung đã chốt điểm danh.'; end if;

  v_access:=private.attendance_supplemental_access_decision();
  if coalesce((v_access->>'allowed')::boolean,false) is not true then
    raise exception '%',coalesce(v_access->>'reason','attendance_not_allowed');
  end if;

  -- A recurring session remains configuration-driven until it is confirmed.
  -- This repairs sessions that were opened/frozen while the group roster was still empty.
  if v_session.kind='recurring' then
    delete from public.bes_supplemental_session_participants p
    where p.session_id=v_session.id;

    insert into public.bes_supplemental_session_participants(
      session_id,student_id,canonical_student_key,student_code_snapshot,
      full_name_snapshot,school_class_snapshot,updated_at
    )
    select distinct on(private.bes_supplemental_canonical_key(st.id))
      v_session.id,
      st.id,
      private.bes_supplemental_canonical_key(st.id),
      st.student_code,
      st.full_name,
      st.school_class_name,
      clock_timestamp()
    from public.bes_supplemental_group_memberships m
    join public.bes_supplemental_students st on st.id=m.student_id and st.active=true
    where m.group_id=v_session.group_id
      and m.effective_from<=v_session.attendance_date
      and (m.effective_until is null or m.effective_until>=v_session.attendance_date)
    order by private.bes_supplemental_canonical_key(st.id),st.id;

    update public.bes_supplemental_sessions s
    set roster_frozen_at=clock_timestamp(),
        status='in_progress',
        total_students=(
          select count(*)
          from public.bes_supplemental_session_participants p
          where p.session_id=v_session.id
        ),
        updated_by=v_uid,
        updated_at=clock_timestamp()
    where s.id=v_session.id
    returning * into v_session;

  elsif v_session.roster_frozen_at is null then
    if not exists(
      select 1
      from public.bes_supplemental_session_participants p
      where p.session_id=v_session.id
    ) then
      raise exception 'Buổi phát sinh chưa có học sinh.';
    end if;

    update public.bes_supplemental_session_participants p
    set canonical_student_key=private.bes_supplemental_canonical_key(st.id),
        student_code_snapshot=st.student_code,
        full_name_snapshot=st.full_name,
        school_class_snapshot=st.school_class_name,
        updated_at=clock_timestamp()
    from public.bes_supplemental_students st
    where p.session_id=v_session.id and st.id=p.student_id;

    update public.bes_supplemental_sessions s
    set roster_frozen_at=clock_timestamp(),
        status='in_progress',
        total_students=(
          select count(*)
          from public.bes_supplemental_session_participants p
          where p.session_id=v_session.id
        ),
        updated_by=v_uid,
        updated_at=clock_timestamp()
    where s.id=v_session.id
    returning * into v_session;

  elsif v_session.status='scheduled' then
    update public.bes_supplemental_sessions s
    set status='in_progress',updated_by=v_uid,updated_at=clock_timestamp()
    where s.id=v_session.id
    returning * into v_session;
  end if;

  return jsonb_build_object(
    'session',to_jsonb(v_session),
    'participants',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',p.id,
        'studentId',p.student_id,
        'canonicalStudentKey',p.canonical_student_key,
        'studentCode',p.student_code_snapshot,
        'fullName',p.full_name_snapshot,
        'schoolClassName',p.school_class_snapshot,
        'status',coalesce(p.attendance_status,'present'),
        'absenceReasonCode',p.absence_reason_code,
        'absenceNote',p.absence_note
      ) order by p.full_name_snapshot)
      from public.bes_supplemental_session_participants p
      where p.session_id=v_session.id
    ),'[]'::jsonb),
    'access',v_access,
    'serverNow',clock_timestamp()
  );
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_list_attendance_activities(p_from date DEFAULT CURRENT_DATE, p_to date DEFAULT CURRENT_DATE, p_activity_type text DEFAULT 'all'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_type text := lower(btrim(coalesce(p_activity_type, 'all')));
  v_can_extra boolean := EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.approved);
  v_can_supplemental boolean := private.bes_is_supplemental_manager();
begin
  if v_type not in ('all', 'remedial', 'enrichment', 'supplemental') then
    raise exception 'Loại hoạt động không hợp lệ.';
  end if;
  if v_type = 'supplemental' and not v_can_supplemental then
    raise exception 'Tài khoản không có quyền truy cập Học bổ sung.' using errcode = '42501';
  end if;
  if v_type in ('remedial', 'enrichment') and not v_can_extra then
    raise exception 'Tài khoản không có quyền xem dữ liệu Điểm danh.' using errcode = '42501';
  end if;
  if v_type = 'all' and not (v_can_extra or v_can_supplemental) then
    raise exception 'Tài khoản không có quyền xem dữ liệu Điểm danh.' using errcode = '42501';
  end if;

  return coalesce((
    with activities as (
      select
        x.id::text as id,
        'extra'::text as source,
        case when lower(coalesce(x.class_type, '')) in ('gifted', 'enrichment') then 'enrichment' else 'remedial' end as activity_type,
        x.class_name as title,
        x.subject,
        x.teacher_name,
        x.attendance_date,
        x.teaching_time_range as time_range,
        x.teaching_room as room,
        x.total_students as participant_count,
        x.present_count,
        x.absent_count,
        (select count(*) from public.bes_extra_attendance_records r where r.session_id = x.id and lower(coalesce(r.status, '')) in ('late','tardy'))::integer as tardy_count,
        x.session_status as status,
        null::text as supplemental_kind
      from public.bes_extra_attendance_sessions x
      where v_can_extra and private.attendance_can_read_class(x.class_id) and x.attendance_date between p_from and p_to

      union all

      select
        s.id::text,
        'supplemental',
        'supplemental',
        s.title,
        s.subject,
        s.teacher_name,
        s.attendance_date,
        to_char(s.start_time, 'HH24:MI') || '–' || to_char(s.end_time, 'HH24:MI'),
        s.room,
        case
          when s.kind = 'recurring' and s.status in ('scheduled', 'in_progress') then (
            select count(distinct private.bes_supplemental_canonical_key(m.student_id))
            from public.bes_supplemental_group_memberships m
            join public.bes_supplemental_students st on st.id = m.student_id and st.active = true
            where m.group_id = s.group_id
              and m.effective_from <= s.attendance_date
              and (m.effective_until is null or m.effective_until >= s.attendance_date)
          )::integer
          else (
            select count(*) from public.bes_supplemental_session_participants p where p.session_id = s.id
          )::integer
        end,
        s.present_count,
        s.absent_count,
        s.tardy_count,
        s.status,
        s.kind
      from public.bes_supplemental_sessions s
      where v_can_supplemental and s.attendance_date between p_from and p_to
    )
    select jsonb_agg(jsonb_build_object(
      'id', a.id,
      'source', a.source,
      'activityType', a.activity_type,
      'title', a.title,
      'subject', a.subject,
      'teacherName', a.teacher_name,
      'date', a.attendance_date,
      'timeRange', a.time_range,
      'room', a.room,
      'participantCount', a.participant_count,
      'totalStudents', a.participant_count,
      'presentCount', coalesce(a.present_count, 0),
      'absentCount', coalesce(a.absent_count, 0),
      'tardyCount', coalesce(a.tardy_count, 0),
      'status', a.status,
      'supplementalKind', a.supplemental_kind
    ) order by a.attendance_date, a.time_range, a.title)
    from activities a
    where v_type = 'all' or a.activity_type = v_type
  ), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_list_supplemental_attendance(p_from date DEFAULT CURRENT_DATE, p_to date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform private.bes_require_supplemental_reader(array['attendance:calendar','attendance:quick','attendance:history','attendance:report']);
  if p_to < p_from then raise exception 'Khoảng ngày không hợp lệ.'; end if;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id',s.id,
        'groupId',s.group_id,
        'kind',s.kind,
        'title',s.title,
        'groupName',g.group_name,
        'attendanceDate',s.attendance_date,
        'subject',s.subject,
        'teacherId',s.teacher_id,
        'teacherName',s.teacher_name,
        'teacherEmail',s.teacher_email,
        'room',s.room,
        'startTime',to_char(s.start_time,'HH24:MI'),
        'endTime',to_char(s.end_time,'HH24:MI'),
        'timeRange',to_char(s.start_time,'HH24:MI')||'–'||to_char(s.end_time,'HH24:MI'),
        'status',s.status,
        'participantCount',case
          when s.kind='recurring' and s.status in ('scheduled','in_progress') then (
            select count(distinct private.bes_supplemental_canonical_key(m.student_id))
            from public.bes_supplemental_group_memberships m
            join public.bes_supplemental_students st on st.id=m.student_id and st.active=true
            where m.group_id=s.group_id
              and m.effective_from<=s.attendance_date
              and (m.effective_until is null or m.effective_until>=s.attendance_date)
          )
          else (
            select count(*)
            from public.bes_supplemental_session_participants p
            where p.session_id=s.id
          )
        end,
        'rosterFrozenAt',s.roster_frozen_at,
        'sessionNote',s.session_note,
        'proofPath',s.proof_path
      ) order by s.attendance_date,s.start_time,s.title
    )
    from public.bes_supplemental_sessions s
    left join public.bes_supplemental_groups g on g.id=s.group_id
    where s.attendance_date between p_from and p_to
      and (s.group_id is null or (g.id is not null and g.active = true and g.archived_at is null))
  ),'[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_upsert_supplemental_student(p_student_id uuid DEFAULT NULL::uuid, p_source_type text DEFAULT 'manual'::text, p_official_key text DEFAULT NULL::text, p_student_code text DEFAULT ''::text, p_full_name text DEFAULT ''::text, p_school_class_name text DEFAULT ''::text, p_active boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.bes_require_supplemental_admin();
  v_row public.bes_supplemental_students%rowtype;
  v_source text := lower(btrim(coalesce(p_source_type,'manual')));
  v_official_key text := nullif(btrim(p_official_key),'');
  v_candidate record;
  v_candidate_found boolean := false;
begin
  if v_source not in ('official','manual') then
    raise exception 'Loại học sinh không hợp lệ.';
  end if;

  if v_source='official' then
    if v_official_key is null then
      raise exception 'Học sinh chính thức phải có khóa định danh.';
    end if;

    select c.* into v_candidate
    from private.bes_supplemental_official_candidates() c
    where lower(c.official_key)=lower(v_official_key)
    limit 1;
    v_candidate_found := found;

    if not v_candidate_found and not exists (
      select 1
      from public.bes_supplemental_students s
      where s.id=coalesce(p_student_id,s.id)
        and s.source_type='official'
        and lower(s.official_key)=lower(v_official_key)
    ) then
      raise exception 'Không tìm thấy học sinh chính thức trong dữ liệu nhà trường.';
    end if;

    if p_student_id is null then
      select * into v_row
      from public.bes_supplemental_students s
      where s.source_type='official' and lower(s.official_key)=lower(v_official_key)
      for update;

      if found then
        update public.bes_supplemental_students s
        set student_code=case when v_candidate_found then coalesce(v_candidate.student_code,'') else s.student_code end,
            full_name=case when v_candidate_found then coalesce(v_candidate.full_name,s.full_name) else s.full_name end,
            school_class_name=case when v_candidate_found then coalesce(v_candidate.school_class_name,'') else s.school_class_name end,
            active=coalesce(p_active,s.active),
            updated_by=v_uid,
            updated_at=clock_timestamp()
        where s.id=v_row.id
        returning * into v_row;
        return to_jsonb(v_row);
      end if;

      insert into public.bes_supplemental_students(
        source_type,official_key,student_code,full_name,school_class_name,active,
        created_by,updated_by,created_at,updated_at
      ) values (
        'official',v_official_key,
        coalesce(v_candidate.student_code,''),
        coalesce(v_candidate.full_name,''),
        coalesce(v_candidate.school_class_name,''),
        coalesce(p_active,true),v_uid,v_uid,clock_timestamp(),clock_timestamp()
      ) returning * into v_row;
      return to_jsonb(v_row);
    end if;

    if exists (
      select 1 from public.bes_supplemental_students s
      where s.id<>p_student_id
        and s.source_type='official'
        and lower(s.official_key)=lower(v_official_key)
    ) then
      raise exception 'Học sinh chính thức này đã có hồ sơ Học bổ sung khác.';
    end if;

    update public.bes_supplemental_students s
    set source_type='official',
        official_key=v_official_key,
        linked_official_key=null,
        student_code=case when v_candidate_found then coalesce(v_candidate.student_code,'') else s.student_code end,
        full_name=case when v_candidate_found then coalesce(v_candidate.full_name,s.full_name) else s.full_name end,
        school_class_name=case when v_candidate_found then coalesce(v_candidate.school_class_name,'') else s.school_class_name end,
        active=coalesce(p_active,s.active),
        updated_by=v_uid,
        updated_at=clock_timestamp()
    where s.id=p_student_id
    returning * into v_row;
    if not found then raise exception 'Không tìm thấy học sinh Học bổ sung.'; end if;
    return to_jsonb(v_row);
  end if;

  if nullif(btrim(p_full_name),'') is null then
    raise exception 'Họ tên học sinh là bắt buộc.';
  end if;

  if p_student_id is null then
    insert into public.bes_supplemental_students(
      source_type,official_key,linked_official_key,student_code,full_name,
      school_class_name,active,created_by,updated_by,created_at,updated_at
    ) values (
      'manual',null,null,btrim(coalesce(p_student_code,'')),btrim(p_full_name),
      btrim(coalesce(p_school_class_name,'')),coalesce(p_active,true),
      v_uid,v_uid,clock_timestamp(),clock_timestamp()
    ) returning * into v_row;
  else
    update public.bes_supplemental_students s
    set source_type='manual',
        official_key=null,
        student_code=btrim(coalesce(p_student_code,'')),
        full_name=btrim(p_full_name),
        school_class_name=btrim(coalesce(p_school_class_name,'')),
        active=coalesce(p_active,s.active),
        updated_by=v_uid,
        updated_at=clock_timestamp()
    where s.id=p_student_id
    returning * into v_row;
    if not found then raise exception 'Không tìm thấy học sinh Học bổ sung.'; end if;
  end if;
  return to_jsonb(v_row);
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_archive_supplemental_class(p_group_id uuid, p_reason text DEFAULT 'Lớp đã được lưu trữ'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.bes_require_supplemental_manager();
  v_group public.bes_supplemental_groups%rowtype;
  v_reason text := coalesce(nullif(btrim(p_reason), ''), 'Lớp đã được lưu trữ');
begin
  select * into v_group
  from public.bes_supplemental_groups g
  where g.id = p_group_id
  for update;
  if not found then raise exception 'Không tìm thấy lớp Học bổ sung.'; end if;

  if v_group.archived_at is null then
    update public.bes_supplemental_groups g
    set active = false,
        archived_at = clock_timestamp(),
        archived_by = v_uid,
        updated_by = v_uid,
        updated_at = clock_timestamp()
    where g.id = p_group_id
    returning * into v_group;

    update public.bes_supplemental_sessions s
    set status = 'cancelled',
        cancellation_reason = v_reason,
        updated_by = v_uid,
        updated_at = clock_timestamp()
    where s.group_id = p_group_id
      and s.kind = 'recurring'
      and s.status = 'scheduled'
      and s.roster_frozen_at is null
      and s.attendance_date >= current_date;
  end if;

  return to_jsonb(v_group);
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_list_supplemental_classes(p_include_archived boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform private.bes_require_supplemental_manager();

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', g.id,
        'className', g.group_name,
        'groupName', g.group_name,
        'subject', g.subject,
        'gradeLevel', g.grade_level,
        'room', g.room,
        'startDate', g.start_date,
        'endDate', g.end_date,
        'weekdays', to_jsonb(g.weekdays),
        'startTime', to_char(g.start_time, 'HH24:MI'),
        'endTime', to_char(g.end_time, 'HH24:MI'),
        'active', g.active,
        'note', g.note,
        'archivedAt', g.archived_at,
        'archivedBy', g.archived_by,
        'teachers', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', t.id,
            'teacherId', t.teacher_id,
            'fullName', t.teacher_name,
            'email', t.teacher_email,
            'position', t.position
          ) order by t.position, t.teacher_name)
          from public.bes_supplemental_group_teachers t
          where t.group_id = g.id
        ), '[]'::jsonb),
        'members', coalesce((
          select jsonb_agg(jsonb_build_object(
            'membershipId', lm.membership_id,
            'studentId', lm.student_id,
            'studentCode', lm.student_code,
            'fullName', lm.full_name,
            'schoolClassName', lm.school_class_name,
            'effectiveFrom', lm.effective_from,
            'effectiveUntil', lm.effective_until,
            'removalReason', lm.removal_reason,
            'status', case when lm.effective_until is null and lm.student_active then 'active' else 'stopped' end
          ) order by lm.full_name, lm.student_code)
          from (
            select distinct on (m.student_id)
              m.id membership_id,
              m.student_id,
              st.student_code,
              st.full_name,
              st.school_class_name,
              st.active student_active,
              m.effective_from,
              m.effective_until,
              m.removal_reason
            from public.bes_supplemental_group_memberships m
            join public.bes_supplemental_students st on st.id = m.student_id
            where m.group_id = g.id
            order by m.student_id, m.effective_from desc, m.created_at desc
          ) lm
        ), '[]'::jsonb),
        'activeStudentCount', (
          select count(distinct m.student_id)
          from public.bes_supplemental_group_memberships m
          join public.bes_supplemental_students st on st.id = m.student_id
          where m.group_id = g.id
            and m.effective_until is null
            and st.active = true
        ),
        'nextSession', (
          select jsonb_build_object(
            'id', s.id,
            'date', s.attendance_date,
            'status', s.status,
            'startTime', to_char(s.start_time, 'HH24:MI'),
            'endTime', to_char(s.end_time, 'HH24:MI')
          )
          from public.bes_supplemental_sessions s
          where s.group_id = g.id
            and s.kind = 'recurring'
            and s.status in ('scheduled', 'in_progress')
            and s.attendance_date >= current_date
          order by s.attendance_date, s.start_time
          limit 1
        )
      )
      order by (g.archived_at is not null), g.active desc, g.group_name
    )
    from public.bes_supplemental_groups g
    where coalesce(p_include_archived, true) or g.archived_at is null
  ), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_set_supplemental_class_member_status(p_group_id uuid, p_student_id uuid, p_active boolean, p_effective_date date DEFAULT CURRENT_DATE, p_removal_reason text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.bes_require_supplemental_manager();
  v_group public.bes_supplemental_groups%rowtype;
  v_student public.bes_supplemental_students%rowtype;
  v_membership public.bes_supplemental_group_memberships%rowtype;
  v_date date := coalesce(p_effective_date, current_date);
begin
  select * into v_group
  from public.bes_supplemental_groups g
  where g.id = p_group_id
  for update;
  if not found then raise exception 'Không tìm thấy lớp Học bổ sung.'; end if;
  if v_group.archived_at is not null then raise exception 'Lớp đã được lưu trữ.'; end if;

  select * into v_student
  from public.bes_supplemental_students s
  where s.id = p_student_id
  for update;
  if not found then raise exception 'Không tìm thấy học sinh.'; end if;

  select * into v_membership
  from public.bes_supplemental_group_memberships m
  where m.group_id = p_group_id
    and m.student_id = p_student_id
    and m.effective_until is null
  order by m.effective_from desc, m.created_at desc
  limit 1
  for update;

  if coalesce(p_active, false) then
    if v_membership.id is null then
      insert into public.bes_supplemental_group_memberships (
        group_id, student_id, effective_from, effective_until, removal_reason,
        created_by, updated_by, created_at, updated_at
      ) values (
        p_group_id, p_student_id, v_date, null, '',
        v_uid, v_uid, clock_timestamp(), clock_timestamp()
      ) returning * into v_membership;
    end if;
    update public.bes_supplemental_students s
    set active = true, updated_by = v_uid, updated_at = clock_timestamp()
    where s.id = p_student_id;
  else
    if v_membership.id is not null then
      update public.bes_supplemental_group_memberships m
      set effective_until = greatest(m.effective_from, v_date),
          removal_reason = btrim(coalesce(p_removal_reason, '')),
          updated_by = v_uid,
          updated_at = clock_timestamp()
      where m.id = v_membership.id
      returning * into v_membership;
    end if;

    update public.bes_supplemental_students s
    set active = exists (
          select 1
          from public.bes_supplemental_group_memberships m
          where m.student_id = p_student_id
            and m.effective_until is null
        ),
        updated_by = v_uid,
        updated_at = clock_timestamp()
    where s.id = p_student_id;
  end if;

  select * into v_student from public.bes_supplemental_students s where s.id = p_student_id;
  return jsonb_build_object(
    'student', to_jsonb(v_student),
    'membership', to_jsonb(v_membership),
    'status', case when coalesce(p_active, false) then 'active' else 'stopped' end
  );
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_set_supplemental_class_teachers(p_group_id uuid, p_teachers jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.bes_require_supplemental_manager();
  v_group public.bes_supplemental_groups%rowtype;
  v_primary public.bes_supplemental_group_teachers%rowtype;
begin
  select * into v_group
  from public.bes_supplemental_groups g
  where g.id = p_group_id
  for update;

  if not found then raise exception 'Không tìm thấy lớp Học bổ sung.'; end if;
  if v_group.archived_at is not null then raise exception 'Lớp đã được lưu trữ.'; end if;
  if jsonb_typeof(coalesce(p_teachers, '[]'::jsonb)) <> 'array' then
    raise exception 'Danh sách giáo viên không hợp lệ.';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(coalesce(p_teachers, '[]'::jsonb)) item
    where nullif(btrim(coalesce(item->>'fullName', item->>'teacherName', '')), '') is null
  ) then
    raise exception 'Họ và tên giáo viên không được để trống.';
  end if;

  delete from public.bes_supplemental_group_teachers t
  where t.group_id = p_group_id;

  insert into public.bes_supplemental_group_teachers (
    group_id, teacher_id, teacher_name, teacher_email, position,
    created_by, updated_by, created_at, updated_at
  )
  select
    p_group_id,
    case
      when nullif(btrim(coalesce(item->>'teacherId', '')), '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
        then (item->>'teacherId')::uuid
      else null
    end,
    btrim(coalesce(item->>'fullName', item->>'teacherName', '')),
    btrim(coalesce(item->>'email', item->>'teacherEmail', '')),
    ordinality::integer,
    v_uid,
    v_uid,
    clock_timestamp(),
    clock_timestamp()
  from jsonb_array_elements(coalesce(p_teachers, '[]'::jsonb)) with ordinality as payload(item, ordinality)
  on conflict do nothing;

  select * into v_primary
  from public.bes_supplemental_group_teachers t
  where t.group_id = p_group_id
  order by t.position, t.created_at
  limit 1;

  update public.bes_supplemental_groups g
  set teacher_id = case when v_primary.id is null then null else v_primary.teacher_id end,
      teacher_name = case when v_primary.id is null then '' else v_primary.teacher_name end,
      teacher_email = case when v_primary.id is null then '' else v_primary.teacher_email end,
      updated_by = v_uid,
      updated_at = clock_timestamp()
  where g.id = p_group_id
  returning * into v_group;

  perform private.bes_materialize_supplemental_group_sessions(p_group_id);

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', t.id,
      'teacherId', t.teacher_id,
      'fullName', t.teacher_name,
      'email', t.teacher_email,
      'position', t.position
    ) order by t.position, t.teacher_name)
    from public.bes_supplemental_group_teachers t
    where t.group_id = p_group_id
  ), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_upsert_supplemental_class(p_group_name text, p_subject text, p_grade_level text, p_start_date date, p_end_date date, p_weekdays smallint[], p_start_time time without time zone, p_end_time time without time zone, p_group_id uuid DEFAULT NULL::uuid, p_room text DEFAULT ''::text, p_note text DEFAULT ''::text, p_active boolean DEFAULT true, p_teachers jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.bes_require_supplemental_manager();
  v_group public.bes_supplemental_groups%rowtype;
  v_name text := btrim(coalesce(p_group_name, ''));
  v_subject text := btrim(coalesce(p_subject, ''));
  v_grade text := btrim(coalesce(p_grade_level, ''));
begin
  if v_name = '' or v_subject = '' or v_grade = '' then
    raise exception 'Tên lớp, môn học và khối không được để trống.';
  end if;
  if p_start_date is null or p_end_date is null or p_end_date < p_start_date then
    raise exception 'Khoảng ngày của lớp không hợp lệ.';
  end if;
  if p_start_time is null or p_end_time is null or p_start_time = p_end_time then
    raise exception 'Khung giờ của lớp không hợp lệ.';
  end if;
  if coalesce(cardinality(p_weekdays), 0) = 0
     or not (p_weekdays <@ array[1,2,3,4,5,6,7]::smallint[]) then
    raise exception 'Hãy chọn ít nhất một thứ học hợp lệ trong tuần.';
  end if;

  if p_group_id is null then
    insert into public.bes_supplemental_groups (
      group_name, subject, grade_level, teacher_id, teacher_name, teacher_email,
      room, start_date, end_date, weekdays, start_time, end_time, active, note,
      archived_at, archived_by, created_by, updated_by, created_at, updated_at
    ) values (
      v_name, v_subject, v_grade, null, '', '', btrim(coalesce(p_room, '')),
      p_start_date, p_end_date, p_weekdays, p_start_time, p_end_time,
      coalesce(p_active, true), btrim(coalesce(p_note, '')), null, null,
      v_uid, v_uid, clock_timestamp(), clock_timestamp()
    ) returning * into v_group;
  else
    select * into v_group
    from public.bes_supplemental_groups g
    where g.id = p_group_id
    for update;
    if not found then raise exception 'Không tìm thấy lớp Học bổ sung.'; end if;
    if v_group.archived_at is not null then raise exception 'Lớp đã được lưu trữ.'; end if;

    update public.bes_supplemental_groups g
    set group_name = v_name,
        subject = v_subject,
        grade_level = v_grade,
        room = btrim(coalesce(p_room, '')),
        start_date = p_start_date,
        end_date = p_end_date,
        weekdays = p_weekdays,
        start_time = p_start_time,
        end_time = p_end_time,
        active = coalesce(p_active, true),
        note = btrim(coalesce(p_note, '')),
        updated_by = v_uid,
        updated_at = clock_timestamp()
    where g.id = p_group_id
    returning * into v_group;
  end if;

  perform private.bes_set_supplemental_class_teachers(v_group.id, coalesce(p_teachers, '[]'::jsonb));

  select * into v_group from public.bes_supplemental_groups g where g.id = v_group.id;
  return to_jsonb(v_group) || jsonb_build_object(
    'className', v_group.group_name,
    'note', v_group.note
  );
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_upsert_supplemental_class_member(p_group_id uuid, p_full_name text, p_student_id uuid DEFAULT NULL::uuid, p_student_code text DEFAULT ''::text, p_school_class_name text DEFAULT ''::text, p_effective_from date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.bes_require_supplemental_manager();
  v_group public.bes_supplemental_groups%rowtype;
  v_student public.bes_supplemental_students%rowtype;
  v_membership public.bes_supplemental_group_memberships%rowtype;
  v_name text := btrim(coalesce(p_full_name, ''));
  v_code text := btrim(coalesce(p_student_code, ''));
  v_school_class text := btrim(coalesce(p_school_class_name, ''));
begin
  if v_name = '' then raise exception 'Họ và tên học sinh không được để trống.'; end if;

  select * into v_group
  from public.bes_supplemental_groups g
  where g.id = p_group_id and g.archived_at is null and g.active = true
  for update;
  if not found then raise exception 'Lớp Học bổ sung không hoạt động hoặc đã được lưu trữ.'; end if;

  if p_student_id is not null then
    select * into v_student
    from public.bes_supplemental_students s
    where s.id = p_student_id
    for update;
    if not found then raise exception 'Không tìm thấy học sinh.'; end if;
  elsif v_code <> '' then
    select * into v_student
    from public.bes_supplemental_students s
    where lower(btrim(s.student_code)) = lower(v_code)
      and s.source_type = 'manual'
      and s.linked_official_key is null
    order by s.active desc, s.updated_at desc
    limit 1
    for update;
  end if;

  if v_student.id is null then
    insert into public.bes_supplemental_students (
      source_type, official_key, linked_official_key, student_code, full_name,
      school_class_name, active, created_by, updated_by, created_at, updated_at
    ) values (
      'manual', null, null, v_code, v_name, v_school_class, true,
      v_uid, v_uid, clock_timestamp(), clock_timestamp()
    ) returning * into v_student;
  else
    update public.bes_supplemental_students s
    set student_code = v_code,
        full_name = v_name,
        school_class_name = v_school_class,
        active = true,
        updated_by = v_uid,
        updated_at = clock_timestamp()
    where s.id = v_student.id
    returning * into v_student;
  end if;

  select * into v_membership
  from public.bes_supplemental_group_memberships m
  where m.group_id = p_group_id
    and m.student_id = v_student.id
    and m.effective_until is null
  order by m.effective_from desc, m.created_at desc
  limit 1
  for update;

  if v_membership.id is null then
    insert into public.bes_supplemental_group_memberships (
      group_id, student_id, effective_from, effective_until, removal_reason,
      created_by, updated_by, created_at, updated_at
    ) values (
      p_group_id, v_student.id, coalesce(p_effective_from, current_date), null, '',
      v_uid, v_uid, clock_timestamp(), clock_timestamp()
    ) returning * into v_membership;
  end if;

  return jsonb_build_object(
    'student', to_jsonb(v_student),
    'membership', to_jsonb(v_membership),
    'status', 'active'
  );
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_can_view_supplemental_proof(p_object_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select private.bes_is_supplemental_manager()
    and exists (
      select 1
      from public.bes_supplemental_sessions s
      where s.id::text = split_part(coalesce(p_object_name, ''), '/', 1)
        and s.status = 'confirmed'
        and nullif(btrim(s.proof_path), '') is not null
        and s.proof_path = p_object_name
    );
$function$;

CREATE OR REPLACE FUNCTION private.bes_archive_attendance_history(p_source_type text, p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_actor_name text := '';
  v_source text := lower(trim(coalesce(p_source_type, '')));
  v_extra public.bes_extra_attendance_sessions%rowtype;
  v_supp public.bes_supplemental_sessions%rowtype;
  v_records jsonb := '[]'::jsonb;
  v_archive_id uuid;
begin
  if not private.attendance_can_move_history() then
    raise exception 'Bạn không có quyền lưu trữ lịch sử điểm danh.' using errcode = '42501';
  end if;

  if v_source = 'supplemental' and not private.attendance_can_manage_roster() then
    raise exception 'Bạn không có quyền lưu trữ Học bổ sung.' using errcode='42501';
  end if;
  if v_source not in ('extra', 'supplemental') then
    raise exception 'Nguồn dữ liệu điểm danh không hợp lệ.' using errcode = '22023';
  end if;

  select coalesce(nullif(trim(p.full_name), ''), p.email, '')
  into v_actor_name
  from public.profiles p
  where p.id = v_uid;

  if v_source = 'extra' then
    select * into v_extra
    from public.bes_extra_attendance_sessions s
    where s.id = p_session_id
    for update;

    if not found then
      select a.id into v_archive_id
      from public.bes_attendance_archive a
      where a.source_type = 'extra' and a.source_session_id = p_session_id
      order by a.archived_at desc
      limit 1;
      if found then
        return jsonb_build_object('archive_id', v_archive_id, 'source_type', 'extra', 'already_archived', true);
      end if;
      raise exception 'Không tìm thấy buổi điểm danh cần lưu trữ.' using errcode = 'P0002';
    end if;

    select coalesce(jsonb_agg(to_jsonb(r) order by r.student_full_name, r.id), '[]'::jsonb)
    into v_records
    from public.bes_extra_attendance_records r
    where r.session_id = p_session_id;

    insert into public.bes_attendance_archive (
      source_type, source_session_id, class_name, subject, teacher_name,
      attendance_date, checked_at, session_status, proof_path,
      session_snapshot, records_snapshot, archived_by, archived_by_name
    ) values (
      'extra', v_extra.id, v_extra.class_name, v_extra.subject, v_extra.teacher_name,
      v_extra.attendance_date, v_extra.checked_at, v_extra.session_status,
      coalesce(v_extra.proof_path, ''), to_jsonb(v_extra), v_records, v_uid, coalesce(v_actor_name, '')
    )
    returning id into v_archive_id;

    -- Records cascade from the session. The proof object is intentionally retained.
    delete from public.bes_extra_attendance_sessions s where s.id = p_session_id;
  else
    select * into v_supp
    from public.bes_supplemental_sessions s
    where s.id = p_session_id
    for update;

    if not found then
      raise exception 'Không tìm thấy buổi Học bổ sung cần lưu trữ.' using errcode = 'P0002';
    end if;
    if v_supp.status not in ('confirmed', 'cancelled') then
      raise exception 'Buổi Học bổ sung này chưa có lịch sử đã chốt để lưu trữ.' using errcode = '22023';
    end if;

    select coalesce(jsonb_agg(to_jsonb(p) order by p.full_name_snapshot, p.id), '[]'::jsonb)
    into v_records
    from public.bes_supplemental_session_participants p
    where p.session_id = p_session_id;

    insert into public.bes_attendance_archive (
      source_type, source_session_id, class_name, subject, teacher_name,
      attendance_date, checked_at, session_status, proof_path,
      session_snapshot, records_snapshot, archived_by, archived_by_name
    ) values (
      'supplemental', v_supp.id, coalesce(nullif(v_supp.title, ''), 'Học bổ sung'),
      v_supp.subject, v_supp.teacher_name, v_supp.attendance_date,
      v_supp.attendance_confirmed_at, v_supp.status, coalesce(v_supp.proof_path, ''),
      to_jsonb(v_supp), v_records, v_uid, coalesce(v_actor_name, '')
    )
    returning id into v_archive_id;

    -- Preserve the scheduled session itself so recurring planning stays intact,
    -- but remove its confirmed/cancelled history state. Keep proof only in archive.
    if v_supp.kind = 'recurring' then
      delete from public.bes_supplemental_session_participants p
      where p.session_id = p_session_id;
    else
      update public.bes_supplemental_session_participants p
      set attendance_status = null,
          absence_reason_code = '',
          absence_note = '',
          recorded_at = null,
          updated_at = clock_timestamp()
      where p.session_id = p_session_id;
    end if;

    update public.bes_supplemental_sessions s
    set status = 'scheduled',
        cancellation_reason = '',
        roster_frozen_at = null,
        attendance_confirmed_at = null,
        checked_by = null,
        checked_by_name = '',
        session_note = '',
        proof_path = '',
        total_students = 0,
        present_count = 0,
        absent_count = 0,
        tardy_count = 0,
        lesson_periods = 1,
        updated_by = v_uid,
        updated_at = clock_timestamp()
    where s.id = p_session_id;
  end if;

  return jsonb_build_object(
    'archive_id', v_archive_id,
    'source_type', v_source,
    'source_session_id', p_session_id,
    'archived', true
  );
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_restore_attendance_archive(p_archive_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_archive public.bes_attendance_archive%rowtype;
  v_extra public.bes_extra_attendance_sessions%rowtype;
  v_supp public.bes_supplemental_sessions%rowtype;
begin
  if not private.attendance_can_move_history() then
    raise exception 'Bạn không có quyền khôi phục lịch sử điểm danh.' using errcode = '42501';
  end if;

  select * into v_archive
  from public.bes_attendance_archive a
  where a.id = p_archive_id
  for update;
  if not found then
    raise exception 'Không tìm thấy mục lưu trữ cần khôi phục.' using errcode = 'P0002';
  end if;
  if v_archive.source_type = 'supplemental' and not private.attendance_can_manage_roster() then
    raise exception 'Bạn không có quyền khôi phục Học bổ sung.' using errcode='42501';
  end if;
  if v_archive.delete_request_status = 'pending' then
    raise exception 'Yêu cầu xóa đang chờ duyệt. Từ chối yêu cầu trước khi khôi phục.' using errcode='22023';
  end if;
  if v_archive.delete_request_status = 'approved' then
    raise exception 'Mục này đã được Admin duyệt xóa và đang chờ hoàn tất, không thể khôi phục.' using errcode = '22023';
  end if;

  if v_archive.source_type = 'extra' then
    select * into v_extra
    from jsonb_populate_record(null::public.bes_extra_attendance_sessions, v_archive.session_snapshot);

    if not exists (select 1 from public.bes_extra_classes c where c.id = v_extra.class_id) then
      raise exception 'Lớp gốc không còn tồn tại nên chưa thể khôi phục buổi điểm danh.' using errcode = '23503';
    end if;
    if exists (
      select 1 from public.bes_extra_attendance_sessions s
      where s.id = v_extra.id or (s.class_id = v_extra.class_id and s.attendance_date = v_extra.attendance_date)
    ) then
      raise exception 'Ngày này đã có một buổi điểm danh mới. Không thể khôi phục chồng dữ liệu.' using errcode = '23505';
    end if;

    insert into public.bes_extra_attendance_sessions
    select * from jsonb_populate_record(null::public.bes_extra_attendance_sessions, v_archive.session_snapshot);

    insert into public.bes_extra_attendance_records (
      id, session_id, class_id, member_id, member_key, student_code,
      student_full_name, school_class_name, status, recorded_at,
      absence_reason_code, absence_note
    )
    select
      r.id, r.session_id, r.class_id,
      case when r.member_id is null or exists (
        select 1 from public.bes_extra_class_members m where m.id = r.member_id
      ) then r.member_id else null end,
      r.member_key, r.student_code, r.student_full_name, r.school_class_name,
      r.status, r.recorded_at, r.absence_reason_code, r.absence_note
    from jsonb_populate_recordset(
      null::public.bes_extra_attendance_records,
      v_archive.records_snapshot
    ) r;
  else
    select * into v_supp
    from jsonb_populate_record(null::public.bes_supplemental_sessions, v_archive.session_snapshot);

    if exists (select 1 from public.bes_supplemental_sessions s where s.id = v_supp.id) then
      if exists (
        select 1
        from public.bes_supplemental_sessions s
        where s.id = v_supp.id
          and (
            s.status <> 'scheduled'
            or s.roster_frozen_at is not null
            or s.attendance_confirmed_at is not null
            or s.checked_by is not null
            or trim(coalesce(s.proof_path, '')) <> ''
          )
      ) then
        raise exception 'Buổi Học bổ sung này đã có dữ liệu điểm danh mới. Không thể khôi phục chồng dữ liệu.' using errcode = '23505';
      end if;

      update public.bes_supplemental_sessions s
      set group_id = v_supp.group_id,
          kind = v_supp.kind,
          title = v_supp.title,
          attendance_date = v_supp.attendance_date,
          subject = v_supp.subject,
          teacher_id = v_supp.teacher_id,
          teacher_name = v_supp.teacher_name,
          teacher_email = v_supp.teacher_email,
          room = v_supp.room,
          start_time = v_supp.start_time,
          end_time = v_supp.end_time,
          status = v_supp.status,
          cancellation_reason = v_supp.cancellation_reason,
          roster_frozen_at = v_supp.roster_frozen_at,
          attendance_confirmed_at = v_supp.attendance_confirmed_at,
          checked_by = v_supp.checked_by,
          checked_by_name = v_supp.checked_by_name,
          session_note = v_supp.session_note,
          proof_path = v_supp.proof_path,
          total_students = v_supp.total_students,
          present_count = v_supp.present_count,
          absent_count = v_supp.absent_count,
          tardy_count = v_supp.tardy_count,
          created_by = v_supp.created_by,
          updated_by = v_supp.updated_by,
          created_at = v_supp.created_at,
          updated_at = v_supp.updated_at,
          lesson_periods = v_supp.lesson_periods
      where s.id = v_supp.id;
    else
      if v_supp.group_id is not null and exists (
        select 1 from public.bes_supplemental_sessions s
        where s.group_id = v_supp.group_id and s.attendance_date = v_supp.attendance_date
      ) then
        raise exception 'Ngày này đã có một buổi Học bổ sung mới. Không thể khôi phục chồng dữ liệu.' using errcode = '23505';
      end if;
      insert into public.bes_supplemental_sessions
      select * from jsonb_populate_record(null::public.bes_supplemental_sessions, v_archive.session_snapshot);
    end if;

    delete from public.bes_supplemental_session_participants p
    where p.session_id = v_supp.id;

    insert into public.bes_supplemental_session_participants
    select * from jsonb_populate_recordset(
      null::public.bes_supplemental_session_participants,
      v_archive.records_snapshot
    );
  end if;

  delete from public.bes_attendance_archive a where a.id = p_archive_id;

  return jsonb_build_object(
    'archive_id', p_archive_id,
    'source_type', v_archive.source_type,
    'source_session_id', v_archive.source_session_id,
    'restored', true
  );
end;
$function$;

REVOKE ALL ON FUNCTION private.bes_confirm_supplemental_attendance_v2(uuid, jsonb, text, text, numeric, text, text, time without time zone, time without time zone) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_confirm_supplemental_attendance_v2(uuid, jsonb, text, text, numeric, text, text, time without time zone, time without time zone) TO authenticated;
CREATE FUNCTION public.bes_confirm_supplemental_attendance_v2(p_session_id uuid, p_participants jsonb, p_session_note text DEFAULT ''::text, p_proof_path text DEFAULT ''::text, p_lesson_periods numeric DEFAULT 1, p_teacher_name text DEFAULT ''::text, p_room text DEFAULT ''::text, p_start_time time without time zone DEFAULT NULL::time without time zone, p_end_time time without time zone DEFAULT NULL::time without time zone) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_confirm_supplemental_attendance_v2(p_session_id, p_participants, p_session_note, p_proof_path, p_lesson_periods, p_teacher_name, p_room, p_start_time, p_end_time);
$$;
REVOKE ALL ON FUNCTION public.bes_confirm_supplemental_attendance_v2(uuid, jsonb, text, text, numeric, text, text, time without time zone, time without time zone) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_confirm_supplemental_attendance_v2(uuid, jsonb, text, text, numeric, text, text, time without time zone, time without time zone) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_delete_supplemental_attendance_history(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_delete_supplemental_attendance_history(uuid) TO authenticated;
CREATE FUNCTION public.bes_delete_supplemental_attendance_history(p_session_id uuid) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_delete_supplemental_attendance_history(p_session_id);
$$;
REVOKE ALL ON FUNCTION public.bes_delete_supplemental_attendance_history(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_delete_supplemental_attendance_history(uuid) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_get_supplemental_attendance_edit_snapshot(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_get_supplemental_attendance_edit_snapshot(uuid) TO authenticated;
CREATE FUNCTION public.bes_get_supplemental_attendance_edit_snapshot(p_session_id uuid) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_get_supplemental_attendance_edit_snapshot(p_session_id);
$$;
REVOKE ALL ON FUNCTION public.bes_get_supplemental_attendance_edit_snapshot(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_get_supplemental_attendance_edit_snapshot(uuid) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_list_supplemental_history(date, date, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_list_supplemental_history(date, date, text) TO authenticated;
CREATE FUNCTION public.bes_list_supplemental_history(p_from date DEFAULT (CURRENT_DATE - 31), p_to date DEFAULT CURRENT_DATE, p_query text DEFAULT ''::text) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_list_supplemental_history(p_from, p_to, p_query);
$$;
REVOKE ALL ON FUNCTION public.bes_list_supplemental_history(date, date, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_list_supplemental_history(date, date, text) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_list_supplemental_session_teachers(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_list_supplemental_session_teachers(uuid) TO authenticated;
CREATE FUNCTION public.bes_list_supplemental_session_teachers(p_session_id uuid) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_list_supplemental_session_teachers(p_session_id);
$$;
REVOKE ALL ON FUNCTION public.bes_list_supplemental_session_teachers(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_list_supplemental_session_teachers(uuid) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_update_supplemental_attendance_session(uuid, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_update_supplemental_attendance_session(uuid, jsonb, text) TO authenticated;
CREATE FUNCTION public.bes_update_supplemental_attendance_session(p_session_id uuid, p_records jsonb, p_note text DEFAULT ''::text) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_update_supplemental_attendance_session(p_session_id, p_records, p_note);
$$;
REVOKE ALL ON FUNCTION public.bes_update_supplemental_attendance_session(uuid, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_update_supplemental_attendance_session(uuid, jsonb, text) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_clear_supplemental_edit_audit_on_reset() FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION private.bes_require_supplemental_reader(text[]) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION private.bes_supplemental_attendance_edit_decision(uuid, timestamp with time zone) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION private.bes_supplemental_canonical_key(uuid) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION private.bes_supplemental_official_candidates() FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION private.bes_materialize_supplemental_group_sessions(uuid) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION private.bes_require_supplemental_admin() FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION private.bes_require_supplemental_manager() FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION private.bes_link_supplemental_student(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_link_supplemental_student(uuid, text) TO authenticated;
CREATE FUNCTION public.bes_link_supplemental_student(p_student_id uuid, p_official_key text) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_link_supplemental_student(p_student_id, p_official_key);
$$;
REVOKE ALL ON FUNCTION public.bes_link_supplemental_student(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_link_supplemental_student(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_list_supplemental_admin_data() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_list_supplemental_admin_data() TO authenticated;
CREATE FUNCTION public.bes_list_supplemental_admin_data() RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_list_supplemental_admin_data();
$$;
REVOKE ALL ON FUNCTION public.bes_list_supplemental_admin_data() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_list_supplemental_admin_data() TO authenticated;

REVOKE ALL ON FUNCTION private.bes_upsert_supplemental_session(uuid, uuid, text, text, date, text, uuid, text, text, text, time without time zone, time without time zone, uuid[], text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_upsert_supplemental_session(uuid, uuid, text, text, date, text, uuid, text, text, text, time without time zone, time without time zone, uuid[], text) TO authenticated;
CREATE FUNCTION public.bes_upsert_supplemental_session(p_session_id uuid DEFAULT NULL::uuid, p_group_id uuid DEFAULT NULL::uuid, p_kind text DEFAULT 'adhoc'::text, p_title text DEFAULT ''::text, p_attendance_date date DEFAULT CURRENT_DATE, p_subject text DEFAULT ''::text, p_teacher_id uuid DEFAULT NULL::uuid, p_teacher_name text DEFAULT ''::text, p_teacher_email text DEFAULT ''::text, p_room text DEFAULT ''::text, p_start_time time without time zone DEFAULT '16:45:00'::time without time zone, p_end_time time without time zone DEFAULT '18:00:00'::time without time zone, p_participant_ids uuid[] DEFAULT '{}'::uuid[], p_session_note text DEFAULT ''::text) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_upsert_supplemental_session(p_session_id, p_group_id, p_kind, p_title, p_attendance_date, p_subject, p_teacher_id, p_teacher_name, p_teacher_email, p_room, p_start_time, p_end_time, p_participant_ids, p_session_note);
$$;
REVOKE ALL ON FUNCTION public.bes_upsert_supplemental_session(uuid, uuid, text, text, date, text, uuid, text, text, text, time without time zone, time without time zone, uuid[], text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_upsert_supplemental_session(uuid, uuid, text, text, date, text, uuid, text, text, text, time without time zone, time without time zone, uuid[], text) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_can_upload_supplemental_proof(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_can_upload_supplemental_proof(text) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_cancel_supplemental_session(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_cancel_supplemental_session(uuid, text) TO authenticated;
CREATE FUNCTION public.bes_cancel_supplemental_session(p_session_id uuid, p_reason text DEFAULT ''::text) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_cancel_supplemental_session(p_session_id, p_reason);
$$;
REVOKE ALL ON FUNCTION public.bes_cancel_supplemental_session(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_cancel_supplemental_session(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_confirm_supplemental_attendance(uuid, jsonb, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_confirm_supplemental_attendance(uuid, jsonb, text, text) TO authenticated;
CREATE FUNCTION public.bes_confirm_supplemental_attendance(p_session_id uuid, p_participants jsonb, p_session_note text DEFAULT ''::text, p_proof_path text DEFAULT ''::text) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_confirm_supplemental_attendance(p_session_id, p_participants, p_session_note, p_proof_path);
$$;
REVOKE ALL ON FUNCTION public.bes_confirm_supplemental_attendance(uuid, jsonb, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_confirm_supplemental_attendance(uuid, jsonb, text, text) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_set_supplemental_membership(uuid, uuid, uuid, date, date, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_set_supplemental_membership(uuid, uuid, uuid, date, date, text) TO authenticated;
CREATE FUNCTION public.bes_set_supplemental_membership(p_membership_id uuid DEFAULT NULL::uuid, p_group_id uuid DEFAULT NULL::uuid, p_student_id uuid DEFAULT NULL::uuid, p_effective_from date DEFAULT CURRENT_DATE, p_effective_until date DEFAULT NULL::date, p_removal_reason text DEFAULT ''::text) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_set_supplemental_membership(p_membership_id, p_group_id, p_student_id, p_effective_from, p_effective_until, p_removal_reason);
$$;
REVOKE ALL ON FUNCTION public.bes_set_supplemental_membership(uuid, uuid, uuid, date, date, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_set_supplemental_membership(uuid, uuid, uuid, date, date, text) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_supplemental_student_report(date, date, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_supplemental_student_report(date, date, text) TO authenticated;
CREATE FUNCTION public.bes_supplemental_student_report(p_from date DEFAULT (CURRENT_DATE - 365), p_to date DEFAULT CURRENT_DATE, p_student_key text DEFAULT NULL::text) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_supplemental_student_report(p_from, p_to, p_student_key);
$$;
REVOKE ALL ON FUNCTION public.bes_supplemental_student_report(date, date, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_supplemental_student_report(date, date, text) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_upsert_supplemental_group(uuid, text, text, text, uuid, text, text, text, date, date, smallint[], time without time zone, time without time zone, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_upsert_supplemental_group(uuid, text, text, text, uuid, text, text, text, date, date, smallint[], time without time zone, time without time zone, boolean) TO authenticated;
CREATE FUNCTION public.bes_upsert_supplemental_group(p_group_id uuid DEFAULT NULL::uuid, p_group_name text DEFAULT ''::text, p_subject text DEFAULT ''::text, p_grade_level text DEFAULT ''::text, p_teacher_id uuid DEFAULT NULL::uuid, p_teacher_name text DEFAULT ''::text, p_teacher_email text DEFAULT ''::text, p_room text DEFAULT ''::text, p_start_date date DEFAULT CURRENT_DATE, p_end_date date DEFAULT CURRENT_DATE, p_weekdays smallint[] DEFAULT ARRAY[(1)::smallint], p_start_time time without time zone DEFAULT '16:45:00'::time without time zone, p_end_time time without time zone DEFAULT '18:00:00'::time without time zone, p_active boolean DEFAULT true) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_upsert_supplemental_group(p_group_id, p_group_name, p_subject, p_grade_level, p_teacher_id, p_teacher_name, p_teacher_email, p_room, p_start_date, p_end_date, p_weekdays, p_start_time, p_end_time, p_active);
$$;
REVOKE ALL ON FUNCTION public.bes_upsert_supplemental_group(uuid, text, text, text, uuid, text, text, text, date, date, smallint[], time without time zone, time without time zone, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_upsert_supplemental_group(uuid, text, text, text, uuid, text, text, text, date, date, smallint[], time without time zone, time without time zone, boolean) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_is_supplemental_manager() FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION private.bes_attach_supplemental_proof(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_attach_supplemental_proof(uuid, text) TO authenticated;
CREATE FUNCTION public.bes_attach_supplemental_proof(p_session_id uuid, p_proof_path text) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_attach_supplemental_proof(p_session_id, p_proof_path);
$$;
REVOKE ALL ON FUNCTION public.bes_attach_supplemental_proof(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_attach_supplemental_proof(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_begin_supplemental_attendance(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_begin_supplemental_attendance(uuid) TO authenticated;
CREATE FUNCTION public.bes_begin_supplemental_attendance(p_session_id uuid) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_begin_supplemental_attendance(p_session_id);
$$;
REVOKE ALL ON FUNCTION public.bes_begin_supplemental_attendance(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_begin_supplemental_attendance(uuid) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_list_attendance_activities(date, date, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_list_attendance_activities(date, date, text) TO authenticated;
CREATE FUNCTION public.bes_list_attendance_activities(p_from date DEFAULT CURRENT_DATE, p_to date DEFAULT CURRENT_DATE, p_activity_type text DEFAULT 'all'::text) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_list_attendance_activities(p_from, p_to, p_activity_type);
$$;
REVOKE ALL ON FUNCTION public.bes_list_attendance_activities(date, date, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_list_attendance_activities(date, date, text) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_list_supplemental_attendance(date, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_list_supplemental_attendance(date, date) TO authenticated;
CREATE FUNCTION public.bes_list_supplemental_attendance(p_from date DEFAULT CURRENT_DATE, p_to date DEFAULT CURRENT_DATE) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_list_supplemental_attendance(p_from, p_to);
$$;
REVOKE ALL ON FUNCTION public.bes_list_supplemental_attendance(date, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_list_supplemental_attendance(date, date) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_upsert_supplemental_student(uuid, text, text, text, text, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_upsert_supplemental_student(uuid, text, text, text, text, text, boolean) TO authenticated;
CREATE FUNCTION public.bes_upsert_supplemental_student(p_student_id uuid DEFAULT NULL::uuid, p_source_type text DEFAULT 'manual'::text, p_official_key text DEFAULT NULL::text, p_student_code text DEFAULT ''::text, p_full_name text DEFAULT ''::text, p_school_class_name text DEFAULT ''::text, p_active boolean DEFAULT true) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_upsert_supplemental_student(p_student_id, p_source_type, p_official_key, p_student_code, p_full_name, p_school_class_name, p_active);
$$;
REVOKE ALL ON FUNCTION public.bes_upsert_supplemental_student(uuid, text, text, text, text, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_upsert_supplemental_student(uuid, text, text, text, text, text, boolean) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_archive_supplemental_class(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_archive_supplemental_class(uuid, text) TO authenticated;
CREATE FUNCTION public.bes_archive_supplemental_class(p_group_id uuid, p_reason text DEFAULT 'Lớp đã được lưu trữ'::text) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_archive_supplemental_class(p_group_id, p_reason);
$$;
REVOKE ALL ON FUNCTION public.bes_archive_supplemental_class(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_archive_supplemental_class(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_list_supplemental_classes(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_list_supplemental_classes(boolean) TO authenticated;
CREATE FUNCTION public.bes_list_supplemental_classes(p_include_archived boolean DEFAULT true) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_list_supplemental_classes(p_include_archived);
$$;
REVOKE ALL ON FUNCTION public.bes_list_supplemental_classes(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_list_supplemental_classes(boolean) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_set_supplemental_class_member_status(uuid, uuid, boolean, date, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_set_supplemental_class_member_status(uuid, uuid, boolean, date, text) TO authenticated;
CREATE FUNCTION public.bes_set_supplemental_class_member_status(p_group_id uuid, p_student_id uuid, p_active boolean, p_effective_date date DEFAULT CURRENT_DATE, p_removal_reason text DEFAULT ''::text) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_set_supplemental_class_member_status(p_group_id, p_student_id, p_active, p_effective_date, p_removal_reason);
$$;
REVOKE ALL ON FUNCTION public.bes_set_supplemental_class_member_status(uuid, uuid, boolean, date, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_set_supplemental_class_member_status(uuid, uuid, boolean, date, text) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_set_supplemental_class_teachers(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_set_supplemental_class_teachers(uuid, jsonb) TO authenticated;
CREATE FUNCTION public.bes_set_supplemental_class_teachers(p_group_id uuid, p_teachers jsonb DEFAULT '[]'::jsonb) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_set_supplemental_class_teachers(p_group_id, p_teachers);
$$;
REVOKE ALL ON FUNCTION public.bes_set_supplemental_class_teachers(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_set_supplemental_class_teachers(uuid, jsonb) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_upsert_supplemental_class(text, text, text, date, date, smallint[], time without time zone, time without time zone, uuid, text, text, boolean, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_upsert_supplemental_class(text, text, text, date, date, smallint[], time without time zone, time without time zone, uuid, text, text, boolean, jsonb) TO authenticated;
CREATE FUNCTION public.bes_upsert_supplemental_class(p_group_name text, p_subject text, p_grade_level text, p_start_date date, p_end_date date, p_weekdays smallint[], p_start_time time without time zone, p_end_time time without time zone, p_group_id uuid DEFAULT NULL::uuid, p_room text DEFAULT ''::text, p_note text DEFAULT ''::text, p_active boolean DEFAULT true, p_teachers jsonb DEFAULT '[]'::jsonb) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_upsert_supplemental_class(p_group_name, p_subject, p_grade_level, p_start_date, p_end_date, p_weekdays, p_start_time, p_end_time, p_group_id, p_room, p_note, p_active, p_teachers);
$$;
REVOKE ALL ON FUNCTION public.bes_upsert_supplemental_class(text, text, text, date, date, smallint[], time without time zone, time without time zone, uuid, text, text, boolean, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_upsert_supplemental_class(text, text, text, date, date, smallint[], time without time zone, time without time zone, uuid, text, text, boolean, jsonb) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_upsert_supplemental_class_member(uuid, text, uuid, text, text, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_upsert_supplemental_class_member(uuid, text, uuid, text, text, date) TO authenticated;
CREATE FUNCTION public.bes_upsert_supplemental_class_member(p_group_id uuid, p_full_name text, p_student_id uuid DEFAULT NULL::uuid, p_student_code text DEFAULT ''::text, p_school_class_name text DEFAULT ''::text, p_effective_from date DEFAULT CURRENT_DATE) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_upsert_supplemental_class_member(p_group_id, p_full_name, p_student_id, p_student_code, p_school_class_name, p_effective_from);
$$;
REVOKE ALL ON FUNCTION public.bes_upsert_supplemental_class_member(uuid, text, uuid, text, text, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_upsert_supplemental_class_member(uuid, text, uuid, text, text, date) TO authenticated;

REVOKE ALL ON FUNCTION private.bes_can_view_supplemental_proof(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_can_view_supplemental_proof(text) TO authenticated;


CREATE TRIGGER attendance_clear_supplemental_edit_audit
AFTER UPDATE OF status ON public.bes_supplemental_sessions
FOR EACH ROW EXECUTE FUNCTION private.bes_clear_supplemental_edit_audit_on_reset();

CREATE POLICY attendance_supplemental_proof_upload ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'attendance-session-proofs'
    AND private.bes_can_upload_supplemental_proof(name));
CREATE POLICY attendance_supplemental_proof_read ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'attendance-session-proofs' AND (
    private.bes_can_view_supplemental_proof(name)
    OR (owner_id = (SELECT auth.uid())::text AND private.bes_can_upload_supplemental_proof(name))));
CREATE POLICY attendance_supplemental_proof_cleanup ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'attendance-session-proofs' AND owner_id = (SELECT auth.uid())::text
    AND private.bes_can_upload_supplemental_proof(name));

NOTIFY pgrst, 'reload schema';
COMMIT;
