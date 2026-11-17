BEGIN;

-- Only explicit roster managers and administrators with MFA can manage classes.
CREATE FUNCTION private.attendance_can_manage_roster()
RETURNS boolean LANGUAGE sql STABLE SET search_path = ''
AS $$
  SELECT private.attendance_is_admin()
    OR private.attendance_global_permission('attendance:manage');
$$;
REVOKE ALL ON FUNCTION private.attendance_can_manage_roster() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.attendance_can_manage_roster() TO authenticated;

CREATE FUNCTION private.attendance_can_move_history()
RETURNS boolean LANGUAGE sql STABLE SET search_path = ''
AS $$
  SELECT private.attendance_is_admin()
    OR private.attendance_global_permission('attendance:delete');
$$;
REVOKE ALL ON FUNCTION private.attendance_can_move_history() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.attendance_can_move_history() TO authenticated;

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
          OR private.attendance_global_permission('attendance:manage')
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

-- Match the columns written by the existing class and roster forms. Actor IDs,
-- row IDs and membership ownership cannot be reassigned through the forms.
GRANT INSERT (class_type, class_name, subject, teacher_id, teacher_name, teacher_email,
  active, source_key, school_year, grade_level, updated_by, updated_at, created_by),
  UPDATE (class_type, class_name, subject, teacher_id, teacher_name, teacher_email,
  active, source_key, school_year, grade_level, updated_by, updated_at)
  ON public.bes_extra_classes TO authenticated;
CREATE POLICY attendance_manage_class_insert ON public.bes_extra_classes
  FOR INSERT TO authenticated
  WITH CHECK ((SELECT private.attendance_can_manage_roster()) AND created_by=(SELECT auth.uid())
    AND updated_by=(SELECT auth.uid()));
CREATE POLICY attendance_manage_class_update ON public.bes_extra_classes
  FOR UPDATE TO authenticated
  USING ((SELECT private.attendance_can_manage_roster()))
  WITH CHECK ((SELECT private.attendance_can_manage_roster()) AND updated_by=(SELECT auth.uid()));

GRANT INSERT (class_id, student_code, student_full_name, school_class_name, member_key,
  active, created_by, updated_by, updated_at),
  UPDATE (student_code, student_full_name, school_class_name, member_key, active,
  updated_by, updated_at, joined_at, left_at, removed_by, removal_reason, teacher_note)
  ON public.bes_extra_class_members TO authenticated;
CREATE POLICY attendance_manage_member_insert ON public.bes_extra_class_members
  FOR INSERT TO authenticated
  WITH CHECK ((SELECT private.attendance_can_manage_roster()) AND created_by=(SELECT auth.uid())
    AND updated_by=(SELECT auth.uid())
    AND EXISTS (SELECT 1 FROM public.bes_extra_classes c WHERE c.id=class_id AND c.active));
CREATE POLICY attendance_manage_member_update ON public.bes_extra_class_members
  FOR UPDATE TO authenticated
  USING ((SELECT private.attendance_can_manage_roster()))
  WITH CHECK ((SELECT private.attendance_can_manage_roster()) AND updated_by=(SELECT auth.uid())
    AND (removed_by IS NULL OR removed_by=(SELECT auth.uid()) OR NOT active));


CREATE OR REPLACE FUNCTION private.bes_extra_member_key(p_student_code text, p_student_full_name text, p_school_class_name text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare
  v_code text := trim(coalesce(p_student_code, ''));
  v_identity text;
  v_key text;
begin
  if v_code ~ '^[0-9]+([.]0+)?$' then
    v_code := regexp_replace(v_code, '[.]0+$', '');
  end if;

  if v_code <> '' then
    v_key := trim(both '-' from regexp_replace(lower(v_code), '[^a-z0-9_-]+', '-', 'g'));
    if v_key <> '' then return 'code:' || v_key; end if;
  end if;

  v_identity := lower(trim(coalesce(p_student_full_name, '')) || '-' || trim(coalesce(p_school_class_name, '')));
  v_identity := translate(
    v_identity,
    'áàảãạăắằẳẵặâấầẩẫậéèẻẽẹêếềểễệíìỉĩịóòỏõọôốồổỗộơớờởỡợúùủũụưứừửữựýỳỷỹỵđ',
    'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd'
  );
  v_identity := regexp_replace(v_identity, '[^a-z0-9]+', '-', 'g');
  v_identity := trim(both '-' from v_identity);
  if v_identity = '' then return ''; end if;
  return 'identity:' || v_identity;
end;
$function$;
REVOKE ALL ON FUNCTION private.bes_extra_member_key(text, text, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.bes_guard_extra_class_source_key_collision()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_existing public.bes_extra_classes%rowtype;
  v_candidate text;
  v_same_identity boolean;
begin
  if nullif(trim(coalesce(new.source_key, '')), '') is null then
    return new;
  end if;

  select * into v_existing
  from public.bes_extra_classes c
  where c.source_key = new.source_key
  limit 1;

  if not found then
    return new;
  end if;

  v_same_identity :=
    v_existing.class_type = new.class_type
    and lower(trim(v_existing.class_name)) = lower(trim(new.class_name))
    and lower(trim(coalesce(v_existing.subject, ''))) = lower(trim(coalesce(new.subject, '')))
    and coalesce(v_existing.teacher_id, '00000000-0000-0000-0000-000000000000'::uuid)
        = coalesce(new.teacher_id, '00000000-0000-0000-0000-000000000000'::uuid)
    and lower(trim(coalesce(v_existing.teacher_email, ''))) = lower(trim(coalesce(new.teacher_email, '')));

  if v_same_identity then
    return new;
  end if;

  v_candidate := new.source_key || '::class::' || md5(
    concat_ws('|',
      lower(trim(coalesce(new.class_type, ''))),
      lower(trim(coalesce(new.class_name, ''))),
      lower(trim(coalesce(new.subject, ''))),
      lower(trim(coalesce(new.grade_level, ''))),
      lower(trim(coalesce(new.school_year, ''))),
      lower(trim(coalesce(new.teacher_name, ''))),
      lower(trim(coalesce(new.teacher_email, '')))
    )
  );

  select * into v_existing
  from public.bes_extra_classes c
  where c.source_key = v_candidate
  limit 1;

  if found then
    v_same_identity :=
      v_existing.class_type = new.class_type
      and lower(trim(v_existing.class_name)) = lower(trim(new.class_name))
      and lower(trim(coalesce(v_existing.subject, ''))) = lower(trim(coalesce(new.subject, '')))
      and coalesce(v_existing.teacher_id, '00000000-0000-0000-0000-000000000000'::uuid)
          = coalesce(new.teacher_id, '00000000-0000-0000-0000-000000000000'::uuid)
      and lower(trim(coalesce(v_existing.teacher_email, ''))) = lower(trim(coalesce(new.teacher_email, '')));

    if not v_same_identity then
      raise exception 'Không thể tạo mã lớp duy nhất cho dữ liệu import.' using errcode = '23505';
    end if;
  end if;

  new.source_key := v_candidate;
  return new;
end;
$function$;
REVOKE ALL ON FUNCTION private.bes_guard_extra_class_source_key_collision() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.bes_attendance_archive_capture_change_logs(p_source_type text, p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_changes jsonb := '[]'::jsonb;
begin
  if lower(trim(coalesce(p_source_type, ''))) = 'extra' then
    select coalesce(jsonb_agg(to_jsonb(c) order by c.changed_at, c.id), '[]'::jsonb)
    into v_changes
    from public.bes_extra_attendance_record_changes c
    where c.session_id = p_session_id;
  elsif lower(trim(coalesce(p_source_type, ''))) = 'supplemental' then
    select coalesce(jsonb_agg(to_jsonb(c) order by c.changed_at, c.id), '[]'::jsonb)
    into v_changes
    from public.bes_supplemental_attendance_record_changes c
    where c.session_id = p_session_id;
  else
    raise exception 'Nguồn dữ liệu điểm danh không hợp lệ.' using errcode = '22023';
  end if;

  return coalesce(v_changes, '[]'::jsonb);
end;
$function$;
REVOKE ALL ON FUNCTION private.bes_attendance_archive_capture_change_logs(text, uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.bes_attendance_archive_capture_change_logs_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  new.changes_snapshot := private.bes_attendance_archive_capture_change_logs(
    new.source_type,
    new.source_session_id
  );
  return new;
end;
$function$;
REVOKE ALL ON FUNCTION private.bes_attendance_archive_capture_change_logs_trigger() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.bes_attendance_archive_clear_change_logs(p_source_type text, p_session_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if lower(trim(coalesce(p_source_type, ''))) = 'extra' then
    delete from public.bes_extra_attendance_record_changes c
    where c.session_id = p_session_id;
  elsif lower(trim(coalesce(p_source_type, ''))) = 'supplemental' then
    delete from public.bes_supplemental_attendance_record_changes c
    where c.session_id = p_session_id;
  else
    raise exception 'Nguồn dữ liệu điểm danh không hợp lệ.' using errcode = '22023';
  end if;
end;
$function$;
REVOKE ALL ON FUNCTION private.bes_attendance_archive_clear_change_logs(text, uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.bes_attendance_archive_clear_change_logs_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform private.bes_attendance_archive_clear_change_logs(
    new.source_type,
    new.source_session_id
  );
  return new;
end;
$function$;
REVOKE ALL ON FUNCTION private.bes_attendance_archive_clear_change_logs_trigger() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.bes_attendance_archive_restore_change_logs(p_source_type text, p_session_id uuid, p_changes_snapshot jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if coalesce(jsonb_array_length(coalesce(p_changes_snapshot, '[]'::jsonb)), 0) = 0 then
    return;
  end if;

  if lower(trim(coalesce(p_source_type, ''))) = 'extra' then
    if exists (
      select 1 from public.bes_extra_attendance_record_changes c
      where c.session_id = p_session_id
    ) then
      raise exception 'Buổi điểm danh đã có lịch sử chỉnh sửa mới. Không thể khôi phục chồng dữ liệu.' using errcode = '23505';
    end if;

    insert into public.bes_extra_attendance_record_changes (
      id, session_id, record_id, class_id, member_key, student_full_name,
      change_kind, changed_by, changed_by_name, changed_at,
      old_status, new_status, old_absence_reason_code, new_absence_reason_code,
      old_absence_note, new_absence_note, session_note_before, session_note_after
    )
    select
      c.id,
      c.session_id,
      c.record_id,
      c.class_id,
      c.member_key,
      c.student_full_name,
      c.change_kind,
      case
        when c.changed_by is null or exists (
          select 1 from public.profiles p where p.id = c.changed_by
        ) then c.changed_by
        else null
      end,
      c.changed_by_name,
      c.changed_at,
      c.old_status,
      c.new_status,
      c.old_absence_reason_code,
      c.new_absence_reason_code,
      c.old_absence_note,
      c.new_absence_note,
      c.session_note_before,
      c.session_note_after
    from jsonb_populate_recordset(
      null::public.bes_extra_attendance_record_changes,
      coalesce(p_changes_snapshot, '[]'::jsonb)
    ) c;
  elsif lower(trim(coalesce(p_source_type, ''))) = 'supplemental' then
    if exists (
      select 1 from public.bes_supplemental_attendance_record_changes c
      where c.session_id = p_session_id
    ) then
      raise exception 'Buổi Học bổ sung đã có lịch sử chỉnh sửa mới. Không thể khôi phục chồng dữ liệu.' using errcode = '23505';
    end if;

    insert into public.bes_supplemental_attendance_record_changes (
      id, session_id, participant_id, group_id, canonical_student_key,
      student_full_name, change_kind, changed_by, changed_by_name, changed_at,
      old_status, new_status, old_absence_reason_code, new_absence_reason_code,
      old_absence_note, new_absence_note, session_note_before, session_note_after
    )
    select
      c.id,
      c.session_id,
      c.participant_id,
      c.group_id,
      c.canonical_student_key,
      c.student_full_name,
      c.change_kind,
      case
        when c.changed_by is null or exists (
          select 1 from public.profiles p where p.id = c.changed_by
        ) then c.changed_by
        else null
      end,
      c.changed_by_name,
      c.changed_at,
      c.old_status,
      c.new_status,
      c.old_absence_reason_code,
      c.new_absence_reason_code,
      c.old_absence_note,
      c.new_absence_note,
      c.session_note_before,
      c.session_note_after
    from jsonb_populate_recordset(
      null::public.bes_supplemental_attendance_record_changes,
      coalesce(p_changes_snapshot, '[]'::jsonb)
    ) c;
  else
    raise exception 'Nguồn dữ liệu điểm danh không hợp lệ.' using errcode = '22023';
  end if;
end;
$function$;
REVOKE ALL ON FUNCTION private.bes_attendance_archive_restore_change_logs(text, uuid, jsonb) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.bes_attendance_archive_restore_change_logs_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  -- Approved rows are deleted only by the permanent-delete finalizer. Their edit
  -- history must disappear with the archive instead of being restored.
  if old.delete_request_status = 'approved' then
    return old;
  end if;

  perform private.bes_attendance_archive_restore_change_logs(
    old.source_type,
    old.source_session_id,
    old.changes_snapshot
  );
  return old;
end;
$function$;
REVOKE ALL ON FUNCTION private.bes_attendance_archive_restore_change_logs_trigger() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.bes_add_extra_class_teacher(p_class_id uuid, p_teacher_name text)
 RETURNS public.bes_extra_class_teachers
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_class public.bes_extra_classes%rowtype;
  v_teacher public.bes_extra_class_teachers%rowtype;
  v_teacher_name text := trim(coalesce(p_teacher_name, ''));
  v_position integer;
  v_id uuid := gen_random_uuid();
begin
  if not private.attendance_can_manage_roster() then
    raise exception 'Bạn không có quyền thêm giáo viên cho lớp.' using errcode = '42501';
  end if;

  if v_teacher_name = '' then
    raise exception 'Vui lòng nhập họ tên giáo viên.' using errcode = '22023';
  end if;

  select * into v_class
  from public.bes_extra_classes
  where id = p_class_id
    and active = true
  for update;

  if not found then
    raise exception 'Không tìm thấy lớp đang hoạt động.' using errcode = 'P0002';
  end if;

  if exists (
    select 1
    from public.bes_extra_class_teachers
    where class_id = p_class_id
      and lower(trim(teacher_name)) = lower(v_teacher_name)
  ) then
    raise exception 'Giáo viên này đã có trong lớp.' using errcode = '23505';
  end if;

  select coalesce(max(position), 0) + 1
    into v_position
  from public.bes_extra_class_teachers
  where class_id = p_class_id;

  begin
    insert into public.bes_extra_class_teachers (
      id, class_id, teacher_id, teacher_name, teacher_email,
      position, source_key, created_by, updated_by, created_at, updated_at
    ) values (
      v_id, p_class_id, null, v_teacher_name, '',
      v_position, 'manual:' || p_class_id::text || ':' || v_id::text,
      auth.uid(), auth.uid(), now(), now()
    )
    returning * into v_teacher;
  exception
    when unique_violation then
      raise exception 'Giáo viên này đã có trong lớp.' using errcode = '23505';
  end;

  update public.bes_extra_classes c
  set teacher_name = coalesce((
        select string_agg(t.teacher_name, ', ' order by t.position, t.teacher_name)
        from public.bes_extra_class_teachers t
        where t.class_id = p_class_id
      ), ''),
      updated_by = auth.uid(),
      updated_at = now()
  where c.id = p_class_id;

  return v_teacher;
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_admin_update_extra_class(p_class_id uuid, p_class_name text, p_subject text, p_grade_level integer, p_room text, p_time_range text, p_weekdays integer[], p_teacher_names text[])
 RETURNS public.bes_extra_classes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_row public.bes_extra_classes%rowtype;
  v_weekdays_text text;
  v_teacher_names text[] := '{}'::text[];
  v_teacher_name text;
  v_position integer := 0;
begin
  if not private.attendance_can_manage_roster() then
    raise exception 'Bạn không có quyền Quản lý lớp.' using errcode = '42501';
  end if;

  if p_class_id is null then
    raise exception 'Không xác định được lớp cần sửa.' using errcode = '22004';
  end if;
  if trim(coalesce(p_class_name, '')) = '' then
    raise exception 'Tên lớp không được để trống.' using errcode = '22023';
  end if;
  if p_grade_level is null or p_grade_level not in (10, 11, 12) then
    raise exception 'Khối lớp phải là 10, 11 hoặc 12.' using errcode = '22023';
  end if;
  if coalesce(cardinality(p_weekdays), 0) = 0 then
    raise exception 'Vui lòng chọn ít nhất một ngày học trong tuần.' using errcode = '22023';
  end if;
  if exists (
    select 1
    from unnest(coalesce(p_weekdays, '{}'::integer[])) as d(value)
    where d.value < 0 or d.value > 6
  ) then
    raise exception 'Thứ học không hợp lệ.' using errcode = '22023';
  end if;

  foreach v_teacher_name in array coalesce(p_teacher_names, '{}'::text[])
  loop
    v_teacher_name := trim(coalesce(v_teacher_name, ''));
    if v_teacher_name <> '' and not exists (
      select 1
      from unnest(v_teacher_names) as existing(name)
      where lower(trim(existing.name)) = lower(v_teacher_name)
    ) then
      v_teacher_names := array_append(v_teacher_names, v_teacher_name);
    end if;
  end loop;

  if coalesce(cardinality(v_teacher_names), 0) = 0 then
    raise exception 'Lớp phải có ít nhất một giáo viên.' using errcode = '22023';
  end if;

  select * into v_row
  from public.bes_extra_classes c
  where c.id = p_class_id
  for update;

  if not found then
    raise exception 'Không tìm thấy lớp cần sửa.' using errcode = 'P0002';
  end if;

  select string_agg(
    case when d.value = 0 then 'CN' else (d.value + 1)::text end,
    ',' order by case when d.value = 0 then 7 else d.value end
  )
  into v_weekdays_text
  from (
    select distinct value
    from unnest(p_weekdays) as weekdays(value)
  ) d;

  delete from public.bes_extra_class_teachers t
  where t.class_id = p_class_id
    and not exists (
      select 1
      from unnest(v_teacher_names) as desired(name)
      where lower(trim(desired.name)) = lower(trim(t.teacher_name))
    );

  foreach v_teacher_name in array v_teacher_names
  loop
    v_position := v_position + 1;

    update public.bes_extra_class_teachers t
    set teacher_name = v_teacher_name,
        position = v_position,
        updated_by = auth.uid(),
        updated_at = clock_timestamp()
    where t.class_id = p_class_id
      and lower(trim(t.teacher_name)) = lower(v_teacher_name);

    if not found then
      insert into public.bes_extra_class_teachers (
        class_id,
        teacher_id,
        teacher_name,
        teacher_email,
        position,
        source_key,
        created_by,
        updated_by,
        created_at,
        updated_at
      ) values (
        p_class_id,
        null,
        v_teacher_name,
        '',
        v_position,
        'manual-edit:' || p_class_id::text || ':' || gen_random_uuid()::text,
        auth.uid(),
        auth.uid(),
        clock_timestamp(),
        clock_timestamp()
      );
    end if;
  end loop;

  update public.bes_extra_classes
  set class_name = trim(p_class_name),
      subject = trim(coalesce(p_subject, '')),
      grade_level = p_grade_level::text,
      room = trim(coalesce(p_room, '')),
      time_range = trim(coalesce(p_time_range, '')),
      weekdays = coalesce(v_weekdays_text, ''),
      teacher_id = null,
      teacher_name = array_to_string(v_teacher_names, ', '),
      teacher_email = '',
      updated_by = auth.uid(),
      updated_at = clock_timestamp()
  where id = p_class_id
  returning * into v_row;

  return v_row;
end;
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

  if v_source <> 'extra' then
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

CREATE OR REPLACE FUNCTION private.bes_archive_extra_class(p_class_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_actor_name text := '';
  v_class public.bes_extra_classes%rowtype;
  v_members jsonb := '[]'::jsonb;
  v_teachers jsonb := '[]'::jsonb;
  v_sessions jsonb := '[]'::jsonb;
  v_records jsonb := '[]'::jsonb;
  v_changes jsonb := '[]'::jsonb;
  v_proof_paths jsonb := '[]'::jsonb;
  v_archive_id uuid;
  v_member_count integer := 0;
  v_teacher_count integer := 0;
  v_session_count integer := 0;
  v_record_count integer := 0;
  v_change_count integer := 0;
begin
  if not private.attendance_can_manage_roster() then
    raise exception 'Ban khong co quyen dua lop vao Kho luu tru.' using errcode = '42501';
  end if;

  if p_class_id is null then
    raise exception 'Khong xac dinh duoc lop can luu tru.' using errcode = '22004';
  end if;

  select * into v_class
  from public.bes_extra_classes c
  where c.id = p_class_id
  for update;

  if not found then
    select a.id into v_archive_id
    from public.bes_extra_class_archive a
    where a.source_class_id = p_class_id
    limit 1;
    if found then
      return jsonb_build_object(
        'archive_id', v_archive_id,
        'class_id', p_class_id,
        'already_archived', true
      );
    end if;
    raise exception 'Khong tim thay lop can luu tru.' using errcode = 'P0002';
  end if;

  select coalesce(nullif(trim(p.full_name), ''), p.email, '')
  into v_actor_name
  from public.profiles p
  where p.id = v_uid;

  select
    coalesce(jsonb_agg(to_jsonb(m) order by m.created_at, m.id), '[]'::jsonb),
    count(*)::integer
  into v_members, v_member_count
  from public.bes_extra_class_members m
  where m.class_id = p_class_id;

  select
    coalesce(jsonb_agg(to_jsonb(t) order by t.position, t.created_at, t.id), '[]'::jsonb),
    count(*)::integer
  into v_teachers, v_teacher_count
  from public.bes_extra_class_teachers t
  where t.class_id = p_class_id;

  select
    coalesce(jsonb_agg(to_jsonb(s) order by s.attendance_date, s.checked_at, s.id), '[]'::jsonb),
    count(*)::integer
  into v_sessions, v_session_count
  from public.bes_extra_attendance_sessions s
  where s.class_id = p_class_id;

  select
    coalesce(jsonb_agg(to_jsonb(r) order by r.recorded_at, r.id), '[]'::jsonb),
    count(*)::integer
  into v_records, v_record_count
  from public.bes_extra_attendance_records r
  where r.class_id = p_class_id;

  select
    coalesce(jsonb_agg(to_jsonb(c) order by c.changed_at, c.id), '[]'::jsonb),
    count(*)::integer
  into v_changes, v_change_count
  from public.bes_extra_attendance_record_changes c
  where c.class_id = p_class_id;

  select coalesce(
    jsonb_agg(distinct trim(s.proof_path)) filter (
      where trim(coalesce(s.proof_path, '')) <> ''
    ),
    '[]'::jsonb
  )
  into v_proof_paths
  from public.bes_extra_attendance_sessions s
  where s.class_id = p_class_id;

  insert into public.bes_extra_class_archive (
    source_class_id,
    class_type,
    class_name,
    subject,
    grade_level,
    school_year,
    class_snapshot,
    members_snapshot,
    teachers_snapshot,
    sessions_snapshot,
    records_snapshot,
    changes_snapshot,
    proof_paths,
    member_count,
    teacher_count,
    session_count,
    record_count,
    change_count,
    archived_by,
    archived_by_name
  ) values (
    v_class.id,
    v_class.class_type,
    v_class.class_name,
    v_class.subject,
    v_class.grade_level,
    v_class.school_year,
    to_jsonb(v_class),
    v_members,
    v_teachers,
    v_sessions,
    v_records,
    v_changes,
    v_proof_paths,
    v_member_count,
    v_teacher_count,
    v_session_count,
    v_record_count,
    v_change_count,
    v_uid,
    coalesce(v_actor_name, '')
  )
  returning id into v_archive_id;

  -- Proof files are intentionally retained. Only operational database rows move out.
  delete from public.bes_extra_attendance_record_changes c where c.class_id = p_class_id;
  delete from public.bes_extra_attendance_records r where r.class_id = p_class_id;
  delete from public.bes_extra_attendance_sessions s where s.class_id = p_class_id;
  delete from public.bes_extra_class_teachers t where t.class_id = p_class_id;
  delete from public.bes_extra_class_members m where m.class_id = p_class_id;
  delete from public.bes_extra_classes c where c.id = p_class_id;

  return jsonb_build_object(
    'archive_id', v_archive_id,
    'class_id', v_class.id,
    'class_name', v_class.class_name,
    'member_count', v_member_count,
    'teacher_count', v_teacher_count,
    'session_count', v_session_count,
    'record_count', v_record_count,
    'change_count', v_change_count,
    'archived', true
  );
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_bulk_add_extra_class_members(p_class_id uuid, p_rows jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_item jsonb;
  v_row_number integer := 0;
  v_student_code text;
  v_student_full_name text;
  v_school_class_name text;
  v_member_key text;
  v_seen text[] := '{}'::text[];
  v_existing public.bes_extra_class_members%rowtype;
  v_added integer := 0;
  v_reactivated integer := 0;
  v_skipped_duplicate integer := 0;
  v_invalid integer := 0;
  v_results jsonb := '[]'::jsonb;
  v_now timestamptz := clock_timestamp();
begin
  if not private.attendance_can_manage_roster() then
    raise exception 'Bạn không có quyền quản lý danh sách học sinh.' using errcode = '42501';
  end if;

  if p_class_id is null then
    raise exception 'Không xác định được lớp cần import.' using errcode = '22004';
  end if;

  if not exists (
    select 1 from public.bes_extra_classes c
    where c.id = p_class_id and c.active = true
  ) then
    raise exception 'Không tìm thấy lớp đang hoạt động.' using errcode = 'P0002';
  end if;

  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'Dữ liệu import phải là một danh sách.' using errcode = '22023';
  end if;

  if jsonb_array_length(p_rows) > 1000 then
    raise exception 'Mỗi lần chỉ được import tối đa 1000 học sinh.' using errcode = '22023';
  end if;

  for v_item in select value from jsonb_array_elements(p_rows)
  loop
    v_row_number := v_row_number + 1;
    v_student_code := trim(coalesce(v_item->>'student_code', ''));
    v_student_full_name := trim(coalesce(v_item->>'student_full_name', ''));
    v_school_class_name := trim(coalesce(v_item->>'school_class_name', ''));
    v_member_key := private.bes_extra_member_key(v_student_code, v_student_full_name, v_school_class_name);

    if v_student_full_name = '' or v_school_class_name = '' or v_member_key = '' then
      v_invalid := v_invalid + 1;
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'row_number', v_row_number,
        'status', 'invalid',
        'student_code', v_student_code,
        'student_full_name', v_student_full_name,
        'school_class_name', v_school_class_name,
        'message', case
          when v_student_full_name = '' then 'Thiếu họ và tên'
          when v_school_class_name = '' then 'Thiếu lớp chính khóa'
          else 'Không tạo được mã nhận diện học sinh'
        end
      ));
      continue;
    end if;

    if v_member_key = any(v_seen) then
      v_skipped_duplicate := v_skipped_duplicate + 1;
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'row_number', v_row_number,
        'status', 'duplicate_file',
        'student_code', v_student_code,
        'student_full_name', v_student_full_name,
        'school_class_name', v_school_class_name,
        'message', 'Trùng học sinh trong chính file import'
      ));
      continue;
    end if;
    v_seen := array_append(v_seen, v_member_key);

    select * into v_existing
    from public.bes_extra_class_members m
    where m.class_id = p_class_id
      and m.member_key = v_member_key
      and m.active = true
    order by m.updated_at desc, m.id
    limit 1
    for update;

    if found then
      v_skipped_duplicate := v_skipped_duplicate + 1;
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'row_number', v_row_number,
        'status', 'existing_active',
        'member_id', v_existing.id,
        'student_code', v_student_code,
        'student_full_name', v_student_full_name,
        'school_class_name', v_school_class_name,
        'message', 'Học sinh đã có trong lớp'
      ));
      continue;
    end if;

    select * into v_existing
    from public.bes_extra_class_members m
    where m.class_id = p_class_id
      and m.member_key = v_member_key
      and m.active = false
    order by m.updated_at desc, m.id
    limit 1
    for update;

    if found then
      update public.bes_extra_class_members
      set student_code = v_student_code,
          student_full_name = v_student_full_name,
          school_class_name = v_school_class_name,
          active = true,
          joined_at = v_now,
          left_at = null,
          removed_by = null,
          removal_reason = '',
          updated_by = auth.uid(),
          updated_at = v_now
      where id = v_existing.id
      returning * into v_existing;

      v_reactivated := v_reactivated + 1;
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'row_number', v_row_number,
        'status', 'reactivated',
        'member_id', v_existing.id,
        'student_code', v_student_code,
        'student_full_name', v_student_full_name,
        'school_class_name', v_school_class_name,
        'message', 'Đã kích hoạt lại học sinh'
      ));
      continue;
    end if;

    insert into public.bes_extra_class_members (
      class_id,
      member_key,
      student_code,
      student_full_name,
      school_class_name,
      active,
      joined_at,
      left_at,
      created_by,
      updated_by,
      removed_by,
      removal_reason,
      source_key,
      created_at,
      updated_at
    ) values (
      p_class_id,
      v_member_key,
      v_student_code,
      v_student_full_name,
      v_school_class_name,
      true,
      v_now,
      null,
      auth.uid(),
      auth.uid(),
      null,
      '',
      'bulk-import:' || p_class_id::text || ':' || md5(v_member_key),
      v_now,
      v_now
    )
    returning * into v_existing;

    v_added := v_added + 1;
    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'row_number', v_row_number,
      'status', 'added',
      'member_id', v_existing.id,
      'student_code', v_student_code,
      'student_full_name', v_student_full_name,
      'school_class_name', v_school_class_name,
      'message', 'Đã thêm học sinh'
    ));
  end loop;

  return jsonb_build_object(
    'total', jsonb_array_length(p_rows),
    'added', v_added,
    'reactivated', v_reactivated,
    'skipped_duplicate', v_skipped_duplicate,
    'invalid', v_invalid,
    'rows', v_results
  );
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_create_extra_class_with_members(p_class_type text, p_class_name text, p_subject text, p_source_key text, p_school_year text, p_grade_level text, p_teacher_names text[], p_members jsonb)
 RETURNS public.bes_extra_classes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_class public.bes_extra_classes%rowtype;
  v_class_name text := trim(coalesce(p_class_name, ''));
  v_subject text := trim(coalesce(p_subject, ''));
  v_source_key text := nullif(trim(coalesce(p_source_key, '')), '');
  v_school_year text := trim(coalesce(p_school_year, ''));
  v_grade_level text := trim(coalesce(p_grade_level, ''));
  v_teacher_name text;
  v_teacher_names text[] := '{}'::text[];
  v_teacher_source_base text;
  v_teacher_position integer := 0;
  v_members jsonb := coalesce(p_members, '[]'::jsonb);
  v_member jsonb;
  v_member_key text;
  v_student_code text;
  v_student_full_name text;
  v_school_class_name text;
begin
  if not private.attendance_can_manage_roster() then
    raise exception 'Bạn không có quyền tạo lớp phụ đạo/bồi dưỡng.' using errcode = '42501';
  end if;

  if p_class_type not in ('remedial', 'gifted') then
    raise exception 'Loại lớp không hợp lệ.' using errcode = '22023';
  end if;

  if v_class_name = '' then
    raise exception 'Tên lớp không được để trống.' using errcode = '22023';
  end if;

  if v_grade_level <> '' and v_grade_level not in ('10', '11', '12') then
    raise exception 'Khối lớp phải là 10, 11 hoặc 12.' using errcode = '22023';
  end if;

  if jsonb_typeof(v_members) <> 'array' then
    raise exception 'Danh sách học sinh import không hợp lệ.' using errcode = '22023';
  end if;

  foreach v_teacher_name in array coalesce(p_teacher_names, '{}'::text[])
  loop
    v_teacher_name := trim(coalesce(v_teacher_name, ''));
    if v_teacher_name <> '' and not (v_teacher_name = any(v_teacher_names)) then
      v_teacher_names := array_append(v_teacher_names, v_teacher_name);
    end if;
  end loop;

  if coalesce(array_length(v_teacher_names, 1), 0) = 0 then
    raise exception 'Lớp phải có ít nhất một giáo viên.' using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.bes_extra_classes c
    where c.active = true
      and c.class_type = p_class_type
      and lower(trim(c.class_name)) = lower(v_class_name)
      and lower(trim(c.subject)) = lower(v_subject)
  ) then
    raise exception 'Lớp này đã tồn tại trên hệ thống.' using errcode = '23505';
  end if;

  insert into public.bes_extra_classes (
    class_type,
    class_name,
    subject,
    teacher_id,
    teacher_name,
    teacher_email,
    active,
    source_key,
    school_year,
    grade_level,
    created_by,
    updated_by,
    created_at,
    updated_at
  ) values (
    p_class_type,
    v_class_name,
    v_subject,
    null,
    array_to_string(v_teacher_names, ', '),
    '',
    true,
    v_source_key,
    v_school_year,
    v_grade_level,
    auth.uid(),
    auth.uid(),
    clock_timestamp(),
    clock_timestamp()
  )
  returning * into v_class;

  v_teacher_source_base := coalesce(v_source_key, 'attendance-create-' || v_class.id::text);

  foreach v_teacher_name in array v_teacher_names
  loop
    v_teacher_position := v_teacher_position + 1;
    insert into public.bes_extra_class_teachers (
      class_id,
      teacher_id,
      teacher_name,
      teacher_email,
      position,
      source_key,
      created_by,
      updated_by,
      created_at,
      updated_at
    ) values (
      v_class.id,
      null,
      v_teacher_name,
      '',
      v_teacher_position,
      v_teacher_source_base || '::teacher::' || lpad(v_teacher_position::text, 2, '0'),
      auth.uid(),
      auth.uid(),
      clock_timestamp(),
      clock_timestamp()
    );
  end loop;

  for v_member in select value from jsonb_array_elements(v_members)
  loop
    v_member_key := trim(coalesce(v_member ->> 'member_key', ''));
    v_student_code := trim(coalesce(v_member ->> 'student_code', ''));
    v_student_full_name := trim(coalesce(v_member ->> 'student_full_name', ''));
    v_school_class_name := trim(coalesce(v_member ->> 'school_class_name', ''));

    if v_member_key = '' or v_student_full_name = '' then
      raise exception 'Mỗi học sinh phải có member_key và họ tên.' using errcode = '22023';
    end if;

    insert into public.bes_extra_class_members (
      class_id,
      member_key,
      student_code,
      student_full_name,
      school_class_name,
      active,
      created_by,
      updated_by,
      created_at,
      updated_at
    ) values (
      v_class.id,
      v_member_key,
      v_student_code,
      v_student_full_name,
      v_school_class_name,
      true,
      auth.uid(),
      auth.uid(),
      clock_timestamp(),
      clock_timestamp()
    );
  end loop;

  return v_class;
exception
  when unique_violation then
    raise exception 'Lớp, phân công hoặc học sinh này đã tồn tại trên hệ thống.' using errcode = '23505';
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_list_extra_class_archive()
 RETURNS TABLE(archive_id uuid, source_class_id uuid, class_type text, class_name text, subject text, grade_level text, school_year text, member_count integer, teacher_count integer, session_count integer, record_count integer, change_count integer, proof_paths jsonb, archived_by uuid, archived_by_name text, archived_at timestamp with time zone, delete_request_status text, delete_requested_by uuid, delete_requested_at timestamp with time zone, delete_request_reason text, delete_reviewed_by uuid, delete_reviewed_at timestamp with time zone, delete_review_note text, can_review boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not private.attendance_can_manage_roster() then
    raise exception 'Ban khong co quyen xem Kho luu tru lop.' using errcode = '42501';
  end if;

  return query
  select
    a.id,
    a.source_class_id,
    a.class_type,
    a.class_name,
    a.subject,
    a.grade_level,
    a.school_year,
    a.member_count,
    a.teacher_count,
    a.session_count,
    a.record_count,
    a.change_count,
    a.proof_paths,
    a.archived_by,
    a.archived_by_name,
    a.archived_at,
    a.delete_request_status,
    a.delete_requested_by,
    a.delete_requested_at,
    a.delete_request_reason,
    a.delete_reviewed_by,
    a.delete_reviewed_at,
    a.delete_review_note,
    private.attendance_is_admin()
  from public.bes_extra_class_archive a
  order by a.archived_at desc, a.class_name;
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_preview_extra_class_member_import(p_class_id uuid, p_rows jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_result jsonb;
  v_total integer := 0;
  v_invalid integer := 0;
  v_duplicate_file integer := 0;
  v_existing_active integer := 0;
  v_reactivate integer := 0;
  v_new integer := 0;
begin
  if not private.attendance_can_manage_roster() then
    raise exception 'Bạn không có quyền quản lý danh sách học sinh.' using errcode = '42501';
  end if;

  if p_class_id is null then
    raise exception 'Không xác định được lớp cần import.' using errcode = '22004';
  end if;

  if not exists (
    select 1 from public.bes_extra_classes c
    where c.id = p_class_id and c.active = true
  ) then
    raise exception 'Không tìm thấy lớp đang hoạt động.' using errcode = 'P0002';
  end if;

  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'Dữ liệu import phải là một danh sách.' using errcode = '22023';
  end if;

  if jsonb_array_length(p_rows) > 1000 then
    raise exception 'Mỗi lần chỉ được import tối đa 1000 học sinh.' using errcode = '22023';
  end if;

  with raw as (
    select
      ordinality::integer as row_number,
      trim(coalesce(value->>'student_code', '')) as student_code,
      trim(coalesce(value->>'student_full_name', '')) as student_full_name,
      trim(coalesce(value->>'school_class_name', '')) as school_class_name
    from jsonb_array_elements(p_rows) with ordinality
  ), normalized as (
    select
      r.*,
      private.bes_extra_member_key(r.student_code, r.student_full_name, r.school_class_name) as member_key
    from raw r
  ), ranked as (
    select
      n.*,
      case
        when n.student_full_name = '' or n.school_class_name = '' or n.member_key = '' then 1
        else row_number() over (partition by n.member_key order by n.row_number)
      end as duplicate_rank
    from normalized n
  ), classified as (
    select
      x.*,
      case
        when x.student_full_name = '' then 'invalid'
        when x.school_class_name = '' then 'invalid'
        when x.member_key = '' then 'invalid'
        when x.duplicate_rank > 1 then 'duplicate_file'
        when exists (
          select 1 from public.bes_extra_class_members m
          where m.class_id = p_class_id
            and m.member_key = x.member_key
            and m.active = true
        ) then 'existing_active'
        when exists (
          select 1 from public.bes_extra_class_members m
          where m.class_id = p_class_id
            and m.member_key = x.member_key
            and m.active = false
        ) then 'reactivate'
        else 'new'
      end as status,
      case
        when x.student_full_name = '' then 'Thiếu họ và tên'
        when x.school_class_name = '' then 'Thiếu lớp chính khóa'
        when x.member_key = '' then 'Không tạo được mã nhận diện học sinh'
        when x.duplicate_rank > 1 then 'Trùng học sinh trong chính file import'
        when exists (
          select 1 from public.bes_extra_class_members m
          where m.class_id = p_class_id
            and m.member_key = x.member_key
            and m.active = true
        ) then 'Học sinh đã có trong lớp'
        when exists (
          select 1 from public.bes_extra_class_members m
          where m.class_id = p_class_id
            and m.member_key = x.member_key
            and m.active = false
        ) then 'Học sinh từng bị xóa và sẽ được kích hoạt lại'
        else 'Sẵn sàng thêm mới'
      end as message
    from ranked x
  ), counts as (
    select
      count(*)::integer as total,
      count(*) filter (where status = 'invalid')::integer as invalid_count,
      count(*) filter (where status = 'duplicate_file')::integer as duplicate_file_count,
      count(*) filter (where status = 'existing_active')::integer as existing_active_count,
      count(*) filter (where status = 'reactivate')::integer as reactivate_count,
      count(*) filter (where status = 'new')::integer as new_count
    from classified
  )
  select
    c.total, c.invalid_count, c.duplicate_file_count, c.existing_active_count, c.reactivate_count, c.new_count,
    jsonb_build_object(
      'total', c.total,
      'invalid', c.invalid_count,
      'duplicate_file', c.duplicate_file_count,
      'existing_active', c.existing_active_count,
      'reactivate', c.reactivate_count,
      'new', c.new_count,
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
          'row_number', q.row_number,
          'student_code', q.student_code,
          'student_full_name', q.student_full_name,
          'school_class_name', q.school_class_name,
          'member_key', q.member_key,
          'status', q.status,
          'message', q.message
        ) order by q.row_number)
        from classified q
      ), '[]'::jsonb)
    )
  into v_total, v_invalid, v_duplicate_file, v_existing_active, v_reactivate, v_new, v_result
  from counts c;

  return coalesce(v_result, jsonb_build_object(
    'total', 0,
    'invalid', 0,
    'duplicate_file', 0,
    'existing_active', 0,
    'reactivate', 0,
    'new', 0,
    'rows', '[]'::jsonb
  ));
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

  if v_archive.delete_request_status = 'pending' then
    raise exception 'Yêu cầu xóa đang chờ duyệt. Từ chối yêu cầu trước khi khôi phục.' using errcode='22023';
  end if;

  if v_archive.delete_request_status = 'approved' then
    raise exception 'Mục này đã được Admin duyệt xóa và đang chờ hoàn tất, không thể khôi phục.' using errcode = '22023';
  end if;

  if v_archive.source_type <> 'extra' then
    raise exception 'Buổi Học bổ sung cần phiên bản có hỗ trợ khôi phục.' using errcode='22023';
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

CREATE OR REPLACE FUNCTION private.bes_restore_extra_class_archive(p_archive_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_archive public.bes_extra_class_archive%rowtype;
  v_class public.bes_extra_classes%rowtype;
begin
  if not private.attendance_can_manage_roster() then
    raise exception 'Ban khong co quyen khoi phuc lop.' using errcode = '42501';
  end if;

  select * into v_archive
  from public.bes_extra_class_archive a
  where a.id = p_archive_id
  for update;

  if not found then
    raise exception 'Khong tim thay lop luu tru can khoi phuc.' using errcode = 'P0002';
  end if;

  if v_archive.delete_request_status not in ('none', 'rejected') then
    raise exception 'Muc nay dang cho hoac da duoc Admin duyet xoa, khong the khoi phuc.' using errcode = '22023';
  end if;

  select * into v_class
  from jsonb_populate_record(null::public.bes_extra_classes, v_archive.class_snapshot);

  if exists (select 1 from public.bes_extra_classes c where c.id = v_archive.source_class_id) then
    raise exception 'ID lop goc da duoc su dung. Khong the khoi phuc chong du lieu.' using errcode = '23505';
  end if;

  if nullif(trim(coalesce(v_class.source_key, '')), '') is not null
     and exists (
       select 1 from public.bes_extra_classes c
       where c.source_key = v_class.source_key
     ) then
    raise exception 'Ma nguon cua lop da duoc su dung. Khong the khoi phuc chong du lieu.' using errcode = '23505';
  end if;

  insert into public.bes_extra_classes
  select r.*
  from jsonb_populate_record(null::public.bes_extra_classes, v_archive.class_snapshot) r;

  insert into public.bes_extra_class_members
  select r.*
  from jsonb_populate_recordset(null::public.bes_extra_class_members, v_archive.members_snapshot) r;

  insert into public.bes_extra_class_teachers
  select r.*
  from jsonb_populate_recordset(null::public.bes_extra_class_teachers, v_archive.teachers_snapshot) r;

  insert into public.bes_extra_attendance_sessions
  select r.*
  from jsonb_populate_recordset(null::public.bes_extra_attendance_sessions, v_archive.sessions_snapshot) r;

  insert into public.bes_extra_attendance_records
  select r.*
  from jsonb_populate_recordset(null::public.bes_extra_attendance_records, v_archive.records_snapshot) r;

  insert into public.bes_extra_attendance_record_changes
  select r.*
  from jsonb_populate_recordset(null::public.bes_extra_attendance_record_changes, v_archive.changes_snapshot) r;

  delete from public.bes_extra_class_archive a where a.id = p_archive_id;

  return jsonb_build_object(
    'archive_id', p_archive_id,
    'class_id', v_archive.source_class_id,
    'class_name', v_archive.class_name,
    'member_count', v_archive.member_count,
    'teacher_count', v_archive.teacher_count,
    'session_count', v_archive.session_count,
    'record_count', v_archive.record_count,
    'change_count', v_archive.change_count,
    'restored', true
  );
end;
$function$;

CREATE OR REPLACE FUNCTION private.bes_update_extra_class_member(p_class_id uuid, p_member_id uuid, p_student_code text, p_student_full_name text, p_school_class_name text, p_active boolean)
 RETURNS public.bes_extra_class_members
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_member public.bes_extra_class_members%rowtype;
  v_member_key text;
  v_student_code text := trim(coalesce(p_student_code, ''));
  v_student_full_name text := trim(coalesce(p_student_full_name, ''));
  v_school_class_name text := trim(coalesce(p_school_class_name, ''));
  v_active boolean := coalesce(p_active, true);
begin
  if not private.attendance_can_manage_roster() then
    raise exception 'Bạn không có quyền Quản lý lớp trong phân hệ Điểm danh.' using errcode = '42501';
  end if;

  if p_class_id is null or p_member_id is null then
    raise exception 'Không xác định được học sinh cần sửa.' using errcode = '22004';
  end if;
  if v_student_full_name = '' then
    raise exception 'Họ và tên không được để trống.' using errcode = '22023';
  end if;
  if v_school_class_name = '' then
    raise exception 'Lớp chính khóa không được để trống.' using errcode = '22023';
  end if;

  select * into v_member
  from public.bes_extra_class_members m
  where m.id = p_member_id
    and m.class_id = p_class_id
  for update;

  if not found then
    raise exception 'Không tìm thấy học sinh trong lớp này.' using errcode = 'P0002';
  end if;

  v_member_key := private.bes_extra_member_key(v_student_code, v_student_full_name, v_school_class_name);
  if v_member_key = '' then
    raise exception 'Không tạo được mã nhận diện học sinh.' using errcode = '22023';
  end if;

  if v_active and exists (
    select 1
    from public.bes_extra_class_members duplicate
    where duplicate.class_id = p_class_id
      and duplicate.active = true
      and duplicate.id <> p_member_id
      and duplicate.member_key = v_member_key
  ) then
    raise exception 'Thông tin sau khi sửa bị trùng với một học sinh đang có trong lớp.' using errcode = '23505';
  end if;

  update public.bes_extra_class_members
  set student_code = v_student_code,
      student_full_name = v_student_full_name,
      school_class_name = v_school_class_name,
      member_key = v_member_key,
      active = v_active,
      left_at = case
        when v_active then null
        when v_member.active is distinct from false then clock_timestamp()
        else coalesce(v_member.left_at, clock_timestamp())
      end,
      removed_by = case
        when v_active then null
        when v_member.active is distinct from false then auth.uid()
        else v_member.removed_by
      end,
      removal_reason = case
        when v_active then ''
        when v_member.active is distinct from false then 'Đã nghỉ'
        else coalesce(nullif(trim(v_member.removal_reason), ''), 'Đã nghỉ')
      end,
      updated_by = auth.uid(),
      updated_at = clock_timestamp()
  where id = p_member_id
    and class_id = p_class_id
  returning * into v_member;

  return v_member;
end;
$function$;

CREATE FUNCTION public.bes_add_extra_class_teacher(p_class_id uuid, p_teacher_name text) RETURNS public.bes_extra_class_teachers
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_add_extra_class_teacher(p_class_id, p_teacher_name);
$$;
REVOKE ALL ON FUNCTION public.bes_add_extra_class_teacher(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_add_extra_class_teacher(uuid, text) TO authenticated;
REVOKE ALL ON FUNCTION private.bes_add_extra_class_teacher(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_add_extra_class_teacher(uuid, text) TO authenticated;

CREATE FUNCTION public.bes_admin_update_extra_class(p_class_id uuid, p_class_name text, p_subject text, p_grade_level integer, p_room text, p_time_range text, p_weekdays integer[], p_teacher_names text[]) RETURNS public.bes_extra_classes
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_admin_update_extra_class(p_class_id, p_class_name, p_subject, p_grade_level, p_room, p_time_range, p_weekdays, p_teacher_names);
$$;
REVOKE ALL ON FUNCTION public.bes_admin_update_extra_class(uuid, text, text, integer, text, text, integer[], text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_admin_update_extra_class(uuid, text, text, integer, text, text, integer[], text[]) TO authenticated;
REVOKE ALL ON FUNCTION private.bes_admin_update_extra_class(uuid, text, text, integer, text, text, integer[], text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_admin_update_extra_class(uuid, text, text, integer, text, text, integer[], text[]) TO authenticated;

CREATE FUNCTION public.bes_archive_attendance_history(p_source_type text, p_session_id uuid) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_archive_attendance_history(p_source_type, p_session_id);
$$;
REVOKE ALL ON FUNCTION public.bes_archive_attendance_history(text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_archive_attendance_history(text, uuid) TO authenticated;
REVOKE ALL ON FUNCTION private.bes_archive_attendance_history(text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_archive_attendance_history(text, uuid) TO authenticated;

CREATE FUNCTION public.bes_archive_extra_class(p_class_id uuid) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_archive_extra_class(p_class_id);
$$;
REVOKE ALL ON FUNCTION public.bes_archive_extra_class(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_archive_extra_class(uuid) TO authenticated;
REVOKE ALL ON FUNCTION private.bes_archive_extra_class(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_archive_extra_class(uuid) TO authenticated;

CREATE FUNCTION public.bes_bulk_add_extra_class_members(p_class_id uuid, p_rows jsonb) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_bulk_add_extra_class_members(p_class_id, p_rows);
$$;
REVOKE ALL ON FUNCTION public.bes_bulk_add_extra_class_members(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_bulk_add_extra_class_members(uuid, jsonb) TO authenticated;
REVOKE ALL ON FUNCTION private.bes_bulk_add_extra_class_members(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_bulk_add_extra_class_members(uuid, jsonb) TO authenticated;

CREATE FUNCTION public.bes_create_extra_class_with_members(p_class_type text, p_class_name text, p_subject text, p_source_key text, p_school_year text, p_grade_level text, p_teacher_names text[], p_members jsonb) RETURNS public.bes_extra_classes
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_create_extra_class_with_members(p_class_type, p_class_name, p_subject, p_source_key, p_school_year, p_grade_level, p_teacher_names, p_members);
$$;
REVOKE ALL ON FUNCTION public.bes_create_extra_class_with_members(text, text, text, text, text, text, text[], jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_create_extra_class_with_members(text, text, text, text, text, text, text[], jsonb) TO authenticated;
REVOKE ALL ON FUNCTION private.bes_create_extra_class_with_members(text, text, text, text, text, text, text[], jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_create_extra_class_with_members(text, text, text, text, text, text, text[], jsonb) TO authenticated;

CREATE FUNCTION public.bes_list_extra_class_archive() RETURNS TABLE(archive_id uuid, source_class_id uuid, class_type text, class_name text, subject text, grade_level text, school_year text, member_count integer, teacher_count integer, session_count integer, record_count integer, change_count integer, proof_paths jsonb, archived_by uuid, archived_by_name text, archived_at timestamp with time zone, delete_request_status text, delete_requested_by uuid, delete_requested_at timestamp with time zone, delete_request_reason text, delete_reviewed_by uuid, delete_reviewed_at timestamp with time zone, delete_review_note text, can_review boolean)
LANGUAGE sql SET search_path = '' AS $$
  SELECT * FROM private.bes_list_extra_class_archive();
$$;
REVOKE ALL ON FUNCTION public.bes_list_extra_class_archive() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_list_extra_class_archive() TO authenticated;
REVOKE ALL ON FUNCTION private.bes_list_extra_class_archive() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_list_extra_class_archive() TO authenticated;

CREATE FUNCTION public.bes_preview_extra_class_member_import(p_class_id uuid, p_rows jsonb) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_preview_extra_class_member_import(p_class_id, p_rows);
$$;
REVOKE ALL ON FUNCTION public.bes_preview_extra_class_member_import(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_preview_extra_class_member_import(uuid, jsonb) TO authenticated;
REVOKE ALL ON FUNCTION private.bes_preview_extra_class_member_import(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_preview_extra_class_member_import(uuid, jsonb) TO authenticated;

CREATE FUNCTION public.bes_restore_attendance_archive(p_archive_id uuid) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_restore_attendance_archive(p_archive_id);
$$;
REVOKE ALL ON FUNCTION public.bes_restore_attendance_archive(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_restore_attendance_archive(uuid) TO authenticated;
REVOKE ALL ON FUNCTION private.bes_restore_attendance_archive(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_restore_attendance_archive(uuid) TO authenticated;

CREATE FUNCTION public.bes_restore_extra_class_archive(p_archive_id uuid) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_restore_extra_class_archive(p_archive_id);
$$;
REVOKE ALL ON FUNCTION public.bes_restore_extra_class_archive(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_restore_extra_class_archive(uuid) TO authenticated;
REVOKE ALL ON FUNCTION private.bes_restore_extra_class_archive(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_restore_extra_class_archive(uuid) TO authenticated;

CREATE FUNCTION public.bes_update_extra_class_member(p_class_id uuid, p_member_id uuid, p_student_code text, p_student_full_name text, p_school_class_name text, p_active boolean) RETURNS public.bes_extra_class_members
LANGUAGE sql SET search_path = '' AS $$
  SELECT private.bes_update_extra_class_member(p_class_id, p_member_id, p_student_code, p_student_full_name, p_school_class_name, p_active);
$$;
REVOKE ALL ON FUNCTION public.bes_update_extra_class_member(uuid, uuid, text, text, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_update_extra_class_member(uuid, uuid, text, text, text, boolean) TO authenticated;
REVOKE ALL ON FUNCTION private.bes_update_extra_class_member(uuid, uuid, text, text, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_update_extra_class_member(uuid, uuid, text, text, text, boolean) TO authenticated;


CREATE TRIGGER attendance_guard_extra_class_source_key
BEFORE INSERT OR UPDATE OF source_key ON public.bes_extra_classes
FOR EACH ROW EXECUTE FUNCTION private.bes_guard_extra_class_source_key_collision();
CREATE TRIGGER attendance_capture_archive_changes
BEFORE INSERT ON public.bes_attendance_archive
FOR EACH ROW EXECUTE FUNCTION private.bes_attendance_archive_capture_change_logs_trigger();
CREATE TRIGGER attendance_clear_archive_changes
AFTER INSERT ON public.bes_attendance_archive
FOR EACH ROW EXECUTE FUNCTION private.bes_attendance_archive_clear_change_logs_trigger();
CREATE TRIGGER attendance_restore_archive_changes
AFTER DELETE ON public.bes_attendance_archive
FOR EACH ROW EXECUTE FUNCTION private.bes_attendance_archive_restore_change_logs_trigger();

NOTIFY pgrst, 'reload schema';
COMMIT;
