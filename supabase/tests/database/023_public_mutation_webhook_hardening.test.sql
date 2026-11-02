begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(83);

-- pgTAP assertions are invoked after SET ROLE below. These are transient test
-- harness grants only: the enclosing transaction rolls them back, so they do
-- not broaden the production runtime roles or browser roles.
grant usage on schema extensions to anon, authenticated, swara_api_runtime, swara_worker_runtime;
grant execute on all functions in schema extensions
  to anon, authenticated, swara_api_runtime, swara_worker_runtime;

-- Structural and ACL proof: private state stays private, while direct browser
-- access to the exposed tables is reduced to the intended read/append verbs.
select has_table(
  'private',
  'alterity_webhook_receipts',
  'Alterity webhook replay ledger exists'
);
select has_table(
  'private',
  'device_mutation_requests',
  'device mutation idempotency ledger exists'
);
select has_table(
  'private',
  'vault_document_requests',
  'Vault mutation idempotency ledger exists'
);
select ok(
  not exists (
    select 1
      from information_schema.columns
     where table_schema = 'private'
       and table_name = 'alterity_webhook_receipts'
       and column_name in ('raw_body', 'body', 'payload', 'tenant_id', 'client_id', 'alterity_user_id')
  ),
  'webhook ledger has no raw body, payload, or Alterity principal columns'
);
select ok(
  (
    select count(*)::integer
      from pg_catalog.pg_class as relation
     where relation.oid in (
       'private.alterity_webhook_receipts'::regclass,
       'private.device_mutation_requests'::regclass,
       'private.vault_document_requests'::regclass
     )
       and relation.relrowsecurity
  ) = 3,
  'all new private ledgers have RLS enabled'
);
select ok(
  (
    select count(*)::integer
      from pg_catalog.pg_proc as routine
     where routine.oid = any (
       array[
         'private.register_device(uuid,text,text,text,text,text)'::regprocedure,
         'private.revoke_device(uuid,uuid,text)'::regprocedure,
         'private.create_vault_upload_intent(uuid,text,text,bigint,text,text,text)'::regprocedure,
         'private.finalize_vault_upload(uuid,uuid,text,text)'::regprocedure,
         'private.soft_delete_vault_document(uuid,uuid,text)'::regprocedure,
         'private.complete_vault_document_processing(uuid,text,text,text)'::regprocedure,
         'private.claim_alterity_webhook(text,text,timestamp with time zone,text)'::regprocedure,
         'private.finalize_alterity_webhook(text,text,text,text)'::regprocedure
       ]
     )
       and routine.prosecdef
  ) = 8,
  'all M022 mutation functions are security definer'
);
select ok(
  (
    select count(*)::integer
      from pg_catalog.pg_proc as routine
     where routine.oid = any (
       array[
         'private.register_device(uuid,text,text,text,text,text)'::regprocedure,
         'private.revoke_device(uuid,uuid,text)'::regprocedure,
         'private.create_vault_upload_intent(uuid,text,text,bigint,text,text,text)'::regprocedure,
         'private.finalize_vault_upload(uuid,uuid,text,text)'::regprocedure,
         'private.soft_delete_vault_document(uuid,uuid,text)'::regprocedure,
         'private.complete_vault_document_processing(uuid,text,text,text)'::regprocedure,
         'private.claim_alterity_webhook(text,text,timestamp with time zone,text)'::regprocedure,
         'private.finalize_alterity_webhook(text,text,text,text)'::regprocedure
       ]
     )
       and 'search_path=""' = any(routine.proconfig)
  ) = 8,
  'all M022 mutation functions pin an empty search path'
);
select ok(
  (
    select count(*)::integer
      from pg_catalog.pg_proc as routine
     where routine.oid = any (
       array[
         'private.register_device(uuid,text,text,text,text,text)'::regprocedure,
         'private.revoke_device(uuid,uuid,text)'::regprocedure,
         'private.create_vault_upload_intent(uuid,text,text,bigint,text,text,text)'::regprocedure,
         'private.finalize_vault_upload(uuid,uuid,text,text)'::regprocedure,
         'private.soft_delete_vault_document(uuid,uuid,text)'::regprocedure,
         'private.complete_vault_document_processing(uuid,text,text,text)'::regprocedure,
         'private.claim_alterity_webhook(text,text,timestamp with time zone,text)'::regprocedure,
         'private.finalize_alterity_webhook(text,text,text,text)'::regprocedure
       ]
     )
       and pg_catalog.pg_get_userbyid(routine.proowner) = 'postgres'
  ) = 8,
  'all M022 mutation functions are owned by postgres'
);
select ok(
  (
    select count(*)::integer
      from (values
        ('private.register_device(uuid,text,text,text,text,text)'::text),
        ('private.revoke_device(uuid,uuid,text)'::text),
        ('private.create_vault_upload_intent(uuid,text,text,bigint,text,text,text)'::text),
        ('private.finalize_vault_upload(uuid,uuid,text,text)'::text),
        ('private.soft_delete_vault_document(uuid,uuid,text)'::text),
        ('private.claim_alterity_webhook(text,text,timestamp with time zone,text)'::text),
        ('private.finalize_alterity_webhook(text,text,text,text)'::text)
      ) as api_function(signature)
     where has_function_privilege('swara_api_runtime', api_function.signature, 'EXECUTE')
  ) = 7,
  'API runtime receives exactly the reviewed device, Vault, and webhook mutations'
);
select ok(
  has_function_privilege(
    'swara_worker_runtime',
    'private.complete_vault_document_processing(uuid,text,text,text)',
    'EXECUTE'
  ),
  'worker runtime can perform the bounded terminal Vault processing transition'
);
select ok(
  (
    select count(*)::integer
      from pg_catalog.pg_proc as routine
     where routine.oid = any (
       array[
         'private.register_device(uuid,text,text,text,text,text)'::regprocedure,
         'private.revoke_device(uuid,uuid,text)'::regprocedure,
         'private.create_vault_upload_intent(uuid,text,text,bigint,text,text,text)'::regprocedure,
         'private.finalize_vault_upload(uuid,uuid,text,text)'::regprocedure,
         'private.soft_delete_vault_document(uuid,uuid,text)'::regprocedure,
         'private.complete_vault_document_processing(uuid,text,text,text)'::regprocedure,
         'private.claim_alterity_webhook(text,text,timestamp with time zone,text)'::regprocedure,
         'private.finalize_alterity_webhook(text,text,text,text)'::regprocedure
       ]
     )
       and (
         has_function_privilege('anon', routine.oid, 'EXECUTE')
         or has_function_privilege('authenticated', routine.oid, 'EXECUTE')
         or has_function_privilege('service_role', routine.oid, 'EXECUTE')
       )
  ) = 0,
  'anon, authenticated, and service_role cannot invoke any M022 wrapper'
);
select ok(
  not has_schema_privilege('service_role', 'private', 'USAGE')
  and not has_schema_privilege('service_role', 'audit', 'USAGE')
  and not has_schema_privilege('service_role', 'pgmq', 'USAGE'),
  'service_role remains closed from private, audit, and PGMQ schemas'
);
select ok(
  not has_table_privilege('service_role', 'public.devices', 'SELECT')
  and not has_table_privilege('service_role', 'public.vault_documents', 'UPDATE')
  and not has_table_privilege('service_role', 'public.swara_context_items', 'INSERT')
  and not has_table_privilege('service_role', 'public.workflows', 'DELETE')
  and not has_table_privilege('service_role', 'public.workflow_versions', 'INSERT'),
  'service_role has no direct public-table mutation or read path for M022 data'
);
select ok(
  has_table_privilege('authenticated', 'public.devices', 'SELECT')
  and not has_table_privilege('authenticated', 'public.devices', 'INSERT')
  and not has_table_privilege('authenticated', 'public.devices', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.devices', 'DELETE'),
  'authenticated devices access is SELECT only'
);
select ok(
  has_table_privilege('authenticated', 'public.vault_documents', 'SELECT')
  and not has_table_privilege('authenticated', 'public.vault_documents', 'INSERT')
  and not has_table_privilege('authenticated', 'public.vault_documents', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.vault_documents', 'DELETE'),
  'authenticated Vault document access is SELECT only'
);
select ok(
  has_table_privilege('authenticated', 'public.swara_context_items', 'SELECT')
  and has_table_privilege('authenticated', 'public.swara_context_items', 'INSERT')
  and not has_table_privilege('authenticated', 'public.swara_context_items', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.swara_context_items', 'DELETE'),
  'authenticated context access is owner-read plus append-only insert'
);
select ok(
  has_table_privilege('authenticated', 'public.workflows', 'SELECT')
  and not has_table_privilege('authenticated', 'public.workflows', 'INSERT')
  and not has_table_privilege('authenticated', 'public.workflows', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.workflows', 'DELETE'),
  'authenticated workflows access is SELECT only'
);
select ok(
  has_table_privilege('authenticated', 'public.workflow_versions', 'SELECT')
  and not has_table_privilege('authenticated', 'public.workflow_versions', 'INSERT')
  and not has_table_privilege('authenticated', 'public.workflow_versions', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.workflow_versions', 'DELETE'),
  'authenticated workflow version access is SELECT only'
);
select ok(
  (select pg_catalog.pg_get_constraintdef(constraint_row.oid)
     from pg_catalog.pg_constraint as constraint_row
    where constraint_row.conrelid = 'public.vault_documents'::regclass
      and constraint_row.conname = 'vault_documents_storage_bucket_check')
    like '%vault-originals%'
  and (select pg_catalog.pg_get_constraintdef(constraint_row.oid)
         from pg_catalog.pg_constraint as constraint_row
        where constraint_row.conrelid = 'public.vault_documents'::regclass
          and constraint_row.conname = 'vault_documents_storage_bucket_check')
    like '%vault-derived%'
  and (select pg_catalog.pg_get_constraintdef(constraint_row.oid)
         from pg_catalog.pg_constraint as constraint_row
        where constraint_row.conrelid = 'public.vault_documents'::regclass
          and constraint_row.conname = 'vault_documents_storage_bucket_check')
    not like '%documents%',
  'Vault metadata constraint excludes the legacy bucket'
);
select ok(
  not exists (
    select 1
      from pg_catalog.pg_policies as policy
     where policy.schemaname = 'storage'
       and policy.tablename = 'objects'
       and policy.policyname like 'swara_%'
       and (coalesce(policy.qual, '') || coalesce(policy.with_check, '')) ~*
         $$bucket_id\\s*=\\s*'documents'$$
  ),
  'Swara Storage policies do not create a legacy bucket access path'
);
select ok(
  not exists (
    select 1
      from pg_catalog.pg_policies as policy
     where policy.schemaname = 'storage'
       and policy.tablename = 'objects'
       and policy.cmd = 'DELETE'
       and 'authenticated' = any(policy.roles)
       and (
         coalesce(policy.qual, '') ilike '%vault-originals%'
         or coalesce(policy.qual, '') ilike '%vault-derived%'
         or coalesce(policy.qual, '') ilike '%task-artifacts%'
         or coalesce(policy.qual, '') ilike '%account-exports%'
       )
  ),
  'authenticated clients have no Swara Storage DELETE policy'
);

insert into auth.users (id)
values
  ('10000000-0000-4000-8000-000000000001'),
  ('20000000-0000-4000-8000-000000000002');

-- Device registration/revocation is idempotent and owner-bound at the
-- runtime-only function boundary.
set local role swara_api_runtime;
select lives_ok(
  $$select * from private.register_device(
      '10000000-0000-4000-8000-000000000001',
      repeat('a', 64),
      'chrome',
      '5.6.0',
      null,
      'device-register-0001'
    )$$,
  'API runtime can register a device from a canonical installation hash'
);
reset role;
select is(
  (select count(*)::integer from public.devices
    where user_id = '10000000-0000-4000-8000-000000000001'),
  1,
  'registration creates one device'
);
select is(
  (select installation_hash from public.devices
    where user_id = '10000000-0000-4000-8000-000000000001'),
  repeat('a', 64),
  'only the installation hash is persisted'
);
set local role swara_api_runtime;
select lives_ok(
  $$select * from private.register_device(
      '10000000-0000-4000-8000-000000000001',
      repeat('a', 64),
      'chrome',
      '5.6.0',
      null,
      'device-register-0001'
    )$$,
  'same registration idempotency key is a safe retry'
);
reset role;
select is(
  (select count(*)::integer from private.device_mutation_requests
    where user_id = '10000000-0000-4000-8000-000000000001'
      and operation = 'register'),
  1,
  'registration retry keeps one durable ledger result'
);
set local role swara_api_runtime;
select throws_ok(
  $$select * from private.register_device(
      '10000000-0000-4000-8000-000000000001',
      repeat('a', 64),
      'chrome',
      '5.6.1',
      null,
      'device-register-0001'
    )$$,
  '22023',
  null,
  'changed input cannot reuse a device registration idempotency key'
);
select throws_ok(
  $$select * from private.register_device(
      '10000000-0000-4000-8000-000000000001',
      'not-a-hash',
      'chrome',
      '5.6.0',
      null,
      'device-register-0002'
    )$$,
  '22023',
  null,
  'raw or non-canonical installation identifiers are rejected'
);
select lives_ok(
  $$select * from private.revoke_device(
      '10000000-0000-4000-8000-000000000001',
      (select id from public.devices
        where user_id = '10000000-0000-4000-8000-000000000001'),
      'device-revoke-0001'
    )$$,
  'API runtime can owner-revoke a device'
);
reset role;
select ok(
  (select revoked_at is not null from public.devices
    where user_id = '10000000-0000-4000-8000-000000000001'),
  'device revocation records a durable revoked timestamp'
);
set local role swara_api_runtime;
select lives_ok(
  $$select * from private.revoke_device(
      '10000000-0000-4000-8000-000000000001',
      (select id from public.devices
        where user_id = '10000000-0000-4000-8000-000000000001'),
      'device-revoke-0001'
    )$$,
  'same device revocation idempotency key is a safe retry'
);
select lives_ok(
  $$select * from private.register_device(
      '20000000-0000-4000-8000-000000000002',
      repeat('b', 64),
      'chrome',
      '5.6.0',
      null,
      'device-register-0003'
    )$$,
  'API runtime can register an independently owned device'
);
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select results_eq(
  $$select user_id from public.devices order by user_id$$,
  $$values ('10000000-0000-4000-8000-000000000001'::uuid)$$,
  'device RLS hides a second user device'
);
select throws_ok(
  $$insert into public.devices (user_id, installation_hash, browser, extension_version)
    values ('10000000-0000-4000-8000-000000000001', repeat('c', 64), 'chrome', '5.6.0')$$,
  '42501',
  null,
  'authenticated users cannot insert device rows directly'
);
select throws_ok(
  $$update public.devices set revoked_at = null
    where user_id = '10000000-0000-4000-8000-000000000001'$$,
  '42501',
  null,
  'authenticated users cannot update device rows directly'
);
reset role;
set local role anon;
select set_config('request.jwt.claim.role', 'anon', true);
select throws_ok(
  $$select count(*) from public.devices$$,
  '42501',
  null,
  'anonymous clients cannot read devices'
);
reset role;

-- Vault intent/finalize/delete functions construct and validate the exact
-- owner path without ever reading or writing storage.objects from SQL.
set local role swara_api_runtime;
select lives_ok(
  $$select * from private.create_vault_upload_intent(
      '10000000-0000-4000-8000-000000000001',
      'notes.txt',
      'text/plain',
      42,
      repeat('c', 64),
      'local',
      'vault-intent-0001'
    )$$,
  'API runtime can create a Vault upload intent'
);
reset role;
select is(
  (select storage_bucket from public.vault_documents
    where user_id = '10000000-0000-4000-8000-000000000001'),
  'vault-originals',
  'upload intent always chooses the private originals bucket'
);
select is(
  (select storage_path from public.vault_documents
    where user_id = '10000000-0000-4000-8000-000000000001'),
  '10000000-0000-4000-8000-000000000001/' ||
    (select id::text from public.vault_documents
      where user_id = '10000000-0000-4000-8000-000000000001') ||
    '/notes.txt',
  'upload intent constructs the exact owner/document/filename path'
);
select is(
  (select status from public.vault_documents
    where user_id = '10000000-0000-4000-8000-000000000001'),
  'pending',
  'new Vault intent begins pending verification'
);
select set_config(
  'm022.vault_document_id',
  (select id::text from public.vault_documents
    where user_id = '10000000-0000-4000-8000-000000000001'),
  true
);
set local role swara_api_runtime;
select lives_ok(
  $$select * from private.create_vault_upload_intent(
      '10000000-0000-4000-8000-000000000001',
      'notes.txt',
      'text/plain',
      42,
      repeat('c', 64),
      'local',
      'vault-intent-0001'
    )$$,
  'same Vault upload intent key is a safe retry'
);
reset role;
select is(
  (select count(*)::integer from private.vault_document_requests
    where user_id = '10000000-0000-4000-8000-000000000001'
      and operation = 'create_upload_intent'),
  1,
  'Vault intent retry keeps one durable ledger result'
);
set local role swara_api_runtime;
select throws_ok(
  $$select * from private.create_vault_upload_intent(
      '10000000-0000-4000-8000-000000000001',
      'changed.txt',
      'text/plain',
      42,
      repeat('c', 64),
      'local',
      'vault-intent-0001'
    )$$,
  '22023',
  null,
  'changed Vault metadata cannot reuse an idempotency key'
);
select throws_ok(
  $$select * from private.create_vault_upload_intent(
      '10000000-0000-4000-8000-000000000001',
      '../escape.txt',
      'text/plain',
      42,
      repeat('c', 64),
      'local',
      'vault-intent-0002'
    )$$,
  '22023',
  null,
  'Vault upload intent rejects path traversal filenames'
);
reset role;
insert into storage.objects (id, bucket_id, name, owner_id, metadata)
values (
  '19000000-0000-4000-8000-000000000019',
  'vault-originals',
  '10000000-0000-4000-8000-000000000001/' ||
    current_setting('m022.vault_document_id') || '/notes.txt',
  '10000000-0000-4000-8000-000000000001',
  '{"size":42,"mimetype":"text/plain"}'::jsonb
);
set local role swara_api_runtime;
select lives_ok(
  $$select * from private.finalize_vault_upload(
      '10000000-0000-4000-8000-000000000001',
      current_setting('m022.vault_document_id')::uuid,
      repeat('c', 64),
      'vault-finalize-0001'
    )$$,
  'API runtime can finalize a matching pending Vault document'
);
reset role;
select is(
  (select status from public.vault_documents
    where user_id = '10000000-0000-4000-8000-000000000001'),
  'processing',
  'matching finalization advances pending document to processing'
);
set local role swara_api_runtime;
select throws_ok(
  $$select * from private.finalize_vault_upload(
      '10000000-0000-4000-8000-000000000001',
      current_setting('m022.vault_document_id')::uuid,
      repeat('d', 64),
      'vault-finalize-0002'
    )$$,
  '22023',
  null,
  'Vault finalization rejects a non-matching SHA-256'
);
select lives_ok(
  $$select * from private.soft_delete_vault_document(
      '10000000-0000-4000-8000-000000000001',
      current_setting('m022.vault_document_id')::uuid,
      'vault-delete-0001'
    )$$,
  'API runtime can soft-delete an owned Vault document'
);
reset role;
select ok(
  (select status = 'deleted' and deleted_at is not null
     from public.vault_documents
    where user_id = '10000000-0000-4000-8000-000000000001'),
  'Vault soft-delete records the terminal metadata state without a Storage operation'
);
set local role swara_api_runtime;
select lives_ok(
  $$select * from private.soft_delete_vault_document(
      '10000000-0000-4000-8000-000000000001',
      current_setting('m022.vault_document_id')::uuid,
      'vault-delete-0001'
    )$$,
  'same Vault soft-delete key is a safe retry'
);
select lives_ok(
  $$select * from private.create_vault_upload_intent(
      '20000000-0000-4000-8000-000000000002',
      'other.txt',
      'text/plain',
      24,
      repeat('e', 64),
      'local',
      'vault-intent-0003'
    )$$,
  'API runtime can create a second user Vault intent'
);
reset role;
set local role swara_api_runtime;
select set_config(
  'm022.tracked_vault_document_id',
  (
    select document_id::text
      from private.create_vault_upload_intent(
        '10000000-0000-4000-8000-000000000001',
        'upload.txt',
        'text/plain',
        9,
        repeat('f', 64),
        'local',
        'vault-intent-0004'
      )
  ),
  true
);
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select results_eq(
  $$select distinct user_id from public.vault_documents order by user_id$$,
  $$values ('10000000-0000-4000-8000-000000000001'::uuid)$$,
  'Vault RLS hides another user metadata'
);
select throws_ok(
  $$insert into public.vault_documents
      (user_id, filename, mime_type, size_bytes, sha256, storage_path, extraction_method)
    values
      ('10000000-0000-4000-8000-000000000001', 'direct.txt', 'text/plain', 1,
       repeat('f', 64), 'direct.txt', 'local')$$,
  '42501',
  null,
  'authenticated users cannot insert Vault metadata directly'
);
select throws_ok(
  $$update public.vault_documents set filename = 'rewritten.txt'
    where user_id = '10000000-0000-4000-8000-000000000001'$$,
  '42501',
  null,
  'authenticated users cannot update Vault metadata directly'
);
select throws_ok(
  $$delete from public.vault_documents
    where user_id = '10000000-0000-4000-8000-000000000001'$$,
  '42501',
  null,
  'authenticated users cannot delete Vault metadata directly'
);
reset role;

-- Context corrections retain their append-only browser-facing contract, and
-- cloud workflow imports can no longer bypass M019 through the Data API.
set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select lives_ok(
  $$insert into public.swara_context_items (user_id, type, key, value, version)
    values ('10000000-0000-4000-8000-000000000001', 'fact', 'm022-context', 'append only', 1)$$,
  'authenticated owner can append controlled context metadata'
);
select throws_ok(
  $$update public.swara_context_items set value = 'rewrite'
    where user_id = '10000000-0000-4000-8000-000000000001'
      and key = 'm022-context'$$,
  '42501',
  null,
  'authenticated users cannot update context rows directly'
);
select throws_ok(
  $$delete from public.swara_context_items
    where user_id = '10000000-0000-4000-8000-000000000001'
      and key = 'm022-context'$$,
  '42501',
  null,
  'authenticated users cannot delete context rows directly'
);
select throws_ok(
  $$insert into public.workflows (user_id, name)
    values ('10000000-0000-4000-8000-000000000001', 'direct workflow')$$,
  '42501',
  null,
  'authenticated users cannot import workflows through direct table insertion'
);
select throws_ok(
  $$insert into public.workflow_versions (workflow_id, user_id, schema_version, definition, content_hash)
    values (pg_catalog.gen_random_uuid(), '10000000-0000-4000-8000-000000000001', 1, '{"steps":[]}'::jsonb, repeat('a', 64))$$,
  '42501',
  null,
  'authenticated users cannot append workflow versions directly'
);
reset role;

-- Storage policy boundary: only vault-originals supports owner browser
-- upload/upsert. Derived files, task artifacts, and exports are read-only in
-- the browser.  These fixtures never reference or touch a legacy bucket.
insert into storage.objects (id, bucket_id, name, owner_id, metadata)
values
  ('30000000-0000-4000-8000-000000000001', 'vault-originals',
   '10000000-0000-4000-8000-000000000001/30000000-0000-4000-8000-000000000001/owned.txt',
   '10000000-0000-4000-8000-000000000001', '{}'::jsonb),
  ('30000000-0000-4000-8000-000000000002', 'vault-originals',
   '20000000-0000-4000-8000-000000000002/30000000-0000-4000-8000-000000000002/other.txt',
   '20000000-0000-4000-8000-000000000002', '{}'::jsonb),
  ('30000000-0000-4000-8000-000000000003', 'vault-derived',
   '10000000-0000-4000-8000-000000000001/30000000-0000-4000-8000-000000000003/derived.txt',
   '10000000-0000-4000-8000-000000000001', '{}'::jsonb),
  ('30000000-0000-4000-8000-000000000004', 'task-artifacts',
   '10000000-0000-4000-8000-000000000001/30000000-0000-4000-8000-000000000004/task.png',
   '10000000-0000-4000-8000-000000000001', '{}'::jsonb),
  ('30000000-0000-4000-8000-000000000005', 'account-exports',
   '10000000-0000-4000-8000-000000000001/30000000-0000-4000-8000-000000000005/export.zip',
   '10000000-0000-4000-8000-000000000001', '{}'::jsonb);

set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select lives_ok(
  $$insert into storage.objects (id, bucket_id, name, owner_id, metadata)
    values (
      '30000000-0000-4000-8000-000000000006', 'vault-originals',
      '10000000-0000-4000-8000-000000000001/' ||
        current_setting('m022.tracked_vault_document_id') || '/upload.txt',
      '10000000-0000-4000-8000-000000000001', '{}'::jsonb
    )$$,
  'authenticated owner can upload only to vault-originals'
);
select lives_ok(
  $$update storage.objects set metadata = '{"upsert":true}'::jsonb
    where id = '30000000-0000-4000-8000-000000000006'$$,
  'authenticated owner can update their original for Storage upsert'
);
select throws_ok(
  $$insert into storage.objects (id, bucket_id, name, owner_id, metadata)
    values (
      '30000000-0000-4000-8000-000000000007', 'vault-derived',
      '10000000-0000-4000-8000-000000000001/30000000-0000-4000-8000-000000000007/derived.txt',
      '10000000-0000-4000-8000-000000000001', '{}'::jsonb
    )$$,
  '42501',
  null,
  'authenticated owner cannot write vault-derived'
);
select throws_ok(
  $$insert into storage.objects (id, bucket_id, name, owner_id, metadata)
    values (
      '30000000-0000-4000-8000-000000000008', 'task-artifacts',
      '10000000-0000-4000-8000-000000000001/30000000-0000-4000-8000-000000000008/task.png',
      '10000000-0000-4000-8000-000000000001', '{}'::jsonb
    )$$,
  '42501',
  null,
  'authenticated owner cannot write task artifacts'
);
select throws_ok(
  $$insert into storage.objects (id, bucket_id, name, owner_id, metadata)
    values (
      '30000000-0000-4000-8000-000000000009', 'account-exports',
      '10000000-0000-4000-8000-000000000001/30000000-0000-4000-8000-000000000009/export.zip',
      '10000000-0000-4000-8000-000000000001', '{}'::jsonb
    )$$,
  '42501',
  null,
  'authenticated owner cannot write account exports'
);
select throws_ok(
  $$delete from storage.objects
    where id = '30000000-0000-4000-8000-000000000006'$$,
  '42501',
  null,
  'authenticated owner cannot delete a Vault original directly'
);
select results_eq(
  $$select id from storage.objects
    where bucket_id = 'vault-originals'
    order by id$$,
  $$values
      ('19000000-0000-4000-8000-000000000019'::uuid),
      ('30000000-0000-4000-8000-000000000001'::uuid),
      ('30000000-0000-4000-8000-000000000006'::uuid)$$,
  'Storage RLS exposes only the authenticated owner originals'
);
select results_eq(
  $$select id from storage.objects
    where bucket_id in ('vault-derived', 'task-artifacts', 'account-exports')
    order by id$$,
  $$values
      ('30000000-0000-4000-8000-000000000003'::uuid),
      ('30000000-0000-4000-8000-000000000004'::uuid),
      ('30000000-0000-4000-8000-000000000005'::uuid)$$,
  'derived, artifact, and export owner reads remain available'
);
reset role;

-- Webhook replay claim/finalization semantics use only opaque event IDs and a
-- canonical raw-body digest.  The actual raw body is never supplied to SQL.
set local role swara_api_runtime;
select is(
  (select claim_outcome from private.claim_alterity_webhook(
    'evt.m022.0001', repeat('1', 64), pg_catalog.clock_timestamp(), 'billing.invoice.paid'
  )),
  'first_delivery',
  'first verified delivery acquires the webhook claim'
);
select is(
  (select claim_outcome from private.claim_alterity_webhook(
    'evt.m022.0001', repeat('1', 64), pg_catalog.clock_timestamp(), 'billing.invoice.paid'
  )),
  'in_progress',
  'same-hash active replay is reported without reprocessing'
);
select is(
  (select attempt_count from private.claim_alterity_webhook(
    'evt.m022.0001', repeat('1', 64), pg_catalog.clock_timestamp(), 'billing.invoice.paid'
  )),
  3,
  'same-hash replay increments the bounded attempt count'
);
select is(
  (select claim_outcome from private.claim_alterity_webhook(
    'evt.m022.0001', repeat('2', 64), pg_catalog.clock_timestamp(), 'billing.invoice.paid'
  )),
  'hash_conflict',
  'same event ID with a different body digest is a conflict'
);
select is(
  (select attempt_count from private.claim_alterity_webhook(
    'evt.m022.0001', repeat('2', 64), pg_catalog.clock_timestamp(), 'billing.invoice.paid'
  )),
  3,
  'hash conflict does not increment the replay count'
);
select is(
  (select status || ':' || finalized::text from private.finalize_alterity_webhook(
    'evt.m022.0001', repeat('1', 64), 'processed', null
  )),
  'processed:true',
  'matching claimed webhook finalizes as processed exactly once'
);
select throws_ok(
  $$select * from private.finalize_alterity_webhook(
      'evt.m022.0001', repeat('1', 64), 'processed', null
    )$$,
  '55000', null,
  'terminal webhook finalization is rejected after the first transition'
);
select throws_ok(
  $$select * from private.finalize_alterity_webhook(
      'evt.m022.0001', repeat('1', 64), 'processed', null
    )$$,
  '55000', null,
  'repeated terminal finalization cannot reopen or replay a webhook'
);
select throws_ok(
  $$select * from private.finalize_alterity_webhook(
      'evt.m022.0001', repeat('1', 64), 'processed', null
    )$$,
  '55000', null,
  'terminal finalization remains fail-closed on every replay'
);
select throws_ok(
  $$select * from private.finalize_alterity_webhook(
      'evt.m022.0001', repeat('2', 64), 'processed', null
    )$$,
  '22023',
  null,
  'webhook finalization rejects a non-matching body digest'
);
select is(
  (select claim_outcome from private.claim_alterity_webhook(
    'evt.m022.0002', repeat('3', 64), pg_catalog.clock_timestamp(), 'billing.invoice.failed'
  )),
  'first_delivery',
  'a separate webhook event can be claimed'
);
select is(
  (select status from private.finalize_alterity_webhook(
    'evt.m022.0002', repeat('3', 64), 'failed', 'upstream.timeout'
  )),
  'failed',
  'webhook can finalize with a bounded safe error code'
);
reset role;
select is(
  (select safe_error_code from private.alterity_webhook_receipts
    where event_id = 'evt.m022.0002'),
  'upstream.timeout',
  'webhook ledger stores only the safe failure code'
);
set local role anon;
select set_config('request.jwt.claim.role', 'anon', true);
select throws_ok(
  $$select * from private.claim_alterity_webhook(
      'evt.m022.denied', repeat('4', 64), pg_catalog.clock_timestamp(), 'billing.invoice.paid'
    )$$,
  '42501',
  null,
  'anonymous callers cannot claim a webhook'
);
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select throws_ok(
  $$select * from private.claim_alterity_webhook(
      'evt.m022.denied-auth', repeat('4', 64), pg_catalog.clock_timestamp(), 'billing.invoice.paid'
    )$$,
  '42501',
  null,
  'authenticated browser callers cannot claim a webhook'
);
reset role;

select * from finish();
rollback;
