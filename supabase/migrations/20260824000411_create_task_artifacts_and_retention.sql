-- Round 3E: private task artifacts and retention handoff.
--
-- This migration creates one new bucket for short-lived task artifacts. It
-- intentionally does not reconfigure, query, copy, or delete any pre-existing
-- bucket or object.

begin;

-- Execution persistence owns the artifact metadata. Retention is represented
-- as a reversible request marker so the worker can delete through the Storage
-- API only after it has durably received the returned metadata.
alter table private.task_artifacts
  add column purge_requested_at timestamptz;

alter table private.task_artifacts
  add constraint task_artifacts_purge_requested_at_check
    check (
      purge_requested_at is null
      or purge_requested_at >= created_at
    );

comment on column private.task_artifacts.purge_requested_at is
  'Set by the service-only retention handoff after an expired artifact has been selected for Storage API purge.';

create index task_artifacts_expired_unrequested_idx
  on private.task_artifacts (expires_at asc, id asc)
  where purge_requested_at is null;

-- Do not upsert this bucket. An unexpected existing bucket should fail the
-- migration instead of silently changing its contents or security posture.
insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'task-artifacts',
  'task-artifacts',
  false,
  10485760,
  array[
    -- Screenshots
    'image/png',
    'image/jpeg',
    'image/webp',
    -- Download results
    'application/pdf',
    'text/plain',
    'text/csv',
    -- Redacted diagnostic payloads; HTML and generic binary uploads are not allowed.
    'application/json'
  ]::text[]
);

-- Storage evaluates grants as well as RLS. These explicit grants allow an
-- RLS-scoped, authenticated API request to perform the permitted operations.
grant usage on schema storage to authenticated;
grant select, insert, update, delete on table storage.objects to authenticated;

-- Each object name must be exactly:
--   {auth.uid()}/{task UUID}/{filename}
-- The user prefix and Storage owner must both match the JWT. The second path
-- component is intentionally an opaque task UUID: task metadata remains in a
-- private, server-only schema.
create policy task_artifacts_storage_select_own
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'task-artifacts'
    and owner_id = (select auth.uid()::text)
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] = (select auth.uid()::text)
    and (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and storage.filename(name) <> ''
  );

create policy task_artifacts_storage_insert_own
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'task-artifacts'
    and owner_id = (select auth.uid()::text)
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] = (select auth.uid()::text)
    and (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and storage.filename(name) <> ''
  );

-- SELECT and UPDATE are both needed by the Storage API upsert path. The
-- WITH CHECK expression prevents a rename, owner change, or bucket change
-- from escaping the caller's user/task namespace.
create policy task_artifacts_storage_update_own
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'task-artifacts'
    and owner_id = (select auth.uid()::text)
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] = (select auth.uid()::text)
    and (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and storage.filename(name) <> ''
  )
  with check (
    bucket_id = 'task-artifacts'
    and owner_id = (select auth.uid()::text)
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] = (select auth.uid()::text)
    and (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and storage.filename(name) <> ''
  );

create policy task_artifacts_storage_delete_own
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'task-artifacts'
    and owner_id = (select auth.uid()::text)
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] = (select auth.uid()::text)
    and (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and storage.filename(name) <> ''
  );

-- Returns a bounded list of expired, not-yet-requested artifact metadata.
-- It does not mutate metadata or Storage objects.
create or replace function private.select_expired_task_artifacts(
  p_limit integer default 100,
  p_as_of timestamptz default pg_catalog.now()
)
returns table (
  artifact_id uuid,
  user_id uuid,
  task_id uuid,
  artifact_type text,
  storage_bucket text,
  storage_path text,
  content_hash text,
  expires_at timestamptz,
  created_at timestamptz,
  purge_requested_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $function$
begin
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'p_limit must be between 1 and 100'
      using errcode = '22023';
  end if;

  if p_as_of is null then
    raise exception 'p_as_of must not be null'
      using errcode = '22004';
  end if;

  return query
  select
    artifact.id,
    artifact.user_id,
    artifact.task_id,
    artifact.artifact_type,
    'task-artifacts'::text,
    artifact.storage_path,
    artifact.content_hash,
    artifact.expires_at,
    artifact.created_at,
    artifact.purge_requested_at
  from private.task_artifacts as artifact
  where artifact.expires_at <= p_as_of
    and artifact.purge_requested_at is null
  order by artifact.expires_at asc, artifact.id asc
  limit p_limit;
end;
$function$;

-- Atomically marks a bounded set of expired artifacts for a worker to purge
-- through the Storage API and returns their metadata. It never deletes rows or
-- mutates Storage objects directly. SKIP LOCKED makes concurrent dispatchers
-- claim disjoint rows without blocking each other.
create or replace function private.request_expired_task_artifact_purge(
  p_limit integer default 100,
  p_as_of timestamptz default pg_catalog.now()
)
returns table (
  artifact_id uuid,
  user_id uuid,
  task_id uuid,
  artifact_type text,
  storage_bucket text,
  storage_path text,
  content_hash text,
  expires_at timestamptz,
  created_at timestamptz,
  purge_requested_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'p_limit must be between 1 and 100'
      using errcode = '22023';
  end if;

  if p_as_of is null then
    raise exception 'p_as_of must not be null'
      using errcode = '22004';
  end if;

  return query
  with candidates as (
    select artifact.id
    from private.task_artifacts as artifact
    where artifact.expires_at <= p_as_of
      and artifact.purge_requested_at is null
    order by artifact.expires_at asc, artifact.id asc
    limit p_limit
    for update skip locked
  ),
  marked as (
    update private.task_artifacts as artifact
    set purge_requested_at = pg_catalog.now()
    from candidates
    where artifact.id = candidates.id
    returning
      artifact.id,
      artifact.user_id,
      artifact.task_id,
      artifact.artifact_type,
      artifact.storage_path,
      artifact.content_hash,
      artifact.expires_at,
      artifact.created_at,
      artifact.purge_requested_at
  )
  select
    marked.id,
    marked.user_id,
    marked.task_id,
    marked.artifact_type,
    'task-artifacts'::text,
    marked.storage_path,
    marked.content_hash,
    marked.expires_at,
    marked.created_at,
    marked.purge_requested_at
  from marked
  order by marked.expires_at asc, marked.id asc;
end;
$function$;

-- Private retention helpers are executable only by the trusted service role.
-- They use a pinned search path and expose no RPC surface to browser clients.
revoke execute on function private.select_expired_task_artifacts(integer, timestamptz)
  from public, anon, authenticated;
revoke execute on function private.request_expired_task_artifact_purge(integer, timestamptz)
  from public, anon, authenticated;

grant usage on schema private to service_role;
grant execute on function private.select_expired_task_artifacts(integer, timestamptz)
  to service_role;
grant execute on function private.request_expired_task_artifact_purge(integer, timestamptz)
  to service_role;

comment on function private.select_expired_task_artifacts(integer, timestamptz) is
  'Service-only selector for bounded, expired task artifact metadata; does not mutate Storage.';
comment on function private.request_expired_task_artifact_purge(integer, timestamptz) is
  'Service-only atomic retention handoff; marks metadata and returns it for a worker, without deleting Storage objects.';

commit;
