BEGIN;

CREATE OR REPLACE FUNCTION private.bes_delete_supplemental_class(p_group_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid;
  v_group public.bes_supplemental_groups%rowtype;
  v_session_count integer := 0;
  v_participant_count integer := 0;
  v_member_count integer := 0;
  v_teacher_count integer := 0;
  v_change_count integer := 0;
  v_proof_paths jsonb := '[]'::jsonb;
begin
  v_uid := private.bes_require_supplemental_manager();

  select * into v_group
  from public.bes_supplemental_groups g
  where g.id = p_group_id
  for update;

  if not found then
    raise exception 'Không tìm thấy lớp Học bổ sung cần xóa.' using errcode = 'P0002';
  end if;


  if exists (
    select 1 from public.bes_supplemental_sessions s
    where s.group_id = p_group_id and nullif(btrim(s.proof_path), '') is not null
  ) or exists (
    select 1 from public.bes_attendance_archive a
    where a.source_type = 'supplemental' and a.session_snapshot->>'group_id' = p_group_id::text
  ) then
    raise exception 'Lớp còn minh chứng hoặc buổi điểm danh trong kho lưu trữ. Hãy xử lý các buổi đó trong Kho lưu trữ trước khi xóa lớp.' using errcode = '22023';
  end if;

  select count(*)::integer,
         coalesce(jsonb_agg(s.proof_path) filter (where nullif(btrim(coalesce(s.proof_path, '')), '') is not null), '[]'::jsonb)
  into v_session_count, v_proof_paths
  from public.bes_supplemental_sessions s
  where s.group_id = p_group_id;

  select count(*)::integer into v_participant_count
  from public.bes_supplemental_session_participants p
  where p.session_id in (select s.id from public.bes_supplemental_sessions s where s.group_id = p_group_id);

  select count(*)::integer into v_change_count
  from public.bes_supplemental_attendance_record_changes c
  where c.session_id in (select s.id from public.bes_supplemental_sessions s where s.group_id = p_group_id);

  select count(*)::integer into v_member_count
  from public.bes_supplemental_group_memberships m
  where m.group_id = p_group_id;

  select count(*)::integer into v_teacher_count
  from public.bes_supplemental_group_teachers t
  where t.group_id = p_group_id;

  delete from public.bes_supplemental_attendance_record_changes c
  where c.session_id in (select s.id from public.bes_supplemental_sessions s where s.group_id = p_group_id);

  delete from public.bes_supplemental_session_participants p
  where p.session_id in (select s.id from public.bes_supplemental_sessions s where s.group_id = p_group_id);

  delete from public.bes_supplemental_sessions s where s.group_id = p_group_id;
  delete from public.bes_supplemental_group_memberships m where m.group_id = p_group_id;
  delete from public.bes_supplemental_group_teachers t where t.group_id = p_group_id;
  delete from public.bes_supplemental_groups g where g.id = p_group_id;

  return jsonb_build_object(
    'group_id', v_group.id,
    'class_name', v_group.group_name,
    'deleted_sessions', v_session_count,
    'deleted_participants', v_participant_count,
    'deleted_changes', v_change_count,
    'deleted_members', v_member_count,
    'deleted_teachers', v_teacher_count,
    'proof_paths', v_proof_paths,
    'deleted_by', v_uid
  );
end;
$function$;

CREATE FUNCTION public.bes_delete_supplemental_class(p_group_id uuid)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.bes_delete_supplemental_class(p_group_id); $$;
REVOKE ALL ON FUNCTION public.bes_delete_supplemental_class(uuid),
  private.bes_delete_supplemental_class(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bes_delete_supplemental_class(uuid),
  private.bes_delete_supplemental_class(uuid) TO authenticated;

COMMIT;
