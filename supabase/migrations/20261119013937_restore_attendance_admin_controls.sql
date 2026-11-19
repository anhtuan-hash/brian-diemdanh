BEGIN;

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
  if not (private.attendance_can_manage_roster()
    or private.attendance_global_permission('attendance:report')) then
    raise exception 'Bạn không có quyền tạo lớp phụ đạo/bồi dưỡng.' using errcode = '42501';
  end if;

  if p_class_type is null or p_class_type not in ('remedial', 'gifted') then
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

  perform pg_advisory_xact_lock(hashtextextended(
    jsonb_build_array(p_class_type, lower(v_class_name), lower(v_subject))::text, 0));

  if exists (
    select 1
    from public.bes_extra_classes c
    where c.active = true
      and c.class_type = p_class_type
      and lower(trim(c.class_name)) = lower(v_class_name)
      and lower(trim(c.subject)) = lower(v_subject)
  ) then
    raise exception 'Lớp này đã tồn tại trên hệ thống.' using errcode = '23505', detail = 'attendance_class_exists';
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
end;
$function$;

CREATE FUNCTION private.bes_admin_set_attendance_time_restriction(
  p_enabled boolean,
  p_start time without time zone,
  p_end time without time zone
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  IF NOT private.attendance_is_admin() THEN
    RAISE EXCEPTION 'Chỉ quản trị viên mới được đổi khung giờ điểm danh.' USING ERRCODE = '42501';
  END IF;

  IF p_enabled IS NULL OR p_start IS NULL OR p_end IS NULL OR p_start = p_end THEN
    RAISE EXCEPTION 'Giờ bắt đầu và giờ kết thúc phải khác nhau.' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.bes_attendance_access_settings
    (id, enforce_teacher_time_window, teacher_start_time, teacher_end_time, updated_by, updated_at)
  VALUES
    (1, p_enabled, p_start, p_end, auth.uid(), clock_timestamp())
  ON CONFLICT (id) DO UPDATE SET
    enforce_teacher_time_window = excluded.enforce_teacher_time_window,
    teacher_start_time = excluded.teacher_start_time,
    teacher_end_time = excluded.teacher_end_time,
    updated_by = excluded.updated_by,
    updated_at = excluded.updated_at;

  RETURN private.bes_attendance_settings_snapshot();
END;
$function$;

CREATE FUNCTION public.bes_admin_set_attendance_time_restriction(
  p_enabled boolean,
  p_start time without time zone,
  p_end time without time zone
)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.bes_admin_set_attendance_time_restriction(p_enabled, p_start, p_end); $$;

REVOKE ALL ON FUNCTION
  public.bes_admin_set_attendance_time_restriction(boolean, time, time),
  private.bes_admin_set_attendance_time_restriction(boolean, time, time)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.bes_admin_set_attendance_time_restriction(boolean, time, time),
  private.bes_admin_set_attendance_time_restriction(boolean, time, time)
  TO authenticated;

COMMIT;
