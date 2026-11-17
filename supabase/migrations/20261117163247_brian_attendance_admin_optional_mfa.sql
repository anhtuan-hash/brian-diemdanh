BEGIN;

ALTER TABLE public.profiles ADD COLUMN attendance_mfa_required boolean NOT NULL DEFAULT true;
REVOKE UPDATE (attendance_mfa_required) ON public.profiles FROM PUBLIC, anon, authenticated;

CREATE TABLE private.attendance_admin_mfa_changes (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  admin_id uuid NOT NULL,
  required boolean NOT NULL,
  changed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE private.attendance_admin_mfa_changes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.attendance_admin_mfa_changes FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.attendance_is_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = (SELECT auth.uid()) AND p.approved AND p.role = 'admin'
      AND ((SELECT auth.jwt() ->> 'aal') = 'aal2' OR NOT p.attendance_mfa_required)
  );
$$;

DO $mfa_migration$
DECLARE
  class_definition text := pg_get_functiondef('private.attendance_can_read_class(uuid)'::regprocedure);
  original_condition text := '(p.role = ''admin'' AND (SELECT auth.jwt() ->> ''aal'') = ''aal2'')';
BEGIN
  IF position(original_condition IN class_definition) = 0 THEN
    RAISE EXCEPTION 'Expected the existing attendance class access check.';
  END IF;
  EXECUTE replace(class_definition, original_condition, 'private.attendance_is_admin()');
END
$mfa_migration$;

CREATE FUNCTION private.bes_set_own_attendance_mfa(p_required boolean)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  actor uuid := (SELECT auth.uid());
  current_requirement boolean;
BEGIN
  IF p_required IS NULL THEN
    RAISE EXCEPTION 'Trạng thái xác thực không hợp lệ.' USING ERRCODE = '22023';
  END IF;

  SELECT p.attendance_mfa_required INTO current_requirement
  FROM public.profiles p
  WHERE p.id = actor AND p.approved AND p.role = 'admin'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Chỉ Admin được duyệt mới có thể đổi thiết lập này.' USING ERRCODE = '42501';
  END IF;
  IF current_requirement = p_required THEN RETURN current_requirement; END IF;
  IF NOT p_required AND (SELECT auth.jwt() ->> 'aal') IS DISTINCT FROM 'aal2' THEN
    RAISE EXCEPTION 'Hãy xác thực hai yếu tố trước khi tắt yêu cầu này.' USING ERRCODE = '42501';
  END IF;

  UPDATE public.profiles SET attendance_mfa_required = p_required WHERE id = actor;
  INSERT INTO private.attendance_admin_mfa_changes(admin_id, required) VALUES (actor, p_required);
  RETURN p_required;
END;
$$;

CREATE FUNCTION public.bes_set_own_attendance_mfa(p_required boolean)
RETURNS boolean LANGUAGE sql SECURITY INVOKER SET search_path = ''
AS $$ SELECT private.bes_set_own_attendance_mfa(p_required); $$;
REVOKE ALL ON FUNCTION private.bes_set_own_attendance_mfa(boolean),
  public.bes_set_own_attendance_mfa(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.bes_set_own_attendance_mfa(boolean),
  public.bes_set_own_attendance_mfa(boolean) TO authenticated;

COMMIT;
