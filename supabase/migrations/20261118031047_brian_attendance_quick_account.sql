BEGIN;

CREATE FUNCTION private.bes_provision_attendance_account(
  p_account uuid, p_username text, p_full_name text, p_permissions text[]
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  actor uuid := auth.uid();
  login_email text := p_username || '@accounts.brianenglish.studio';
  requested text[];
  account public.profiles%ROWTYPE;
BEGIN
  IF NOT private.attendance_is_admin() THEN
    RAISE EXCEPTION 'Chỉ Admin có phiên xác thực hợp lệ mới được tạo tài khoản.' USING ERRCODE = '42501';
  END IF;
  IF p_username IS NULL OR p_username !~ '^[a-z0-9][a-z0-9._-]{1,30}[a-z0-9]$'
    OR p_full_name IS NULL OR length(btrim(p_full_name)) NOT BETWEEN 1 AND 120
    OR p_permissions IS NULL OR cardinality(p_permissions) NOT BETWEEN 1 AND 7
    OR array_position(p_permissions, NULL) IS NOT NULL
    OR NOT (p_permissions <@ ARRAY['attendance:quick','attendance:calendar','attendance:manage',
        'attendance:history','attendance:report','attendance:supplemental','attendance:delete']::text[])
  THEN
    RAISE EXCEPTION 'Thông tin tạo tài khoản không hợp lệ.' USING ERRCODE = '22023';
  END IF;

  -- An Auth user must originate from this Edge Function and this same admin.
  IF NOT EXISTS (
    SELECT 1 FROM auth.users u
    WHERE u.id = p_account AND u.email = login_email AND u.deleted_at IS NULL
      AND u.raw_app_meta_data ->> 'attendance_created_by' = actor::text
  ) THEN
    RAISE EXCEPTION 'Chưa xác nhận được tài khoản đăng nhập mới.' USING ERRCODE = 'P0002';
  END IF;
  requested := ARRAY(SELECT DISTINCT permission FROM unnest(p_permissions) AS permission ORDER BY permission);

  INSERT INTO public.profiles (
    id, email, username, full_name, role, approved, auth_mode, must_change_password, permissions, attendance_permissions
  ) VALUES (
    p_account, login_email, p_username, btrim(p_full_name), 'teacher', true, 'username', false,
    '{"mode":"all","allowed":[]}'::jsonb, requested
  )
  ON CONFLICT (id) DO NOTHING
  RETURNING * INTO account;

  IF FOUND THEN
    INSERT INTO private.attendance_permission_changes(account_id, admin_id, previous_permissions, new_permissions)
    VALUES (p_account, actor, NULL, requested);
  ELSE
    -- Retry of a request whose first response was lost. Preserve subsequent admin edits.
    SELECT p.* INTO account FROM public.profiles p
    WHERE p.id = p_account AND p.username = p_username AND p.email = login_email AND p.role = 'teacher';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Hồ sơ tài khoản đã tồn tại.' USING ERRCODE = '55000';
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'id', account.id, 'email', account.email, 'full_name', account.full_name, 'approved', account.approved,
    'attendance_permissions', account.attendance_permissions,
    'effective_permissions', coalesce(account.attendance_permissions, ARRAY[]::text[])
  );
END;
$$;

CREATE FUNCTION public.bes_provision_attendance_account(
  p_account uuid, p_username text, p_full_name text, p_permissions text[]
)
RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.bes_provision_attendance_account(p_account, p_username, p_full_name, p_permissions); $$;

REVOKE ALL ON FUNCTION private.bes_provision_attendance_account(uuid, text, text, text[]),
  public.bes_provision_attendance_account(uuid, text, text, text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_provision_attendance_account(uuid, text, text, text[]),
  public.bes_provision_attendance_account(uuid, text, text, text[]) TO authenticated;

COMMIT;
