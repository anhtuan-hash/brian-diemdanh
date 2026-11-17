BEGIN;
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon;
GRANT USAGE ON SCHEMA private TO authenticated;

CREATE FUNCTION private.attendance_can_read_class(target_class_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $body$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles p
    JOIN public.bes_extra_classes c ON c.id = target_class_id
    WHERE p.id = (SELECT auth.uid())
      AND p.approved IS TRUE
      AND (
        (p.role = 'admin' AND (SELECT auth.jwt() ->> 'aal') = 'aal2')
        OR (
          c.teacher_id = p.id
          OR (c.teacher_id IS NULL AND nullif(btrim(c.teacher_email), '') IS NOT NULL
              AND lower(btrim(c.teacher_email)) = lower(btrim(p.email)))
          OR EXISTS (
            SELECT 1 FROM public.bes_extra_class_teachers t
            WHERE t.class_id = c.id
              AND (t.teacher_id = p.id OR (
                t.teacher_id IS NULL AND nullif(btrim(t.teacher_email), '') IS NOT NULL
                AND lower(btrim(t.teacher_email)) = lower(btrim(p.email))
              ))
          )
        )
      )
  );
$body$;
REVOKE ALL ON FUNCTION private.attendance_can_read_class(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.attendance_can_read_class(uuid) TO authenticated;

CREATE POLICY attendance_read_own_profile ON public.profiles
  FOR SELECT TO authenticated USING (id = (SELECT auth.uid()));
CREATE POLICY attendance_read_own_role ON public.system_roles
  FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY attendance_read_assigned_class ON public.bes_extra_classes
  FOR SELECT TO authenticated USING (private.attendance_can_read_class(id));
GRANT SELECT ON public.profiles, public.system_roles, public.bes_extra_classes TO authenticated;

CREATE POLICY attendance_read_assigned_class ON public.bes_extra_class_members FOR SELECT TO authenticated USING (private.attendance_can_read_class(class_id));
GRANT SELECT ON public.bes_extra_class_members TO authenticated;
CREATE POLICY attendance_read_assigned_class ON public.bes_extra_class_teachers FOR SELECT TO authenticated USING (private.attendance_can_read_class(class_id));
GRANT SELECT ON public.bes_extra_class_teachers TO authenticated;
CREATE POLICY attendance_read_assigned_class ON public.bes_extra_attendance_sessions FOR SELECT TO authenticated USING (private.attendance_can_read_class(class_id));
GRANT SELECT ON public.bes_extra_attendance_sessions TO authenticated;
CREATE POLICY attendance_read_assigned_class ON public.bes_extra_attendance_records FOR SELECT TO authenticated USING (private.attendance_can_read_class(class_id));
GRANT SELECT ON public.bes_extra_attendance_records TO authenticated;
CREATE POLICY attendance_read_assigned_class ON public.bes_extra_attendance_record_changes FOR SELECT TO authenticated USING (private.attendance_can_read_class(class_id));
GRANT SELECT ON public.bes_extra_attendance_record_changes TO authenticated;

CREATE POLICY attendance_read_assigned_session_proof ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'attendance-session-proofs'
    AND EXISTS (
      SELECT 1 FROM public.bes_extra_attendance_sessions s
      WHERE s.proof_path = storage.objects.name
        AND private.attendance_can_read_class(s.class_id)
    )
  );
COMMIT;
