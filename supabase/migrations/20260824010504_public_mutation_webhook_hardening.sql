-- Round 5 M022: final browser-mutation, Storage, and webhook hardening.
--
-- This migration deliberately has no DML against storage.objects for the
-- legacy `documents` bucket.  The bucket and any objects already in it remain
-- outside the Swara data model; a pre-existing Vault metadata reference to
-- that bucket fails closed instead of being adopted.

begin;

do $runtime_roles$
begin
  if not exists (
    select 1 from pg_catalog.pg_roles where rolname = 'swara_api_runtime'
  ) or not exists (
    select 1 from pg_catalog.pg_roles where rolname = 'swara_worker_runtime'
  ) then
    raise exception using
      errcode = '55000',
      message = 'M022 requires the M018 Swara runtime permission groups';
  end if;
end;
$runtime_roles$;

-- M019 installs pgcrypto, but repeat the idempotent declaration because the
-- operation hashes below are security boundaries rather than convenience
-- values.  No caller-controlled value is ever stored in a ledger un-hashed.
create extension if not exists pgcrypto with schema extensions;

-- A Swara Vault row must never point at a legacy Storage bucket.  Do not
-- rewrite such a row: it lacks verified ownership mapping and needs explicit
-- operator remediation.  This check touches metadata only, never Storage
-- objects or buckets.
do $legacy_vault_metadata$
begin
  if exists (
    select 1
      from public.vault_documents as document
     where document.storage_bucket not in ('vault-originals', 'vault-derived')
  ) then
    raise exception using
      errcode = '55000',
      message = 'Vault metadata references an unsupported Storage bucket and requires explicit remediation';
  end if;
end;
$legacy_vault_metadata$;

alter table public.vault_documents
  drop constraint if exists vault_documents_storage_bucket_check;

alter table public.vault_documents
  add constraint vault_documents_storage_bucket_check
  check (storage_bucket in ('vault-originals', 'vault-derived'));

comment on column public.vault_documents.storage_bucket is
  'Swara-owned private Storage bucket only: vault-originals or vault-derived. Legacy buckets are never mapped into Vault metadata.';

-- These ledgers contain only bounded identifiers, canonical SHA-256 digests,
-- operation state, and durable result IDs.  They deliberately omit request
-- bodies, webhook payloads, browser installation IDs, vendor tenant IDs, and
-- user-entered document content.
create table if not exists private.alterity_webhook_receipts (
  event_id text primary key,
  body_sha256 text not null,
  signed_at timestamptz not null,
  event_type text not null,
  status text not null default 'claimed',
  attempt_count integer not null default 1,
  first_received_at timestamptz not null default pg_catalog.clock_timestamp(),
  last_received_at timestamptz not null default pg_catalog.clock_timestamp(),
  claimed_at timestamptz not null default pg_catalog.clock_timestamp(),
  processed_at timestamptz,
  safe_error_code text,

  constraint alterity_webhook_receipts_event_id_check
    check (
      event_id = pg_catalog.btrim(event_id)
      and pg_catalog.char_length(event_id) between 1 and 200
      and event_id ~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$'
    ),
  constraint alterity_webhook_receipts_body_sha256_check
    check (
      body_sha256 = pg_catalog.lower(body_sha256)
      and body_sha256 ~ '^[0-9a-f]{64}$'
    ),
  constraint alterity_webhook_receipts_event_type_check
    check (
      event_type = pg_catalog.lower(pg_catalog.btrim(event_type))
      and pg_catalog.char_length(event_type) between 1 and 80
      and event_type ~ '^[a-z][a-z0-9._-]*$'
    ),
  constraint alterity_webhook_receipts_status_check
    check (status in ('claimed', 'processed', 'failed')),
  constraint alterity_webhook_receipts_attempt_count_check
    check (attempt_count between 1 and 1000),
  constraint alterity_webhook_receipts_timestamps_check
    check (
      last_received_at >= first_received_at
      and claimed_at >= first_received_at
      and signed_at >= first_received_at - interval '15 minutes'
      and signed_at <= first_received_at + interval '5 minutes'
    ),
  constraint alterity_webhook_receipts_error_code_check
    check (
      safe_error_code is null
      or (
        safe_error_code = pg_catalog.lower(pg_catalog.btrim(safe_error_code))
        and pg_catalog.char_length(safe_error_code) between 1 and 64
        and safe_error_code ~ '^[a-z0-9][a-z0-9._-]*$'
      )
    ),
  constraint alterity_webhook_receipts_state_check
    check (
      (status = 'claimed' and processed_at is null and safe_error_code is null)
      or (status = 'processed' and processed_at is not null and safe_error_code is null)
      or (status = 'failed' and processed_at is not null and safe_error_code is not null)
    )
);

create index if not exists alterity_webhook_receipts_status_received_idx
  on private.alterity_webhook_receipts (status, last_received_at asc);

create table if not exists private.device_mutation_requests (
  user_id uuid not null references auth.users(id) on delete cascade,
  operation text not null,
  idempotency_key text not null,
  input_hash text not null,
  device_id uuid not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),

  constraint device_mutation_requests_pkey
    primary key (user_id, operation, idempotency_key),
  constraint device_mutation_requests_operation_check
    check (operation in ('register', 'revoke')),
  constraint device_mutation_requests_idempotency_key_check
    check (
      idempotency_key = pg_catalog.btrim(idempotency_key)
      and pg_catalog.char_length(idempotency_key) between 8 and 200
      and idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$'
    ),
  constraint device_mutation_requests_input_hash_check
    check (
      input_hash = pg_catalog.lower(input_hash)
      and input_hash ~ '^[0-9a-f]{64}$'
    ),
  constraint device_mutation_requests_device_owner_fkey
    foreign key (device_id, user_id)
    references public.devices (id, user_id)
    on delete cascade
);

create table if not exists private.vault_document_requests (
  user_id uuid not null references auth.users(id) on delete cascade,
  operation text not null,
  idempotency_key text not null,
  input_hash text not null,
  document_id uuid not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),

  constraint vault_document_requests_pkey
    primary key (user_id, operation, idempotency_key),
  constraint vault_document_requests_operation_check
    check (operation in ('create_upload_intent', 'finalize_upload', 'soft_delete')),
  constraint vault_document_requests_idempotency_key_check
    check (
      idempotency_key = pg_catalog.btrim(idempotency_key)
      and pg_catalog.char_length(idempotency_key) between 8 and 200
      and idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$'
    ),
  constraint vault_document_requests_input_hash_check
    check (
      input_hash = pg_catalog.lower(input_hash)
      and input_hash ~ '^[0-9a-f]{64}$'
    ),
  constraint vault_document_requests_document_owner_fkey
    foreign key (document_id, user_id)
    references public.vault_documents (id, user_id)
    on delete cascade
);

alter table private.alterity_webhook_receipts enable row level security;
alter table private.device_mutation_requests enable row level security;
alter table private.vault_document_requests enable row level security;

revoke all privileges on table
  private.alterity_webhook_receipts,
  private.device_mutation_requests,
  private.vault_document_requests
  from public, anon, authenticated, service_role,
       swara_api_runtime, swara_worker_runtime;

-- Browser-facing public tables remain readable through the authenticated Data
-- API, but all mutations are narrowed to reviewed private functions.  The
-- API runtime gets no broad direct public-table write grant; it receives only
-- the dedicated SECURITY DEFINER functions below.
revoke all privileges on table public.devices
  from public, anon, authenticated, service_role, swara_worker_runtime;
grant select on table public.devices to authenticated;

revoke all privileges on table public.vault_documents,
  public.swara_context_items,
  public.workflows,
  public.workflow_versions
  from public, anon, authenticated, service_role,
       swara_api_runtime, swara_worker_runtime;
grant select on table public.vault_documents to authenticated;
grant select, insert on table public.swara_context_items to authenticated;
grant select on table public.workflows, public.workflow_versions to authenticated;

alter table public.devices enable row level security;
alter table public.vault_documents enable row level security;
alter table public.swara_context_items enable row level security;
alter table public.workflows enable row level security;
alter table public.workflow_versions enable row level security;

-- Keep only owner-read policies for direct authenticated access.  Context
-- remains intentionally append-only, because the version trigger turns a
-- controlled correction insert into an atomic supersession.
drop policy if exists devices_insert_own on public.devices;
drop policy if exists devices_update_own on public.devices;
drop policy if exists devices_delete_own on public.devices;

drop policy if exists vault_documents_insert_own on public.vault_documents;
drop policy if exists vault_documents_update_own on public.vault_documents;
drop policy if exists vault_documents_delete_own on public.vault_documents;
drop policy if exists vault_documents_service_role_all on public.vault_documents;

drop policy if exists context_items_update_own on public.swara_context_items;
drop policy if exists context_items_delete_own on public.swara_context_items;
drop policy if exists context_items_service_role_all on public.swara_context_items;

drop policy if exists workflows_insert_own on public.workflows;
drop policy if exists workflows_update_own on public.workflows;
drop policy if exists workflows_delete_own on public.workflows;
drop policy if exists workflow_versions_insert_own on public.workflow_versions;

-- A device registration receives an installation *hash* from the verified
-- Edge layer; the raw browser installation ID is never accepted or persisted.
create or replace function private.register_device(
  p_user_id uuid,
  p_installation_hash text,
  p_browser text,
  p_extension_version text,
  p_device_public_key text,
  p_idempotency_key text
)
returns table (
  device_id uuid,
  revoked_at timestamptz,
  duplicate boolean
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_input_hash text;
  v_prior_input_hash text;
  v_prior_device_id uuid;
  v_device_id uuid;
  v_revoked_at timestamptz;
begin
  if p_user_id is null
     or p_installation_hash is null
     or p_installation_hash <> pg_catalog.lower(pg_catalog.btrim(p_installation_hash))
     or p_installation_hash !~ '^[0-9a-f]{64}$' then
    raise exception using
      errcode = '22023',
      message = 'Device registration requires a canonical installation SHA-256 hash';
  end if;

  if p_browser is null
     or p_browser <> pg_catalog.btrim(p_browser)
     or pg_catalog.char_length(p_browser) not between 1 and 128
     or p_browser ~ '[[:cntrl:]]'
     or p_extension_version is null
     or p_extension_version <> pg_catalog.btrim(p_extension_version)
     or pg_catalog.char_length(p_extension_version) not between 1 and 128
     or p_extension_version ~ '[[:cntrl:]]' then
    raise exception using
      errcode = '22023',
      message = 'Device registration metadata is invalid';
  end if;

  if p_device_public_key is not null and (
       p_device_public_key <> pg_catalog.btrim(p_device_public_key)
       or pg_catalog.char_length(p_device_public_key) not between 1 and 16384
       or p_device_public_key ~ '[[:cntrl:]]'
     ) then
    raise exception using
      errcode = '22023',
      message = 'Device public key is invalid';
  end if;

  if p_idempotency_key is null
     or p_idempotency_key <> pg_catalog.btrim(p_idempotency_key)
     or pg_catalog.char_length(p_idempotency_key) not between 8 and 200
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$' then
    raise exception using
      errcode = '22023',
      message = 'Device registration idempotency key is invalid';
  end if;

  if not exists (
    select 1 from auth.users as account where account.id = p_user_id
  ) then
    raise exception using
      errcode = '22023',
      message = 'Device owner is not available';
  end if;

  v_input_hash := pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(
        pg_catalog.jsonb_build_object(
          'user_id', p_user_id,
          'installation_hash', p_installation_hash,
          'browser', p_browser,
          'extension_version', p_extension_version,
          'device_public_key', p_device_public_key
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'swara-device-register:' || p_user_id::text || ':' || p_idempotency_key,
      8072026::bigint
    )
  );

  select request.input_hash, request.device_id
    into v_prior_input_hash, v_prior_device_id
    from private.device_mutation_requests as request
   where request.user_id = p_user_id
     and request.operation = 'register'
     and request.idempotency_key = p_idempotency_key
   for update;

  if found then
    if v_prior_input_hash is distinct from v_input_hash then
      raise exception using
        errcode = '22023',
        message = 'Device registration idempotency key is bound to different input';
    end if;

    select device.revoked_at
      into v_revoked_at
      from public.devices as device
     where device.id = v_prior_device_id
       and device.user_id = p_user_id;

    if not found then
      raise exception using
        errcode = '55000',
        message = 'Device registration result is no longer available';
    end if;

    return query select v_prior_device_id, v_revoked_at, true;
    return;
  end if;

  insert into public.devices (
    user_id,
    installation_hash,
    browser,
    extension_version,
    device_public_key,
    revoked_at,
    last_seen_at
  )
  values (
    p_user_id,
    p_installation_hash,
    p_browser,
    p_extension_version,
    p_device_public_key,
    null,
    pg_catalog.clock_timestamp()
  )
  on conflict (user_id, installation_hash) do update
    set browser = excluded.browser,
        extension_version = excluded.extension_version,
        device_public_key = excluded.device_public_key,
        revoked_at = null,
        last_seen_at = pg_catalog.clock_timestamp()
  returning id, public.devices.revoked_at into v_device_id, v_revoked_at;

  insert into private.device_mutation_requests (
    user_id,
    operation,
    idempotency_key,
    input_hash,
    device_id
  )
  values (
    p_user_id,
    'register',
    p_idempotency_key,
    v_input_hash,
    v_device_id
  );

  return query select v_device_id, v_revoked_at, false;
end;
$function$;

create or replace function private.revoke_device(
  p_user_id uuid,
  p_device_id uuid,
  p_idempotency_key text
)
returns table (
  device_id uuid,
  revoked_at timestamptz,
  duplicate boolean
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_input_hash text;
  v_prior_input_hash text;
  v_prior_device_id uuid;
  v_revoked_at timestamptz;
begin
  if p_user_id is null or p_device_id is null then
    raise exception using
      errcode = '22023',
      message = 'Device revocation requires owner and device identifiers';
  end if;

  if p_idempotency_key is null
     or p_idempotency_key <> pg_catalog.btrim(p_idempotency_key)
     or pg_catalog.char_length(p_idempotency_key) not between 8 and 200
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$' then
    raise exception using
      errcode = '22023',
      message = 'Device revocation idempotency key is invalid';
  end if;

  v_input_hash := pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(
        pg_catalog.jsonb_build_object(
          'user_id', p_user_id,
          'device_id', p_device_id
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'swara-device-revoke:' || p_user_id::text || ':' || p_idempotency_key,
      8072026::bigint
    )
  );

  select request.input_hash, request.device_id
    into v_prior_input_hash, v_prior_device_id
    from private.device_mutation_requests as request
   where request.user_id = p_user_id
     and request.operation = 'revoke'
     and request.idempotency_key = p_idempotency_key
   for update;

  if found then
    if v_prior_input_hash is distinct from v_input_hash then
      raise exception using
        errcode = '22023',
        message = 'Device revocation idempotency key is bound to different input';
    end if;

    select device.revoked_at
      into v_revoked_at
      from public.devices as device
     where device.id = v_prior_device_id
       and device.user_id = p_user_id;

    if not found then
      raise exception using
        errcode = '55000',
        message = 'Device revocation result is no longer available';
    end if;

    return query select v_prior_device_id, v_revoked_at, true;
    return;
  end if;

  select device.revoked_at
    into v_revoked_at
    from public.devices as device
   where device.id = p_device_id
     and device.user_id = p_user_id
   for update;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'Device is not available';
  end if;

  if v_revoked_at is null then
    update public.devices as device
       set revoked_at = pg_catalog.clock_timestamp()
     where device.id = p_device_id
       and device.user_id = p_user_id
    returning device.revoked_at into v_revoked_at;
  end if;

  insert into private.device_mutation_requests (
    user_id,
    operation,
    idempotency_key,
    input_hash,
    device_id
  )
  values (
    p_user_id,
    'revoke',
    p_idempotency_key,
    v_input_hash,
    p_device_id
  );

  return query select p_device_id, v_revoked_at, false;
end;
$function$;

-- The upload-intent API constructs the bucket/path inside the database.  It
-- creates metadata only; Edge verifies the uploaded Storage object before it
-- asks finalize_vault_upload to advance the state.
create or replace function private.create_vault_upload_intent(
  p_user_id uuid,
  p_filename text,
  p_mime_type text,
  p_size_bytes bigint,
  p_sha256 text,
  p_extraction_method text,
  p_idempotency_key text
)
returns table (
  document_id uuid,
  storage_bucket text,
  storage_path text,
  status text,
  duplicate boolean
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_input_hash text;
  v_prior_input_hash text;
  v_document_id uuid;
  v_existing_filename text;
  v_storage_bucket text;
  v_storage_path text;
  v_status text;
  v_expected_path text;
begin
  if p_user_id is null
     or p_filename is null
     or p_filename <> pg_catalog.btrim(p_filename)
     or pg_catalog.char_length(p_filename) not between 1 and 255
     or p_filename in ('.', '..')
     or pg_catalog.strpos(p_filename, '/') > 0
     or pg_catalog.strpos(p_filename, E'\\') > 0
     or p_filename ~ '[[:cntrl:]]'
     or p_mime_type is null
     or p_mime_type <> pg_catalog.btrim(p_mime_type)
     or p_mime_type not in (
       'application/pdf',
       'application/msword',
       'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
       'application/vnd.ms-excel',
       'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
       'application/vnd.ms-powerpoint',
       'application/vnd.openxmlformats-officedocument.presentationml.presentation',
       'application/vnd.oasis.opendocument.text',
       'application/vnd.oasis.opendocument.spreadsheet',
       'application/vnd.oasis.opendocument.presentation',
       'application/rtf',
       'application/epub+zip',
       'text/plain',
       'text/markdown',
       'text/csv',
       'text/rtf',
       'image/jpeg',
       'image/png',
       'image/webp',
       'image/tiff'
     )
     or p_size_bytes is null
     or p_size_bytes not between 1 and 52428800
     or p_sha256 is null
     or p_sha256 <> pg_catalog.lower(pg_catalog.btrim(p_sha256))
     or p_sha256 !~ '^[0-9a-f]{64}$'
     or p_extraction_method is null
     or p_extraction_method not in ('local', 'ocr', 'manual') then
    raise exception using
      errcode = '22023',
      message = 'Vault upload intent input is invalid';
  end if;

  if p_idempotency_key is null
     or p_idempotency_key <> pg_catalog.btrim(p_idempotency_key)
     or pg_catalog.char_length(p_idempotency_key) not between 8 and 200
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$' then
    raise exception using
      errcode = '22023',
      message = 'Vault upload intent idempotency key is invalid';
  end if;

  if not exists (
    select 1 from auth.users as account where account.id = p_user_id
  ) then
    raise exception using
      errcode = '22023',
      message = 'Vault owner is not available';
  end if;

  v_input_hash := pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(
        pg_catalog.jsonb_build_object(
          'user_id', p_user_id,
          'filename', p_filename,
          'mime_type', p_mime_type,
          'size_bytes', p_size_bytes,
          'sha256', p_sha256,
          'extraction_method', p_extraction_method
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'swara-vault-upload-intent:' || p_user_id::text || ':' || p_idempotency_key,
      8072026::bigint
    )
  );

  select request.input_hash, request.document_id
    into v_prior_input_hash, v_document_id
    from private.vault_document_requests as request
   where request.user_id = p_user_id
     and request.operation = 'create_upload_intent'
     and request.idempotency_key = p_idempotency_key
   for update;

  if found then
    if v_prior_input_hash is distinct from v_input_hash then
      raise exception using
        errcode = '22023',
        message = 'Vault upload intent idempotency key is bound to different input';
    end if;

    select document.storage_bucket, document.storage_path, document.status
      into v_storage_bucket, v_storage_path, v_status
      from public.vault_documents as document
     where document.id = v_document_id
       and document.user_id = p_user_id;

    if not found then
      raise exception using
        errcode = '55000',
        message = 'Vault upload intent result is no longer available';
    end if;

    return query select v_document_id, v_storage_bucket, v_storage_path, v_status, true;
    return;
  end if;

  v_document_id := pg_catalog.gen_random_uuid();
  v_expected_path := p_user_id::text || '/' || v_document_id::text || '/' || p_filename;

  insert into public.vault_documents as document (
    id,
    user_id,
    filename,
    mime_type,
    size_bytes,
    sha256,
    storage_bucket,
    storage_path,
    extraction_method,
    status,
    error_code,
    error_message,
    deleted_at
  )
  values (
    v_document_id,
    p_user_id,
    p_filename,
    p_mime_type,
    p_size_bytes,
    p_sha256,
    'vault-originals',
    v_expected_path,
    p_extraction_method,
    'pending',
    null,
    null,
    null
  )
  on conflict (user_id, sha256) do nothing
  returning document.id, document.filename, document.storage_bucket, document.storage_path, document.status
    into v_document_id, v_existing_filename, v_storage_bucket, v_storage_path, v_status;

  if not found then
    select
      document.id,
      document.filename,
      document.storage_bucket,
      document.storage_path,
      document.status
    into
      v_document_id,
      v_existing_filename,
      v_storage_bucket,
      v_storage_path,
      v_status
    from public.vault_documents as document
    where document.user_id = p_user_id
      and document.sha256 = p_sha256
    for update;

    if not found then
      raise exception using
        errcode = '55000',
        message = 'Vault document could not be recovered';
    end if;

    v_expected_path := p_user_id::text || '/' || v_document_id::text || '/' || p_filename;
    if v_existing_filename is distinct from p_filename
       or v_storage_bucket is distinct from 'vault-originals'
       or v_storage_path is distinct from v_expected_path then
      raise exception using
        errcode = '22023',
        message = 'Vault content hash is already bound to different document metadata';
    end if;

    if v_status = 'deleted' then
      update public.vault_documents as document
         set mime_type = p_mime_type,
             size_bytes = p_size_bytes,
             extraction_method = p_extraction_method,
             status = 'pending',
             error_code = null,
             error_message = null,
             deleted_at = null
       where document.id = v_document_id
         and document.user_id = p_user_id
      returning document.storage_bucket, document.storage_path, document.status
        into v_storage_bucket, v_storage_path, v_status;
    end if;
  end if;

  insert into private.vault_document_requests (
    user_id,
    operation,
    idempotency_key,
    input_hash,
    document_id
  )
  values (
    p_user_id,
    'create_upload_intent',
    p_idempotency_key,
    v_input_hash,
    v_document_id
  );

  return query select v_document_id, v_storage_bucket, v_storage_path, v_status, false;
end;
$function$;

create or replace function private.finalize_vault_upload(
  p_user_id uuid,
  p_document_id uuid,
  p_sha256 text,
  p_idempotency_key text
)
returns table (
  document_id uuid,
  storage_bucket text,
  storage_path text,
  status text,
  duplicate boolean
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_input_hash text;
  v_prior_input_hash text;
  v_prior_document_id uuid;
  v_filename text;
  v_actual_sha256 text;
  v_storage_bucket text;
  v_storage_path text;
  v_status text;
  v_expected_path text;
begin
  if p_user_id is null
     or p_document_id is null
     or p_sha256 is null
     or p_sha256 <> pg_catalog.lower(pg_catalog.btrim(p_sha256))
     or p_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception using
      errcode = '22023',
      message = 'Vault upload finalization input is invalid';
  end if;

  if p_idempotency_key is null
     or p_idempotency_key <> pg_catalog.btrim(p_idempotency_key)
     or pg_catalog.char_length(p_idempotency_key) not between 8 and 200
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$' then
    raise exception using
      errcode = '22023',
      message = 'Vault upload finalization idempotency key is invalid';
  end if;

  v_input_hash := pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(
        pg_catalog.jsonb_build_object(
          'user_id', p_user_id,
          'document_id', p_document_id,
          'sha256', p_sha256
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'swara-vault-finalize:' || p_user_id::text || ':' || p_idempotency_key,
      8072026::bigint
    )
  );

  select request.input_hash, request.document_id
    into v_prior_input_hash, v_prior_document_id
    from private.vault_document_requests as request
   where request.user_id = p_user_id
     and request.operation = 'finalize_upload'
     and request.idempotency_key = p_idempotency_key
   for update;

  if found then
    if v_prior_input_hash is distinct from v_input_hash then
      raise exception using
        errcode = '22023',
        message = 'Vault upload finalization idempotency key is bound to different input';
    end if;

    select document.storage_bucket, document.storage_path, document.status
      into v_storage_bucket, v_storage_path, v_status
      from public.vault_documents as document
     where document.id = v_prior_document_id
       and document.user_id = p_user_id;

    if not found then
      raise exception using
        errcode = '55000',
        message = 'Vault upload finalization result is no longer available';
    end if;

    return query select v_prior_document_id, v_storage_bucket, v_storage_path, v_status, true;
    return;
  end if;

  select
    document.filename,
    document.sha256,
    document.storage_bucket,
    document.storage_path,
    document.status
  into
    v_filename,
    v_actual_sha256,
    v_storage_bucket,
    v_storage_path,
    v_status
  from public.vault_documents as document
  where document.id = p_document_id
    and document.user_id = p_user_id
  for update;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'Vault document is not available';
  end if;

  v_expected_path := p_user_id::text || '/' || p_document_id::text || '/' || v_filename;
  if v_actual_sha256 is distinct from p_sha256
     or v_storage_bucket is distinct from 'vault-originals'
     or v_storage_path is distinct from v_expected_path then
    raise exception using
      errcode = '22023',
      message = 'Vault upload finalization does not match the pending document';
  end if;

  if v_status = 'pending' then
    update public.vault_documents as document
       set status = 'processing',
           error_code = null,
           error_message = null
     where document.id = p_document_id
       and document.user_id = p_user_id
    returning document.status into v_status;
  elsif v_status in ('processing', 'ready') then
    null;
  else
    raise exception using
      errcode = '22023',
      message = 'Vault document cannot be finalized from its current state';
  end if;

  insert into private.vault_document_requests (
    user_id,
    operation,
    idempotency_key,
    input_hash,
    document_id
  )
  values (
    p_user_id,
    'finalize_upload',
    p_idempotency_key,
    v_input_hash,
    p_document_id
  );

  return query select p_document_id, v_storage_bucket, v_storage_path, v_status, false;
end;
$function$;

create or replace function private.soft_delete_vault_document(
  p_user_id uuid,
  p_document_id uuid,
  p_idempotency_key text
)
returns table (
  document_id uuid,
  deleted_at timestamptz,
  duplicate boolean
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_input_hash text;
  v_prior_input_hash text;
  v_prior_document_id uuid;
  v_filename text;
  v_storage_bucket text;
  v_storage_path text;
  v_status text;
  v_deleted_at timestamptz;
  v_expected_path text;
begin
  if p_user_id is null or p_document_id is null then
    raise exception using
      errcode = '22023',
      message = 'Vault document deletion requires owner and document identifiers';
  end if;

  if p_idempotency_key is null
     or p_idempotency_key <> pg_catalog.btrim(p_idempotency_key)
     or pg_catalog.char_length(p_idempotency_key) not between 8 and 200
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$' then
    raise exception using
      errcode = '22023',
      message = 'Vault document deletion idempotency key is invalid';
  end if;

  v_input_hash := pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(
        pg_catalog.jsonb_build_object(
          'user_id', p_user_id,
          'document_id', p_document_id
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'swara-vault-soft-delete:' || p_user_id::text || ':' || p_idempotency_key,
      8072026::bigint
    )
  );

  select request.input_hash, request.document_id
    into v_prior_input_hash, v_prior_document_id
    from private.vault_document_requests as request
   where request.user_id = p_user_id
     and request.operation = 'soft_delete'
     and request.idempotency_key = p_idempotency_key
   for update;

  if found then
    if v_prior_input_hash is distinct from v_input_hash then
      raise exception using
        errcode = '22023',
        message = 'Vault document deletion idempotency key is bound to different input';
    end if;

    select document.deleted_at
      into v_deleted_at
      from public.vault_documents as document
     where document.id = v_prior_document_id
       and document.user_id = p_user_id;

    if not found then
      raise exception using
        errcode = '55000',
        message = 'Vault document deletion result is no longer available';
    end if;

    return query select v_prior_document_id, v_deleted_at, true;
    return;
  end if;

  select
    document.filename,
    document.storage_bucket,
    document.storage_path,
    document.status,
    document.deleted_at
  into
    v_filename,
    v_storage_bucket,
    v_storage_path,
    v_status,
    v_deleted_at
  from public.vault_documents as document
  where document.id = p_document_id
    and document.user_id = p_user_id
  for update;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'Vault document is not available';
  end if;

  v_expected_path := p_user_id::text || '/' || p_document_id::text || '/' || v_filename;
  if v_storage_bucket not in ('vault-originals', 'vault-derived')
     or v_storage_path is distinct from v_expected_path then
    raise exception using
      errcode = '22023',
      message = 'Vault document has an invalid Storage location';
  end if;

  if v_status <> 'deleted' then
    update public.vault_documents as document
       set status = 'deleted',
           deleted_at = pg_catalog.clock_timestamp(),
           error_code = null,
           error_message = null
     where document.id = p_document_id
       and document.user_id = p_user_id
    returning document.deleted_at into v_deleted_at;
  end if;

  insert into private.vault_document_requests (
    user_id,
    operation,
    idempotency_key,
    input_hash,
    document_id
  )
  values (
    p_user_id,
    'soft_delete',
    p_idempotency_key,
    v_input_hash,
    p_document_id
  );

  return query select p_document_id, v_deleted_at, false;
end;
$function$;

-- Ingestion workers need one bounded terminal transition after they have
-- processed the private original.  They cannot write Vault metadata directly,
-- and this function records only a safe error code, never an extractor error
-- body or document content.
create or replace function private.complete_vault_document_processing(
  p_document_id uuid,
  p_sha256 text,
  p_status text,
  p_error_code text default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actual_sha256 text;
  v_current_status text;
  v_transitioned boolean := false;
begin
  if p_document_id is null
     or p_sha256 is null
     or p_sha256 <> pg_catalog.lower(pg_catalog.btrim(p_sha256))
     or p_sha256 !~ '^[0-9a-f]{64}$'
     or p_status not in ('ready', 'failed') then
    raise exception using
      errcode = '22023',
      message = 'Vault processing completion input is invalid';
  end if;

  if (p_status = 'ready' and p_error_code is not null)
     or (p_status = 'failed' and (
       p_error_code is null
       or p_error_code <> pg_catalog.lower(pg_catalog.btrim(p_error_code))
       or pg_catalog.char_length(p_error_code) not between 1 and 128
       or p_error_code !~ '^[a-z0-9][a-z0-9._:-]*$'
     )) then
    raise exception using
      errcode = '22023',
      message = 'Vault processing completion error code is invalid';
  end if;

  select document.sha256, document.status
    into v_actual_sha256, v_current_status
    from public.vault_documents as document
   where document.id = p_document_id
   for update;

  if not found then
    raise exception using
      errcode = '22023',
      message = 'Vault document is not available';
  end if;

  if v_actual_sha256 is distinct from p_sha256 then
    raise exception using
      errcode = '22023',
      message = 'Vault processing completion does not match the document';
  end if;

  if v_current_status = p_status then
    return false;
  end if;

  if v_current_status <> 'processing' then
    raise exception using
      errcode = '22023',
      message = 'Vault document cannot complete from its current state';
  end if;

  update public.vault_documents as document
     set status = p_status,
         error_code = p_error_code,
         error_message = null
   where document.id = p_document_id;

  v_transitioned := true;
  return v_transitioned;
end;
$function$;

-- The webhook handler has already verified the raw-body signature before it
-- calls this function.  PostgreSQL receives only the canonical digest and
-- bounded routing metadata, then serializes delivery state by opaque event ID.
create or replace function private.claim_alterity_webhook(
  p_event_id text,
  p_body_sha256 text,
  p_signed_at timestamptz,
  p_event_type text
)
returns table (
  claim_outcome text,
  status text,
  attempt_count integer,
  first_received_at timestamptz,
  processed_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_existing_body_sha256 text;
  v_existing_event_type text;
  v_status text;
  v_attempt_count integer;
  v_first_received_at timestamptz;
  v_processed_at timestamptz;
begin
  if p_event_id is null
     or p_event_id <> pg_catalog.btrim(p_event_id)
     or pg_catalog.char_length(p_event_id) not between 1 and 200
     or p_event_id !~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$'
     or p_body_sha256 is null
     or p_body_sha256 <> pg_catalog.lower(pg_catalog.btrim(p_body_sha256))
     or p_body_sha256 !~ '^[0-9a-f]{64}$'
     or p_event_type is null
     or p_event_type <> pg_catalog.lower(pg_catalog.btrim(p_event_type))
     or pg_catalog.char_length(p_event_type) not between 1 and 80
     or p_event_type !~ '^[a-z][a-z0-9._-]*$'
     or p_signed_at is null
     or p_signed_at < v_now - interval '15 minutes'
     or p_signed_at > v_now + interval '5 minutes' then
    raise exception using
      errcode = '22023',
      message = 'Alterity webhook claim input is invalid';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('swara-alterity-webhook:' || p_event_id, 8072026::bigint)
  );

  select
    receipt.body_sha256,
    receipt.event_type,
    receipt.status,
    receipt.attempt_count,
    receipt.first_received_at,
    receipt.processed_at
  into
    v_existing_body_sha256,
    v_existing_event_type,
    v_status,
    v_attempt_count,
    v_first_received_at,
    v_processed_at
  from private.alterity_webhook_receipts as receipt
  where receipt.event_id = p_event_id
  for update;

  if found then
    if v_existing_body_sha256 is distinct from p_body_sha256
       or v_existing_event_type is distinct from p_event_type then
      return query
      select 'hash_conflict', v_status, v_attempt_count, v_first_received_at, v_processed_at;
      return;
    end if;

    if v_attempt_count >= 1000 then
      raise exception using
        errcode = '22023',
        message = 'Alterity webhook replay limit has been reached';
    end if;

    update private.alterity_webhook_receipts as receipt
       set attempt_count = receipt.attempt_count + 1,
           last_received_at = v_now
     where receipt.event_id = p_event_id
    returning receipt.status, receipt.attempt_count, receipt.first_received_at, receipt.processed_at
      into v_status, v_attempt_count, v_first_received_at, v_processed_at;

    return query
    select 'same_hash_replay', v_status, v_attempt_count, v_first_received_at, v_processed_at;
    return;
  end if;

  insert into private.alterity_webhook_receipts as receipt (
    event_id,
    body_sha256,
    signed_at,
    event_type,
    status,
    attempt_count,
    first_received_at,
    last_received_at,
    claimed_at
  )
  values (
    p_event_id,
    p_body_sha256,
    p_signed_at,
    p_event_type,
    'claimed',
    1,
    v_now,
    v_now,
    v_now
  )
  returning receipt.status, receipt.attempt_count, receipt.first_received_at, receipt.processed_at
    into v_status, v_attempt_count, v_first_received_at, v_processed_at;

  return query
  select 'first_delivery', v_status, v_attempt_count, v_first_received_at, v_processed_at;
end;
$function$;

create or replace function private.finalize_alterity_webhook(
  p_event_id text,
  p_body_sha256 text,
  p_status text,
  p_safe_error_code text default null
)
returns table (
  status text,
  finalized boolean,
  processed_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_existing_body_sha256 text;
  v_current_status text;
  v_current_error_code text;
  v_processed_at timestamptz;
begin
  if p_event_id is null
     or p_event_id <> pg_catalog.btrim(p_event_id)
     or pg_catalog.char_length(p_event_id) not between 1 and 200
     or p_event_id !~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$'
     or p_body_sha256 is null
     or p_body_sha256 <> pg_catalog.lower(pg_catalog.btrim(p_body_sha256))
     or p_body_sha256 !~ '^[0-9a-f]{64}$'
     or p_status not in ('processed', 'failed') then
    raise exception using
      errcode = '22023',
      message = 'Alterity webhook finalization input is invalid';
  end if;

  if (p_status = 'processed' and p_safe_error_code is not null)
     or (p_status = 'failed' and (
       p_safe_error_code is null
       or p_safe_error_code <> pg_catalog.lower(pg_catalog.btrim(p_safe_error_code))
       or pg_catalog.char_length(p_safe_error_code) not between 1 and 64
       or p_safe_error_code !~ '^[a-z0-9][a-z0-9._-]*$'
     )) then
    raise exception using
      errcode = '22023',
      message = 'Alterity webhook finalization error code is invalid';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('swara-alterity-webhook:' || p_event_id, 8072026::bigint)
  );

  select
    receipt.body_sha256,
    receipt.status,
    receipt.safe_error_code,
    receipt.processed_at
  into
    v_existing_body_sha256,
    v_current_status,
    v_current_error_code,
    v_processed_at
  from private.alterity_webhook_receipts as receipt
  where receipt.event_id = p_event_id
  for update;

  if not found then
    raise exception using
      errcode = '22023',
      message = 'Alterity webhook claim is not available';
  end if;

  if v_existing_body_sha256 is distinct from p_body_sha256 then
    raise exception using
      errcode = '22023',
      message = 'Alterity webhook finalization does not match the claimed body';
  end if;

  if v_current_status in ('processed', 'failed') then
    if v_current_status is distinct from p_status
       or v_current_error_code is distinct from p_safe_error_code then
      raise exception using
        errcode = '22023',
        message = 'Alterity webhook is already finalized with different result';
    end if;

    return query select v_current_status, false, v_processed_at;
    return;
  end if;

  update private.alterity_webhook_receipts as receipt
     set status = p_status,
         processed_at = pg_catalog.clock_timestamp(),
         safe_error_code = p_safe_error_code
   where receipt.event_id = p_event_id
  returning receipt.status, receipt.processed_at
    into v_current_status, v_processed_at;

  return query select v_current_status, true, v_processed_at;
end;
$function$;

-- Pin ownership and function ACLs explicitly.  The migration owner is
-- postgres in the Supabase migration runner; no browser, service_role, or
-- alternate runtime role may inherit execution through PUBLIC defaults.
alter function private.register_device(uuid, text, text, text, text, text) owner to postgres;
alter function private.revoke_device(uuid, uuid, text) owner to postgres;
alter function private.create_vault_upload_intent(uuid, text, text, bigint, text, text, text) owner to postgres;
alter function private.finalize_vault_upload(uuid, uuid, text, text) owner to postgres;
alter function private.soft_delete_vault_document(uuid, uuid, text) owner to postgres;
alter function private.complete_vault_document_processing(uuid, text, text, text) owner to postgres;
alter function private.claim_alterity_webhook(text, text, timestamptz, text) owner to postgres;
alter function private.finalize_alterity_webhook(text, text, text, text) owner to postgres;

revoke all privileges on function private.register_device(uuid, text, text, text, text, text)
  from public, anon, authenticated, service_role, swara_worker_runtime;
revoke all privileges on function private.revoke_device(uuid, uuid, text)
  from public, anon, authenticated, service_role, swara_worker_runtime;
revoke all privileges on function private.create_vault_upload_intent(uuid, text, text, bigint, text, text, text)
  from public, anon, authenticated, service_role, swara_worker_runtime;
revoke all privileges on function private.finalize_vault_upload(uuid, uuid, text, text)
  from public, anon, authenticated, service_role, swara_worker_runtime;
revoke all privileges on function private.soft_delete_vault_document(uuid, uuid, text)
  from public, anon, authenticated, service_role, swara_worker_runtime;
revoke all privileges on function private.complete_vault_document_processing(uuid, text, text, text)
  from public, anon, authenticated, service_role, swara_api_runtime;
revoke all privileges on function private.claim_alterity_webhook(text, text, timestamptz, text)
  from public, anon, authenticated, service_role, swara_worker_runtime;
revoke all privileges on function private.finalize_alterity_webhook(text, text, text, text)
  from public, anon, authenticated, service_role, swara_worker_runtime;

grant usage on schema private to swara_api_runtime, swara_worker_runtime;
grant execute on function private.register_device(uuid, text, text, text, text, text)
  to swara_api_runtime;
grant execute on function private.revoke_device(uuid, uuid, text)
  to swara_api_runtime;
grant execute on function private.create_vault_upload_intent(uuid, text, text, bigint, text, text, text)
  to swara_api_runtime;
grant execute on function private.finalize_vault_upload(uuid, uuid, text, text)
  to swara_api_runtime;
grant execute on function private.soft_delete_vault_document(uuid, uuid, text)
  to swara_api_runtime;
grant execute on function private.claim_alterity_webhook(text, text, timestamptz, text)
  to swara_api_runtime;
grant execute on function private.finalize_alterity_webhook(text, text, text, text)
  to swara_api_runtime;
grant execute on function private.complete_vault_document_processing(uuid, text, text, text)
  to swara_worker_runtime;

-- Replace the original broad per-bucket browser policies.  Grants on
-- storage.objects are relation-wide in PostgreSQL, so RLS policies provide
-- the necessary bucket-level split.  Supabase Storage's administrator-owned
-- relation grant is intentionally not rewritten here; the absence of every
-- authenticated DELETE policy is the durable browser DELETE denial. Trusted
-- Storage API credentials continue to perform deferred deletion outside SQL.
revoke all privileges on table storage.objects from anon;
revoke delete on table storage.objects from authenticated;
grant usage on schema storage to authenticated;
grant select, insert, update on table storage.objects to authenticated;

drop policy if exists vault_storage_select_own on storage.objects;
drop policy if exists vault_storage_insert_own on storage.objects;
drop policy if exists vault_storage_update_own on storage.objects;
drop policy if exists vault_storage_delete_own on storage.objects;
drop policy if exists task_artifacts_storage_select_own on storage.objects;
drop policy if exists task_artifacts_storage_insert_own on storage.objects;
drop policy if exists task_artifacts_storage_update_own on storage.objects;
drop policy if exists task_artifacts_storage_delete_own on storage.objects;
drop policy if exists account_exports_select_own on storage.objects;
drop policy if exists account_exports_delete_own on storage.objects;

create policy swara_vault_originals_select_own
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'vault-originals'
    and owner_id = (select auth.uid()::text)
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] = (select auth.uid()::text)
    and (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and storage.filename(name) <> ''
  );

create policy swara_vault_originals_insert_own
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'vault-originals'
    and owner_id = (select auth.uid()::text)
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] = (select auth.uid()::text)
    and (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and storage.filename(name) <> ''
  );

create policy swara_vault_originals_update_own
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'vault-originals'
    and owner_id = (select auth.uid()::text)
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] = (select auth.uid()::text)
    and (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and storage.filename(name) <> ''
  )
  with check (
    bucket_id = 'vault-originals'
    and owner_id = (select auth.uid()::text)
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] = (select auth.uid()::text)
    and (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and storage.filename(name) <> ''
  );

create policy swara_vault_derived_select_own
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'vault-derived'
    and owner_id = (select auth.uid()::text)
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] = (select auth.uid()::text)
    and (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and storage.filename(name) <> ''
  );

create policy swara_task_artifacts_select_own
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

create policy swara_account_exports_select_own
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'account-exports'
    and owner_id = (select auth.uid()::text)
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] = (select auth.uid()::text)
    and (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and storage.filename(name) <> ''
  );

-- Repeat the service-role closure at the final migration boundary.  M022 does
-- not introduce any service_role path to private, audit, or PGMQ state.
revoke all privileges on schema private, audit, pgmq from service_role;
revoke all privileges on all tables in schema private from service_role;
revoke all privileges on all sequences in schema private from service_role;
revoke execute on all functions in schema private from service_role;
revoke all privileges on all tables in schema audit from service_role;
revoke all privileges on all sequences in schema audit from service_role;
revoke execute on all functions in schema audit from service_role;
revoke all privileges on all tables in schema pgmq from service_role;
revoke all privileges on all sequences in schema pgmq from service_role;
revoke execute on all functions in schema pgmq from service_role;

comment on table private.alterity_webhook_receipts is
  'Private replay ledger for verified Alterity webhooks. It stores opaque event IDs, SHA-256 body fingerprints, bounded state, and safe error codes only.';
comment on table private.device_mutation_requests is
  'Private idempotency ledger for Edge-derived device registrations and revocations. It stores installation hashes, never raw installation identifiers.';
comment on table private.vault_document_requests is
  'Private idempotency ledger for Vault metadata transitions. It stores request digests and document identifiers, never Storage object content.';
comment on function private.register_device(uuid, text, text, text, text, text) is
  'API-runtime-only device registration. p_user_id must be derived from verified Edge claims; p_installation_hash is a canonical SHA-256 hash.';
comment on function private.revoke_device(uuid, uuid, text) is
  'API-runtime-only, owner-checked, idempotent device revocation. p_user_id must be derived from verified Edge claims.';
comment on function private.create_vault_upload_intent(uuid, text, text, bigint, text, text, text) is
  'API-runtime-only Vault upload intent. It constructs an exact vault-originals path and never performs a Storage object operation.';
comment on function private.finalize_vault_upload(uuid, uuid, text, text) is
  'API-runtime-only Vault upload finalization. Edge verifies Storage before this function advances metadata to processing.';
comment on function private.soft_delete_vault_document(uuid, uuid, text) is
  'API-runtime-only Vault metadata soft delete. Storage deletion is delegated to trusted Storage API work, never SQL.';
comment on function private.complete_vault_document_processing(uuid, text, text, text) is
  'Worker-runtime-only terminal Vault processing transition with safe error codes only.';
comment on function private.claim_alterity_webhook(text, text, timestamptz, text) is
  'API-runtime-only replay claim for an already signature-verified Alterity webhook; raw body and vendor principals are never persisted.';
comment on function private.finalize_alterity_webhook(text, text, text, text) is
  'API-runtime-only Alterity webhook finalization with body-digest matching and a bounded safe error code.';

commit;
