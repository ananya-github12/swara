-- Round 3B: least-privilege access controls for cloud workflows.
--
-- Table privileges and row-level policies are separate controls.  The table
-- grants below expose only the operations required by authenticated users;
-- the policies then restrict those operations to the owning Swara user.

-- No anonymous or PUBLIC table access.
REVOKE ALL PRIVILEGES ON TABLE public.workflows FROM PUBLIC;
REVOKE ALL PRIVILEGES ON TABLE public.workflows FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.workflows FROM authenticated;

REVOKE ALL PRIVILEGES ON TABLE public.workflow_versions FROM PUBLIC;
REVOKE ALL PRIVILEGES ON TABLE public.workflow_versions FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.workflow_versions FROM authenticated;

-- Workflows are owner-managed CRUD records.
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE public.workflows TO authenticated;

-- Versions are readable and appendable by their owner only.  Deliberately do
-- not grant UPDATE or DELETE so authenticated clients cannot mutate history.
GRANT SELECT, INSERT
  ON TABLE public.workflow_versions TO authenticated;

ALTER TABLE public.workflows ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workflow_versions ENABLE ROW LEVEL SECURITY;

-- Workflows: owner-scoped CRUD.
CREATE POLICY workflows_select_own
  ON public.workflows
  FOR SELECT
  TO authenticated
  USING ((select auth.uid()) = user_id);

CREATE POLICY workflows_insert_own
  ON public.workflows
  FOR INSERT
  TO authenticated
  WITH CHECK ((select auth.uid()) = user_id);

CREATE POLICY workflows_update_own
  ON public.workflows
  FOR UPDATE
  TO authenticated
  USING ((select auth.uid()) = user_id)
  WITH CHECK ((select auth.uid()) = user_id);

CREATE POLICY workflows_delete_own
  ON public.workflows
  FOR DELETE
  TO authenticated
  USING ((select auth.uid()) = user_id);

-- Versions: a version is visible only when both its recorded owner and its
-- parent workflow belong to the authenticated user.  The parent check also
-- prevents inconsistent ownership from becoming client-visible.
CREATE POLICY workflow_versions_select_own
  ON public.workflow_versions
  FOR SELECT
  TO authenticated
  USING (
    (select auth.uid()) = user_id
    AND EXISTS (
      SELECT 1
      FROM public.workflows AS workflow
      WHERE workflow.id = workflow_id
        AND workflow.user_id = (select auth.uid())
    )
  );

CREATE POLICY workflow_versions_insert_own
  ON public.workflow_versions
  FOR INSERT
  TO authenticated
  WITH CHECK (
    (select auth.uid()) = user_id
    AND EXISTS (
      SELECT 1
      FROM public.workflows AS workflow
      WHERE workflow.id = workflow_id
        AND workflow.user_id = (select auth.uid())
    )
  );

-- There are intentionally no UPDATE or DELETE policies for workflow_versions.
