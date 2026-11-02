-- Round 6A: close the durable worker handoffs.

begin;

create or replace function private.enqueue_vault_ingestion_job()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if old.status is distinct from 'processing' and new.status = 'processing' then
    perform private.enqueue_job(
      'vault-ingest',
      pg_catalog.jsonb_build_object(
        'schema_version', 1,
        'job_type', 'vault_ingest',
        'job_id', new.id::text,
        'idempotency_key', pg_catalog.format('vault-ingest:%s:%s', new.id, new.sha256),
        'correlation_id', new.id::text
      ),
      0
    );
  end if;
  return new;
end;
$function$;

create or replace function private.prepare_account_export(p_request_id uuid)
returns table (request_id uuid, user_id uuid, payload jsonb)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid;
  v_status text;
begin
  select request.user_id, request.status
    into v_user_id, v_status
    from private.account_export_requests as request
   where request.id = p_request_id
   for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'Account export request was not found';
  end if;
  if v_status not in ('queued', 'processing') then
    return query select p_request_id, v_user_id, '{}'::jsonb;
    return;
  end if;

  update private.account_export_requests
     set status = 'processing',
         started_at = coalesce(started_at, pg_catalog.now()),
         error_code = null,
         error_message = null
   where id = p_request_id;

  return query select p_request_id, v_user_id, pg_catalog.jsonb_build_object(
    'schema_version', 1,
    'exported_at', pg_catalog.now(),
    'profile', coalesce((select pg_catalog.to_jsonb(profile) from public.profiles profile where profile.user_id = v_user_id), '{}'::jsonb),
    'settings', coalesce((select pg_catalog.to_jsonb(settings) from public.user_settings settings where settings.user_id = v_user_id), '{}'::jsonb),
    'devices', coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(device) order by device.created_at) from public.devices device where device.user_id = v_user_id), '[]'::jsonb),
    'vault_documents', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', document.id, 'filename', document.filename, 'mime_type', document.mime_type,
      'size_bytes', document.size_bytes, 'sha256', document.sha256, 'status', document.status,
      'extraction_method', document.extraction_method, 'created_at', document.created_at,
      'updated_at', document.updated_at) order by document.created_at)
      from public.vault_documents document where document.user_id = v_user_id), '[]'::jsonb),
    'context_items', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', context.id, 'type', context.type, 'key', context.key, 'value', context.value,
      'category', context.category, 'sensitivity', context.sensitivity,
      'source_document_id', context.source_document_id, 'source_type', context.source_type,
      'scope', context.scope, 'status', context.status, 'version', context.version,
      'created_at', context.created_at, 'updated_at', context.updated_at) order by context.created_at)
      from public.swara_context_items context where context.user_id = v_user_id), '[]'::jsonb),
    'workflows', coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(workflow) order by workflow.created_at)
      from public.workflows workflow where workflow.user_id = v_user_id), '[]'::jsonb)
  );
end;
$function$;

create or replace function private.complete_account_export(p_request_id uuid, p_storage_path text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare v_completed boolean := false;
begin
  if p_request_id is null or p_storage_path is null
     or p_storage_path <> pg_catalog.btrim(p_storage_path)
     or p_storage_path !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[A-Za-z0-9._-]+$' then
    raise exception using errcode = '22023', message = 'Account export completion input is invalid';
  end if;
  update private.account_export_requests
     set status = 'ready', storage_path = p_storage_path,
         completed_at = coalesce(completed_at, pg_catalog.now()),
         expires_at = coalesce(expires_at, pg_catalog.now() + interval '7 days'),
         error_code = null, error_message = null
   where id = p_request_id and status in ('queued', 'processing')
  returning true into v_completed;
  return coalesce(v_completed, false);
end;
$function$;

create or replace function private.fail_account_export(p_request_id uuid, p_error_code text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare v_failed boolean := false;
begin
  if p_request_id is null or p_error_code is null
     or p_error_code <> pg_catalog.lower(pg_catalog.btrim(p_error_code))
     or p_error_code !~ '^[a-z0-9][a-z0-9_.:-]{0,127}$' then
    raise exception using errcode = '22023', message = 'Account export failure input is invalid';
  end if;
  update private.account_export_requests
     set status = 'failed', completed_at = coalesce(completed_at, pg_catalog.now()),
         error_code = p_error_code, error_message = null
   where id = p_request_id and status in ('queued', 'processing')
  returning true into v_failed;
  return coalesce(v_failed, false);
end;
$function$;

create or replace function private.claim_expired_account_exports(p_limit integer default 100)
returns table (request_id uuid, user_id uuid, storage_path text)
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception using errcode = '22023', message = 'Account export claim limit is invalid';
  end if;
  return query
  with candidates as (
    select request.id from private.account_export_requests request
     where request.status = 'ready' and request.expires_at <= pg_catalog.now()
       and request.storage_path is not null
     order by request.expires_at, request.id limit p_limit for update skip locked
  ), expired as (
    update private.account_export_requests request set status = 'expired'
      from candidates where request.id = candidates.id
      returning request.id, request.user_id, request.storage_path
  ) select expired.id, expired.user_id, expired.storage_path from expired;
end;
$function$;

-- Define this before its privilege boundary below. The original migration
-- placed it after COMMIT, which made a clean reset fail before reaching the
-- subsequent billing migrations.
create or replace function private.prepare_vault_ingestion(p_document_id uuid)
returns table (
  document_id uuid,
  user_id uuid,
  sha256 text,
  mime_type text,
  size_bytes bigint,
  storage_bucket text,
  storage_path text,
  status text
)
language sql
security definer
set search_path = ''
as $function$
  select document.id, document.user_id, document.sha256, document.mime_type,
         document.size_bytes, document.storage_bucket, document.storage_path,
         document.status
    from public.vault_documents as document
   where document.id = p_document_id
     and document.status = 'processing'
   limit 1
$function$;

create or replace function private.select_stuck_vault_ingestion(p_as_of timestamptz default pg_catalog.now())
returns table (document_id uuid, sha256 text)
language sql
security definer
set search_path = ''
as $function$
  select document.id, document.sha256
    from public.vault_documents as document
   where document.status = 'processing'
     and document.updated_at <= p_as_of - interval '30 minutes'
   order by document.updated_at, document.id
   limit 50
$function$;

create or replace function private.list_account_storage_objects(p_user_id uuid)
returns table (storage_bucket text, storage_path text)
language sql
security definer
set search_path = ''
as $function$
  select document.storage_bucket, document.storage_path
    from public.vault_documents document
   where document.user_id = p_user_id
  union all
  select 'account-exports'::text, request.storage_path
    from private.account_export_requests request
   where request.user_id = p_user_id
     and request.storage_path is not null
$function$;

create or replace function private.revoke_account_sessions(p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if p_user_id is null then
    raise exception using errcode = '22023', message = 'Account session revocation requires a user identifier';
  end if;
  delete from auth.sessions where user_id = p_user_id;
  return true;
end;
$function$;

revoke all privileges on function private.enqueue_vault_ingestion_job() from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.prepare_vault_ingestion(uuid) from public, anon, authenticated, service_role, swara_api_runtime;
revoke all privileges on function private.select_stuck_vault_ingestion(timestamptz) from public, anon, authenticated, service_role, swara_api_runtime;
revoke all privileges on function private.list_account_storage_objects(uuid) from public, anon, authenticated, service_role, swara_api_runtime;
revoke all privileges on function private.revoke_account_sessions(uuid) from public, anon, authenticated, service_role, swara_api_runtime;
revoke all privileges on function private.prepare_account_export(uuid) from public, anon, authenticated, service_role, swara_api_runtime;
revoke all privileges on function private.complete_account_export(uuid, text) from public, anon, authenticated, service_role, swara_api_runtime;
revoke all privileges on function private.fail_account_export(uuid, text) from public, anon, authenticated, service_role, swara_api_runtime;
revoke all privileges on function private.claim_expired_account_exports(integer) from public, anon, authenticated, service_role, swara_api_runtime;
grant usage on schema private to swara_worker_runtime;
grant execute on function private.prepare_vault_ingestion(uuid), private.select_stuck_vault_ingestion(timestamptz), private.list_account_storage_objects(uuid), private.revoke_account_sessions(uuid), private.prepare_account_export(uuid), private.complete_account_export(uuid, text), private.fail_account_export(uuid, text), private.claim_expired_account_exports(integer) to swara_worker_runtime;
grant update on table private.entitlement_snapshots to swara_worker_runtime;
create policy entitlement_snapshots_worker_runtime_update
  on private.entitlement_snapshots
  for update to swara_worker_runtime
  using (true) with check (true);

drop trigger if exists vault_documents_enqueue_ingestion on public.vault_documents;
create trigger vault_documents_enqueue_ingestion
  after update of status on public.vault_documents
  for each row
  when (old.status is distinct from new.status and new.status = 'processing')
  execute function private.enqueue_vault_ingestion_job();

commit;
