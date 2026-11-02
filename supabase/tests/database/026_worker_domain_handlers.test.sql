begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(14);

insert into auth.users (id)
values ('44444444-4444-4444-8444-444444444444');

select has_function('private', 'prepare_vault_ingestion', array['uuid'], 'Vault ingestion preparation exists');
select has_function('private', 'select_stuck_vault_ingestion', array['timestamp with time zone'], 'Stuck-ingestion selector exists');
select has_function('private', 'prepare_account_export', array['uuid'], 'Account export preparation exists');
select has_function('private', 'complete_account_export', array['uuid', 'text'], 'Account export completion exists');
select ok(
  (select prosecdef from pg_proc where oid = 'private.prepare_account_export(uuid)'::regprocedure)
  and (select prosecdef from pg_proc where oid = 'private.prepare_vault_ingestion(uuid)'::regprocedure),
  'worker preparation surfaces are security-definer boundaries'
);
select ok(
  has_function_privilege('swara_worker_runtime', 'private.prepare_account_export(uuid)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'private.prepare_account_export(uuid)', 'EXECUTE'),
  'account export preparation is worker-only'
);

insert into public.vault_documents (
  id, user_id, filename, mime_type, size_bytes, sha256, storage_path, extraction_method, status
)
values (
  '55555555-5555-4555-8555-555555555555',
  '44444444-4444-4444-8444-444444444444',
  'notes.txt', 'text/plain', 5, repeat('a', 64),
  '44444444-4444-4444-8444-444444444444/55555555-5555-4555-8555-555555555555/notes.txt',
  'local', 'pending'
);
update public.vault_documents set status = 'processing'
 where id = '55555555-5555-4555-8555-555555555555';
select is(
  (select count(*)::integer from private.worker_job_runs where queue_name = 'vault-ingest' and idempotency_key like 'vault-ingest:55555555-5555-4555-8555-555555555555:%'),
  1,
  'processing transition enqueues exactly one ingestion job'
);
select is(
  (select sha256 from private.prepare_vault_ingestion('55555555-5555-4555-8555-555555555555')),
  repeat('a', 64),
  'ingestion preparation returns only the document metadata contract'
);

insert into private.account_export_requests (id, user_id, idempotency_key)
values ('66666666-6666-4666-8666-666666666666', '44444444-4444-4444-8444-444444444444', 'export-worker-001');
select is(
  (select jsonb_typeof(payload) from private.prepare_account_export('66666666-6666-4666-8666-666666666666')),
  'object',
  'account export preparation returns a bounded JSON object'
);
select is(
  (select status from private.account_export_requests where id = '66666666-6666-4666-8666-666666666666'),
  'processing',
  'account export preparation claims the request'
);
select is(
  (select private.complete_account_export(
    '66666666-6666-4666-8666-666666666666',
    '44444444-4444-4444-8444-444444444444/66666666-6666-4666-8666-666666666666/export.json'
  )),
  true,
  'account export completion records the Storage path'
);
select is(
  (select status from private.account_export_requests where id = '66666666-6666-4666-8666-666666666666'),
  'ready',
  'completed export is ready for authenticated download'
);
select is(
  (select storage_path from private.account_export_requests where id = '66666666-6666-4666-8666-666666666666'),
  '44444444-4444-4444-8444-444444444444/66666666-6666-4666-8666-666666666666/export.json',
  'export path remains owner/request scoped'
);
select ok(
  not has_function_privilege('anon', 'private.revoke_account_sessions(uuid)', 'EXECUTE')
  and has_function_privilege('swara_worker_runtime', 'private.revoke_account_sessions(uuid)', 'EXECUTE'),
  'session revocation is worker-only'
);

select * from finish();
rollback;
