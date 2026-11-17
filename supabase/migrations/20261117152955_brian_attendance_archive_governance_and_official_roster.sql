BEGIN;

CREATE FUNCTION private.attendance_archive_proof_can_read(proof_name text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT (private.attendance_can_move_history() AND EXISTS (
    SELECT 1 FROM public.bes_attendance_archive a WHERE a.proof_path = proof_name
  )) OR (private.attendance_can_manage_roster() AND EXISTS (
    SELECT 1 FROM public.bes_extra_class_archive a WHERE a.proof_paths ? proof_name
  ));
$$;

CREATE FUNCTION private.attendance_archive_proof_is_shared(proof_name text, archive_kind text, archive_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (SELECT 1 FROM public.bes_extra_attendance_sessions s WHERE s.proof_path = proof_name)
    OR EXISTS (SELECT 1 FROM public.bes_supplemental_sessions s WHERE s.proof_path = proof_name)
    OR EXISTS (SELECT 1 FROM public.bes_attendance_archive a
      WHERE a.proof_path = proof_name AND (archive_kind <> 'session' OR a.id <> archive_id))
    OR EXISTS (SELECT 1 FROM public.bes_extra_class_archive a
      WHERE a.proof_paths ? proof_name AND (archive_kind <> 'class' OR a.id <> archive_id));
$$;

CREATE FUNCTION private.attendance_archive_proof_can_delete(proof_name text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT private.attendance_is_admin() AND (
    EXISTS (SELECT 1 FROM public.bes_attendance_archive a
      WHERE a.proof_path = proof_name AND a.delete_request_status = 'approved'
        AND NOT private.attendance_archive_proof_is_shared(proof_name, 'session', a.id))
    OR EXISTS (SELECT 1 FROM public.bes_extra_class_archive a
      WHERE a.proof_paths ? proof_name AND a.delete_request_status = 'approved'
        AND NOT private.attendance_archive_proof_is_shared(proof_name, 'class', a.id))
  );
$$;

REVOKE ALL ON FUNCTION private.attendance_archive_proof_can_read(text),
  private.attendance_archive_proof_can_delete(text),
  private.attendance_archive_proof_is_shared(text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.attendance_archive_proof_can_read(text),
  private.attendance_archive_proof_can_delete(text) TO authenticated;

CREATE POLICY attendance_read_archived_proof ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'attendance-session-proofs' AND private.attendance_archive_proof_can_read(name));
CREATE POLICY attendance_delete_approved_archived_proof ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'attendance-session-proofs' AND private.attendance_archive_proof_can_delete(name));

CREATE OR REPLACE FUNCTION private.bes_finalize_attendance_archive_delete(p_archive_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_archive public.bes_attendance_archive%rowtype;
begin
  if not private.attendance_is_admin() then
    raise exception 'Chỉ Admin được hoàn tất xóa vĩnh viễn.' using errcode = '42501';
  end if;

  select * into v_archive
  from public.bes_attendance_archive a
  where a.id = p_archive_id
  for update;
  if not found then
    raise exception 'Không tìm thấy mục lưu trữ.' using errcode = 'P0002';
  end if;
  if v_archive.delete_request_status <> 'approved' then
    raise exception 'Mục này chưa được Admin duyệt xóa.' using errcode = '22023';
  end if;

  if exists (
    select 1 from storage.objects o where o.bucket_id = 'attendance-session-proofs'
      and o.name = v_archive.proof_path
      and not private.attendance_archive_proof_is_shared(o.name, 'session', p_archive_id)
  ) then
    raise exception 'Ảnh minh chứng chưa được xóa khỏi Storage. Mục lưu trữ vẫn được giữ để thử lại.' using errcode = '22023';
  end if;

  delete from public.bes_attendance_archive a where a.id = p_archive_id;
  return jsonb_build_object(
    'archive_id', p_archive_id,
    'approved', true,
    'permanently_deleted', true,
    'finalized_by', v_uid
  );
end;
$function$;

CREATE FUNCTION public.bes_finalize_attendance_archive_delete(p_archive_id uuid)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.bes_finalize_attendance_archive_delete(p_archive_id); $$;
REVOKE ALL ON FUNCTION public.bes_finalize_attendance_archive_delete(uuid),
  private.bes_finalize_attendance_archive_delete(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_finalize_attendance_archive_delete(uuid),
  private.bes_finalize_attendance_archive_delete(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION private.bes_request_attendance_archive_delete(p_archive_id uuid, p_reason text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_archive public.bes_attendance_archive%rowtype;
begin
  if not private.attendance_can_move_history() then
    raise exception 'Bạn không có quyền gửi yêu cầu xóa vĩnh viễn.' using errcode = '42501';
  end if;

  select * into v_archive
  from public.bes_attendance_archive a
  where a.id = p_archive_id
  for update;
  if not found then
    raise exception 'Không tìm thấy mục lưu trữ.' using errcode = 'P0002';
  end if;
  if v_archive.delete_request_status not in ('none', 'rejected') then
    raise exception 'Mục này đã có yêu cầu xóa.' using errcode = '22023';
  end if;

  update public.bes_attendance_archive a
  set delete_request_status = 'pending',
      delete_requested_by = v_uid,
      delete_requested_at = clock_timestamp(),
      delete_request_reason = trim(coalesce(p_reason, '')),
      delete_reviewed_by = null,
      delete_reviewed_at = null,
      delete_review_note = ''
  where a.id = p_archive_id;

  return jsonb_build_object('archive_id', p_archive_id, 'delete_request_status', 'pending');
end;
$function$;

CREATE FUNCTION public.bes_request_attendance_archive_delete(p_archive_id uuid, p_reason text DEFAULT ''::text)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.bes_request_attendance_archive_delete(p_archive_id, p_reason); $$;
REVOKE ALL ON FUNCTION public.bes_request_attendance_archive_delete(uuid, text),
  private.bes_request_attendance_archive_delete(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_request_attendance_archive_delete(uuid, text),
  private.bes_request_attendance_archive_delete(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION private.bes_review_attendance_archive_delete(p_archive_id uuid, p_approve boolean, p_note text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_archive public.bes_attendance_archive%rowtype;
begin
  if not private.attendance_is_admin() then
    raise exception 'Chỉ Admin được duyệt yêu cầu xóa vĩnh viễn.' using errcode = '42501';
  end if;

  select * into v_archive
  from public.bes_attendance_archive a
  where a.id = p_archive_id
  for update;
  if not found then
    raise exception 'Không tìm thấy mục lưu trữ.' using errcode = 'P0002';
  end if;
  if v_archive.delete_request_status not in ('pending', 'approved') then
    raise exception 'Mục này không có yêu cầu xóa đang chờ duyệt.' using errcode = '22023';
  end if;

  if coalesce(p_approve, false) then
    update public.bes_attendance_archive a
    set delete_request_status = 'approved',
        delete_reviewed_by = v_uid,
        delete_reviewed_at = clock_timestamp(),
        delete_review_note = trim(coalesce(p_note, ''))
    where a.id = p_archive_id;

    return jsonb_build_object(
      'archive_id', p_archive_id,
      'approved', true,
      'ready_for_permanent_delete', true,
      'proof_path', v_archive.proof_path,
      'reviewed_by', v_uid,
      'note', trim(coalesce(p_note, ''))
    );
  end if;

  if v_archive.delete_request_status = 'approved' then
    raise exception 'Yêu cầu này đã được duyệt xóa, không thể chuyển sang từ chối.' using errcode = '22023';
  end if;

  update public.bes_attendance_archive a
  set delete_request_status = 'rejected',
      delete_reviewed_by = v_uid,
      delete_reviewed_at = clock_timestamp(),
      delete_review_note = trim(coalesce(p_note, ''))
  where a.id = p_archive_id;

  return jsonb_build_object(
    'archive_id', p_archive_id,
    'approved', false,
    'delete_request_status', 'rejected'
  );
end;
$function$;

CREATE FUNCTION public.bes_review_attendance_archive_delete(p_archive_id uuid, p_approve boolean, p_note text DEFAULT ''::text)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.bes_review_attendance_archive_delete(p_archive_id, p_approve, p_note); $$;
REVOKE ALL ON FUNCTION public.bes_review_attendance_archive_delete(uuid, boolean, text),
  private.bes_review_attendance_archive_delete(uuid, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_review_attendance_archive_delete(uuid, boolean, text),
  private.bes_review_attendance_archive_delete(uuid, boolean, text) TO authenticated;

CREATE OR REPLACE FUNCTION private.bes_finalize_extra_class_archive_delete(p_archive_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_archive public.bes_extra_class_archive%rowtype;
begin
  if not private.attendance_is_admin() then
    raise exception 'Chi Admin moi duoc hoan tat xoa vinh vien lop.' using errcode = '42501';
  end if;

  select * into v_archive
  from public.bes_extra_class_archive a
  where a.id = p_archive_id
  for update;
  if not found then
    raise exception 'Khong tim thay lop luu tru.' using errcode = 'P0002';
  end if;

  if v_archive.delete_request_status <> 'approved' then
    raise exception 'Lop chua duoc Admin duyet xoa vinh vien.' using errcode = '22023';
  end if;

  if exists (
    select 1 from storage.objects o where o.bucket_id = 'attendance-session-proofs'
      and v_archive.proof_paths ? o.name
      and not private.attendance_archive_proof_is_shared(o.name, 'class', p_archive_id)
  ) then
    raise exception 'Ảnh minh chứng chưa được xóa khỏi Storage. Mục lưu trữ vẫn được giữ để thử lại.' using errcode = '22023';
  end if;

  delete from public.bes_extra_class_archive a where a.id = p_archive_id;

  return jsonb_build_object(
    'archive_id', p_archive_id,
    'class_id', v_archive.source_class_id,
    'class_name', v_archive.class_name,
    'finalized', true
  );
end;
$function$;

CREATE FUNCTION public.bes_finalize_extra_class_archive_delete(p_archive_id uuid)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.bes_finalize_extra_class_archive_delete(p_archive_id); $$;
REVOKE ALL ON FUNCTION public.bes_finalize_extra_class_archive_delete(uuid),
  private.bes_finalize_extra_class_archive_delete(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_finalize_extra_class_archive_delete(uuid),
  private.bes_finalize_extra_class_archive_delete(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION private.bes_request_extra_class_archive_delete(p_archive_id uuid, p_reason text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_archive public.bes_extra_class_archive%rowtype;
begin
  if not private.attendance_can_manage_roster() then
    raise exception 'Ban khong co quyen yeu cau xoa vinh vien lop.' using errcode = '42501';
  end if;

  select * into v_archive
  from public.bes_extra_class_archive a
  where a.id = p_archive_id
  for update;
  if not found then
    raise exception 'Khong tim thay lop luu tru.' using errcode = 'P0002';
  end if;

  if v_archive.delete_request_status not in ('none', 'rejected') then
    raise exception 'Muc nay khong o trang thai co the gui yeu cau xoa.' using errcode = '22023';
  end if;

  update public.bes_extra_class_archive
  set delete_request_status = 'pending',
      delete_requested_by = auth.uid(),
      delete_requested_at = clock_timestamp(),
      delete_request_reason = trim(coalesce(p_reason, '')),
      delete_reviewed_by = null,
      delete_reviewed_at = null,
      delete_review_note = ''
  where id = p_archive_id
  returning * into v_archive;

  return jsonb_build_object(
    'archive_id', v_archive.id,
    'class_name', v_archive.class_name,
    'delete_request_status', v_archive.delete_request_status,
    'requested', true
  );
end;
$function$;

CREATE FUNCTION public.bes_request_extra_class_archive_delete(p_archive_id uuid, p_reason text DEFAULT ''::text)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.bes_request_extra_class_archive_delete(p_archive_id, p_reason); $$;
REVOKE ALL ON FUNCTION public.bes_request_extra_class_archive_delete(uuid, text),
  private.bes_request_extra_class_archive_delete(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_request_extra_class_archive_delete(uuid, text),
  private.bes_request_extra_class_archive_delete(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION private.bes_review_extra_class_archive_delete(p_archive_id uuid, p_approve boolean, p_note text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_archive public.bes_extra_class_archive%rowtype;
begin
  if not private.attendance_is_admin() then
    raise exception 'Chi Admin moi duoc duyet xoa vinh vien lop.' using errcode = '42501';
  end if;

  select * into v_archive
  from public.bes_extra_class_archive a
  where a.id = p_archive_id
  for update;
  if not found then
    raise exception 'Khong tim thay lop luu tru.' using errcode = 'P0002';
  end if;

  if v_archive.delete_request_status <> 'pending' then
    raise exception 'Yeu cau nay khong o trang thai cho duyet.' using errcode = '22023';
  end if;

  update public.bes_extra_class_archive
  set delete_request_status = case when p_approve is true then 'approved' else 'rejected' end,
      delete_reviewed_by = auth.uid(),
      delete_reviewed_at = clock_timestamp(),
      delete_review_note = trim(coalesce(p_note, ''))
  where id = p_archive_id
  returning * into v_archive;

  return jsonb_build_object(
    'archive_id', v_archive.id,
    'class_name', v_archive.class_name,
    'delete_request_status', v_archive.delete_request_status,
    'proof_paths', v_archive.proof_paths,
    'approved', p_approve is true
  );
end;
$function$;

CREATE FUNCTION public.bes_review_extra_class_archive_delete(p_archive_id uuid, p_approve boolean, p_note text DEFAULT ''::text)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.bes_review_extra_class_archive_delete(p_archive_id, p_approve, p_note); $$;
REVOKE ALL ON FUNCTION public.bes_review_extra_class_archive_delete(uuid, boolean, text),
  private.bes_review_extra_class_archive_delete(uuid, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_review_extra_class_archive_delete(uuid, boolean, text),
  private.bes_review_extra_class_archive_delete(uuid, boolean, text) TO authenticated;


CREATE TABLE private.attendance_school_rosters (
  class_name text PRIMARY KEY CHECK (btrim(class_name) <> ''),
  registry_owner_id uuid NOT NULL,
  school_year text NOT NULL,
  registry_updated_at timestamptz NOT NULL,
  students jsonb NOT NULL CHECK (jsonb_typeof(students) = 'array'),
  homeroom_teacher_id uuid,
  subject_teacher_ids uuid[] NOT NULL DEFAULT '{}'
);
ALTER TABLE private.attendance_school_rosters ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.attendance_school_rosters FROM PUBLIC, anon, authenticated;

CREATE FUNCTION private.get_my_assigned_school_classes()
RETURNS TABLE(registry_owner_id uuid, class_name text, assignment_type text, class_payload jsonb, registry_updated_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT r.registry_owner_id, r.class_name,
    CASE WHEN r.homeroom_teacher_id = p.id THEN 'homeroom'
         WHEN p.id = ANY(r.subject_teacher_ids) THEN 'subject' ELSE 'managed' END,
    jsonb_build_object('className', r.class_name, 'schoolYear', r.school_year, 'students', r.students),
    r.registry_updated_at
  FROM public.profiles p CROSS JOIN private.attendance_school_rosters r
  WHERE p.id = (SELECT auth.uid()) AND p.approved
    AND ((SELECT private.attendance_is_admin()) OR (
      p.role <> 'admin' AND (
        p.role = 'department_head' OR r.homeroom_teacher_id = p.id OR p.id = ANY(r.subject_teacher_ids)
      )
    ))
  ORDER BY r.class_name;
$$;

CREATE FUNCTION public.get_my_assigned_school_classes()
RETURNS TABLE(registry_owner_id uuid, class_name text, assignment_type text, class_payload jsonb, registry_updated_at timestamptz)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = ''
AS $$ SELECT * FROM private.get_my_assigned_school_classes(); $$;
REVOKE ALL ON FUNCTION public.get_my_assigned_school_classes(),
  private.get_my_assigned_school_classes() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_assigned_school_classes(),
  private.get_my_assigned_school_classes() TO authenticated;

COMMIT;
