-- Round 1C: least-privilege access controls for Swara identity data.
--
-- Table privileges and row-level policies are deliberately separate controls:
-- privileges decide whether a role can reach a table at all, while policies
-- restrict the rows that an authenticated user may reach.

-- No anonymous or PUBLIC table access.  Revoke first so this migration is
-- deterministic even if a prior environment supplied broader defaults.
REVOKE ALL PRIVILEGES ON TABLE public.profiles FROM PUBLIC;
REVOKE ALL PRIVILEGES ON TABLE public.profiles FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.profiles FROM authenticated;

REVOKE ALL PRIVILEGES ON TABLE public.user_settings FROM PUBLIC;
REVOKE ALL PRIVILEGES ON TABLE public.user_settings FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.user_settings FROM authenticated;

REVOKE ALL PRIVILEGES ON TABLE public.devices FROM PUBLIC;
REVOKE ALL PRIVILEGES ON TABLE public.devices FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.devices FROM authenticated;

REVOKE ALL PRIVILEGES ON TABLE public.domain_policies FROM PUBLIC;
REVOKE ALL PRIVILEGES ON TABLE public.domain_policies FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.domain_policies FROM authenticated;

REVOKE ALL PRIVILEGES ON TABLE public.consent_records FROM PUBLIC;
REVOKE ALL PRIVILEGES ON TABLE public.consent_records FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.consent_records FROM authenticated;

-- Profiles, settings, devices, and domain policies are user-owned CRUD data.
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE public.profiles TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE public.user_settings TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE public.devices TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE public.domain_policies TO authenticated;

-- Consent history is append-only for authenticated clients.
GRANT SELECT, INSERT
  ON TABLE public.consent_records TO authenticated;

-- Enable row-level security independently of the table grants above.
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.domain_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.consent_records ENABLE ROW LEVEL SECURITY;

-- Profiles: owner-scoped CRUD.
CREATE POLICY profiles_select_own
  ON public.profiles
  FOR SELECT
  TO authenticated
  USING ((select auth.uid()) = user_id);

CREATE POLICY profiles_insert_own
  ON public.profiles
  FOR INSERT
  TO authenticated
  WITH CHECK ((select auth.uid()) = user_id);

CREATE POLICY profiles_update_own
  ON public.profiles
  FOR UPDATE
  TO authenticated
  USING ((select auth.uid()) = user_id)
  WITH CHECK ((select auth.uid()) = user_id);

CREATE POLICY profiles_delete_own
  ON public.profiles
  FOR DELETE
  TO authenticated
  USING ((select auth.uid()) = user_id);

-- User settings: owner-scoped CRUD.
CREATE POLICY user_settings_select_own
  ON public.user_settings
  FOR SELECT
  TO authenticated
  USING ((select auth.uid()) = user_id);

CREATE POLICY user_settings_insert_own
  ON public.user_settings
  FOR INSERT
  TO authenticated
  WITH CHECK ((select auth.uid()) = user_id);

CREATE POLICY user_settings_update_own
  ON public.user_settings
  FOR UPDATE
  TO authenticated
  USING ((select auth.uid()) = user_id)
  WITH CHECK ((select auth.uid()) = user_id);

CREATE POLICY user_settings_delete_own
  ON public.user_settings
  FOR DELETE
  TO authenticated
  USING ((select auth.uid()) = user_id);

-- Devices: owner-scoped CRUD.
CREATE POLICY devices_select_own
  ON public.devices
  FOR SELECT
  TO authenticated
  USING ((select auth.uid()) = user_id);

CREATE POLICY devices_insert_own
  ON public.devices
  FOR INSERT
  TO authenticated
  WITH CHECK ((select auth.uid()) = user_id);

CREATE POLICY devices_update_own
  ON public.devices
  FOR UPDATE
  TO authenticated
  USING ((select auth.uid()) = user_id)
  WITH CHECK ((select auth.uid()) = user_id);

CREATE POLICY devices_delete_own
  ON public.devices
  FOR DELETE
  TO authenticated
  USING ((select auth.uid()) = user_id);

-- Domain policies: owner-scoped CRUD.
CREATE POLICY domain_policies_select_own
  ON public.domain_policies
  FOR SELECT
  TO authenticated
  USING ((select auth.uid()) = user_id);

CREATE POLICY domain_policies_insert_own
  ON public.domain_policies
  FOR INSERT
  TO authenticated
  WITH CHECK ((select auth.uid()) = user_id);

CREATE POLICY domain_policies_update_own
  ON public.domain_policies
  FOR UPDATE
  TO authenticated
  USING ((select auth.uid()) = user_id)
  WITH CHECK ((select auth.uid()) = user_id);

CREATE POLICY domain_policies_delete_own
  ON public.domain_policies
  FOR DELETE
  TO authenticated
  USING ((select auth.uid()) = user_id);

-- Consent records: append-only, owner-scoped read and insert.  There are
-- intentionally no UPDATE or DELETE grants or policies for authenticated.
CREATE POLICY consent_records_select_own
  ON public.consent_records
  FOR SELECT
  TO authenticated
  USING ((select auth.uid()) = user_id);

CREATE POLICY consent_records_insert_own
  ON public.consent_records
  FOR INSERT
  TO authenticated
  WITH CHECK ((select auth.uid()) = user_id);
