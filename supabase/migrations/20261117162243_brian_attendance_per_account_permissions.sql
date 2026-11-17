BEGIN;

ALTER TABLE public.profiles ADD COLUMN attendance_permissions text[];
ALTER TABLE public.profiles ADD CONSTRAINT profiles_attendance_permissions_valid CHECK (
  attendance_permissions <@ ARRAY['attendance:quick','attendance:calendar','attendance:manage',
    'attendance:history','attendance:report','attendance:supplemental','attendance:delete']::text[]
  AND array_position(attendance_permissions, NULL) IS NULL
);
REVOKE UPDATE (attendance_permissions) ON public.profiles FROM PUBLIC, anon, authenticated;

CREATE TABLE private.attendance_permission_changes (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id uuid NOT NULL,
  admin_id uuid NOT NULL,
  previous_permissions text[],
  new_permissions text[] NOT NULL,
  changed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE private.attendance_permission_changes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.attendance_permission_changes FROM PUBLIC, anon, authenticated;

CREATE FUNCTION private.attendance_permissions_configured()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = (SELECT auth.uid())
    AND p.approved AND p.attendance_permissions IS NOT NULL);
$$;

CREATE OR REPLACE FUNCTION private.attendance_global_permission(permission_id text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = (SELECT auth.uid()) AND p.approved AND p.role <> 'admin'
      AND CASE WHEN p.attendance_permissions IS NOT NULL THEN permission_id = ANY(p.attendance_permissions)
        ELSE jsonb_typeof(p.permissions -> 'allowed') = 'array' AND (p.permissions -> 'allowed') ? permission_id END
  );
$$;

CREATE OR REPLACE FUNCTION private.attendance_can_write()
RETURNS boolean LANGUAGE sql STABLE SET search_path = ''
AS $$
  SELECT private.attendance_is_admin()
    OR private.attendance_global_permission('attendance:quick')
    OR (NOT private.attendance_permissions_configured() AND private.attendance_global_permission('attendance:report'));
$$;

CREATE FUNCTION private.attendance_can_read_details()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT private.attendance_is_admin() OR EXISTS (
    SELECT 1 FROM public.profiles p WHERE p.id = (SELECT auth.uid()) AND p.approved
      AND p.role <> 'admin' AND (p.attendance_permissions IS NULL OR p.attendance_permissions &&
      ARRAY['attendance:quick','attendance:manage','attendance:history','attendance:report'])
  );
$$;

CREATE FUNCTION private.attendance_can_use_class_archive()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT private.attendance_is_admin()
    OR (private.attendance_can_manage_roster() AND
    (NOT private.attendance_permissions_configured() OR private.attendance_global_permission('attendance:delete')));
$$;

CREATE OR REPLACE FUNCTION private.bes_is_supplemental_manager()
RETURNS boolean LANGUAGE sql STABLE SET search_path = ''
AS $$
  SELECT private.attendance_is_admin()
    OR private.attendance_global_permission(CASE WHEN private.attendance_permissions_configured()
      THEN 'attendance:supplemental' ELSE 'attendance:manage' END);
$$;

REVOKE ALL ON FUNCTION private.attendance_permissions_configured(), private.attendance_can_read_details(),
  private.attendance_can_use_class_archive() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.attendance_permissions_configured(), private.attendance_can_read_details() TO authenticated;

ALTER POLICY attendance_read_assigned_class ON public.bes_extra_class_members
  USING (private.attendance_can_read_class(class_id) AND (SELECT private.attendance_can_read_details()));
ALTER POLICY attendance_read_assigned_class ON public.bes_extra_attendance_records
  USING (private.attendance_can_read_class(class_id) AND (SELECT private.attendance_can_read_details()));
ALTER POLICY attendance_read_assigned_class ON public.bes_extra_attendance_record_changes
  USING (private.attendance_can_read_class(class_id) AND (SELECT private.attendance_can_read_details()));
ALTER POLICY attendance_read_assigned_session_proof ON storage.objects
  USING (bucket_id = 'attendance-session-proofs' AND (SELECT private.attendance_can_read_details()) AND EXISTS (
    SELECT 1 FROM public.bes_extra_attendance_sessions s
    WHERE s.proof_path = objects.name AND private.attendance_can_read_class(s.class_id)
  ));

CREATE FUNCTION private.bes_list_attendance_permission_accounts()
RETURNS TABLE(id uuid, full_name text, email text, approved boolean, attendance_permissions text[], effective_permissions text[])
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF NOT private.attendance_is_admin() THEN
    RAISE EXCEPTION 'Chỉ Admin đã xác thực hai lớp được xem quyền.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT p.id, p.full_name, p.email, p.approved, p.attendance_permissions,
    coalesce(p.attendance_permissions, ARRAY(
      SELECT x.permission_id FROM (VALUES
        ('attendance:quick', p.permissions -> 'allowed' ?| ARRAY['route:attendance','attendance:quick','attendance:report']),
        ('attendance:calendar', true),
        ('attendance:manage', p.permissions -> 'allowed' ?| ARRAY['route:attendance','attendance:manage']),
        ('attendance:history', true),
        ('attendance:report', p.permissions -> 'allowed' ?| ARRAY['route:attendance','attendance:report']),
        ('attendance:supplemental', p.permissions -> 'allowed' ?| ARRAY['route:attendance','attendance:manage']),
        ('attendance:delete', p.permissions -> 'allowed' ? 'attendance:delete')
      ) x(permission_id, permitted) WHERE x.permitted))
  FROM public.profiles p WHERE p.role <> 'admin'
  ORDER BY p.approved DESC, lower(p.full_name), lower(p.email), p.id;
END;
$$;

CREATE FUNCTION private.bes_set_attendance_permissions(p_account uuid, p_permissions text[], p_expected text[])
RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  previous text[];
  requested text[];
BEGIN
  IF NOT private.attendance_is_admin() THEN
    RAISE EXCEPTION 'Chỉ Admin đã xác thực hai lớp được lưu quyền.' USING ERRCODE = '42501';
  END IF;
  IF p_permissions IS NULL OR array_position(p_permissions, NULL) IS NOT NULL OR NOT (
    p_permissions <@ ARRAY['attendance:quick','attendance:calendar','attendance:manage',
    'attendance:history','attendance:report','attendance:supplemental','attendance:delete']::text[]
  ) THEN
    RAISE EXCEPTION 'Danh sách quyền Điểm danh không hợp lệ.' USING ERRCODE = '22023';
  END IF;
  SELECT p.attendance_permissions INTO previous FROM public.profiles p
    WHERE p.id = p_account AND p.role <> 'admin' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Không tìm thấy tài khoản có thể phân quyền.' USING ERRCODE = 'P0002'; END IF;
  requested := ARRAY(SELECT DISTINCT x.permission_id FROM unnest(p_permissions) x(permission_id) ORDER BY x.permission_id);
  IF previous IS NOT DISTINCT FROM requested THEN RETURN requested; END IF;
  IF previous IS DISTINCT FROM p_expected THEN
    RAISE EXCEPTION 'Quyền của tài khoản đã thay đổi. Hãy tải lại danh sách trước khi lưu.' USING ERRCODE = '40001';
  END IF;
  UPDATE public.profiles SET attendance_permissions = requested WHERE id = p_account;
  INSERT INTO private.attendance_permission_changes(account_id, admin_id, previous_permissions, new_permissions)
    VALUES (p_account, auth.uid(), previous, requested);
  RETURN requested;
END;
$$;

CREATE FUNCTION public.bes_list_attendance_permission_accounts()
RETURNS TABLE(id uuid, full_name text, email text, approved boolean, attendance_permissions text[], effective_permissions text[])
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = ''
AS $$ SELECT * FROM private.bes_list_attendance_permission_accounts(); $$;

CREATE FUNCTION public.bes_set_attendance_permissions(p_account uuid, p_permissions text[], p_expected text[])
RETURNS text[] LANGUAGE sql SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.bes_set_attendance_permissions(p_account, p_permissions, p_expected); $$;

REVOKE ALL ON FUNCTION private.bes_list_attendance_permission_accounts(),
  public.bes_list_attendance_permission_accounts(),
  private.bes_set_attendance_permissions(uuid, text[], text[]),
  public.bes_set_attendance_permissions(uuid, text[], text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_list_attendance_permission_accounts(),
  public.bes_list_attendance_permission_accounts(),
  private.bes_set_attendance_permissions(uuid, text[], text[]),
  public.bes_set_attendance_permissions(uuid, text[], text[]) TO authenticated;

-- Retain the existing checks in these routines and narrow the relevant grants.
DO $permission_migration$
DECLARE
  rule record;
  definition text;
BEGIN
  FOR rule IN SELECT * FROM (VALUES
    ('private.attendance_can_read_class(uuid)',
      'OR (p.role <> ''admin'' AND (',
      'OR (p.role <> ''admin'' AND (p.attendance_permissions IS NULL OR p.attendance_permissions && ARRAY[''attendance:quick'',''attendance:calendar'',''attendance:manage'',''attendance:history'',''attendance:report'']) AND ('),
    ('private.bes_extra_attendance_edit_decision(uuid,timestamptz)',
      'v_has_report := private.attendance_global_permission(''attendance:report'');',
      'v_has_report := private.attendance_global_permission(''attendance:report'') AND private.attendance_can_write();'),
    ('private.attendance_supplemental_access_decision()', 'private.attendance_can_manage_roster()', 'private.bes_is_supplemental_manager()'),
    ('private.bes_archive_attendance_history(text,uuid)', 'and not private.attendance_can_manage_roster()', 'and not private.bes_is_supplemental_manager()'),
    ('private.bes_restore_attendance_archive(uuid)', 'and not private.attendance_can_manage_roster()', 'and not private.bes_is_supplemental_manager()'),
    ('private.bes_archive_extra_class(uuid)', 'private.attendance_can_manage_roster()', 'private.attendance_can_use_class_archive()'),
    ('private.bes_list_extra_class_archive()', 'private.attendance_can_manage_roster()', 'private.attendance_can_use_class_archive()'),
    ('private.bes_restore_extra_class_archive(uuid)', 'private.attendance_can_manage_roster()', 'private.attendance_can_use_class_archive()'),
    ('private.bes_request_extra_class_archive_delete(uuid,text)', 'private.attendance_can_manage_roster()', 'private.attendance_can_use_class_archive()'),
    ('private.attendance_archive_proof_can_read(text)', 'private.attendance_can_manage_roster()', 'private.attendance_can_use_class_archive()'),
    ('private.get_my_assigned_school_classes()',
      'p.role <> ''admin'' AND (',
      'p.role <> ''admin'' AND (p.attendance_permissions IS NULL OR ''attendance:manage'' = ANY(p.attendance_permissions)) AND (')
  ) AS updates(signature, original, replacement)
  LOOP
    definition := pg_get_functiondef(rule.signature::regprocedure);
    IF position(rule.original IN definition) = 0 THEN
      RAISE EXCEPTION 'Permission migration cannot find expected logic in %.', rule.signature;
    END IF;
    EXECUTE replace(definition, rule.original, rule.replacement);
  END LOOP;
END
$permission_migration$;

COMMIT;
