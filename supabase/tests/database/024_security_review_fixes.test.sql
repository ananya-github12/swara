begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(60);

-- Temporary grants make SET ROLE pgTAP assertions possible inside this rolled
-- back test transaction; they do not alter the production runtime contract.
grant usage on schema extensions to anon, authenticated, swara_api_runtime, swara_worker_runtime;
grant execute on all functions in schema extensions
  to anon, authenticated, swara_api_runtime, swara_worker_runtime;

select ok(
  pg_catalog.to_regprocedure('pgmq.read(text,integer,integer,jsonb)') is not null,
  'M023 requires the PGMQ 1.5.1 conditional read overload'
);

select ok(
  not exists (
    select 1
      from pg_catalog.pg_roles as runtime_role
     where runtime_role.rolname in ('swara_api_runtime', 'swara_worker_runtime')
       and (
         runtime_role.rolcanlogin
         or runtime_role.rolsuper
         or runtime_role.rolcreatedb
         or runtime_role.rolcreaterole
         or runtime_role.rolreplication
         or runtime_role.rolbypassrls
         or runtime_role.rolinherit
       )
  ),
  'runtime groups are NOLOGIN NOINHERIT and non-privileged'
);

select ok(
  not exists (
    select 1
      from pg_catalog.pg_auth_members as membership
      join pg_catalog.pg_roles as member_role on member_role.oid = membership.member
     where member_role.rolname in ('swara_api_runtime', 'swara_worker_runtime')
  ),
  'runtime groups are not members of upstream roles'
);

with gateways(signature) as (
  values
    ('private.import_workflow_atomic(uuid,uuid,text,integer,jsonb,uuid,text,uuid)'),
    ('private.enqueue_job(text,jsonb,integer)'),
    ('private.read_jobs(text,integer,integer)'),
    ('private.claim_job(text,bigint,text,integer)'),
    ('private.extend_job_visibility(text,bigint,text,integer)'),
    ('private.archive_job(text,bigint,text)'),
    ('private.dead_letter_job(text,bigint,text,text)'),
    ('private.enqueue_maintenance_dispatch(text,text,integer,integer)'),
    ('private.claim_expired_task_artifacts(integer,integer,timestamp with time zone)'),
    ('private.complete_task_artifact_purge(uuid,uuid)'),
    ('private.fail_task_artifact_purge(uuid,uuid,text,boolean)'),
    ('private.request_account_export(uuid,text)'),
    ('private.request_account_deletion(uuid,text,uuid)'),
    ('private.validate_context_item_version()'),
    ('private.register_device(uuid,text,text,text,text,text)'),
    ('private.revoke_device(uuid,uuid,text)'),
    ('private.create_vault_upload_intent(uuid,text,text,bigint,text,text,text)'),
    ('private.finalize_vault_upload(uuid,uuid,text,text)'),
    ('private.soft_delete_vault_document(uuid,uuid,text)'),
    ('private.complete_vault_document_processing(uuid,text,text,text)'),
    ('private.claim_alterity_webhook(text,text,timestamp with time zone,text)'),
    ('private.finalize_alterity_webhook(text,text,text,text)')
), resolved as (
  select signature::regprocedure as oid from gateways
)
select is(
  (select count(*)::bigint
     from resolved
     join pg_catalog.pg_proc as routine on routine.oid = resolved.oid
    where routine.prosecdef
      and pg_catalog.pg_get_userbyid(routine.proowner) = 'postgres'
      and 'search_path=""' = any(routine.proconfig)),
  22::bigint,
  'all M019-M022 security-definer gateways are postgres-owned with empty search paths'
);

with gateways(signature) as (
  values
    ('private.import_workflow_atomic(uuid,uuid,text,integer,jsonb,uuid,text,uuid)'),
    ('private.enqueue_job(text,jsonb,integer)'),
    ('private.read_jobs(text,integer,integer)'),
    ('private.claim_job(text,bigint,text,integer)'),
    ('private.extend_job_visibility(text,bigint,text,integer)'),
    ('private.archive_job(text,bigint,text)'),
    ('private.dead_letter_job(text,bigint,text,text)'),
    ('private.enqueue_maintenance_dispatch(text,text,integer,integer)'),
    ('private.claim_expired_task_artifacts(integer,integer,timestamp with time zone)'),
    ('private.complete_task_artifact_purge(uuid,uuid)'),
    ('private.fail_task_artifact_purge(uuid,uuid,text,boolean)'),
    ('private.request_account_export(uuid,text)'),
    ('private.request_account_deletion(uuid,text,uuid)'),
    ('private.validate_context_item_version()'),
    ('private.register_device(uuid,text,text,text,text,text)'),
    ('private.revoke_device(uuid,uuid,text)'),
    ('private.create_vault_upload_intent(uuid,text,text,bigint,text,text,text)'),
    ('private.finalize_vault_upload(uuid,uuid,text,text)'),
    ('private.soft_delete_vault_document(uuid,uuid,text)'),
    ('private.complete_vault_document_processing(uuid,text,text,text)'),
    ('private.claim_alterity_webhook(text,text,timestamp with time zone,text)'),
    ('private.finalize_alterity_webhook(text,text,text,text)')
), resolved as (
  select signature::regprocedure as oid from gateways
)
select is(
  (select count(*)::bigint
     from resolved
    where has_function_privilege('anon', oid, 'EXECUTE')
       or has_function_privilege('authenticated', oid, 'EXECUTE')
       or has_function_privilege('service_role', oid, 'EXECUTE')),
  0::bigint,
  'browser and service roles cannot execute any hardened gateway'
);

with expected_api(signature) as (
  values
    ('private.import_workflow_atomic(uuid,uuid,text,integer,jsonb,uuid,text,uuid)'),
    ('private.request_account_export(uuid,text)'),
    ('private.request_account_deletion(uuid,text,uuid)'),
    ('private.register_device(uuid,text,text,text,text,text)'),
    ('private.revoke_device(uuid,uuid,text)'),
    ('private.create_vault_upload_intent(uuid,text,text,bigint,text,text,text)'),
    ('private.finalize_vault_upload(uuid,uuid,text,text)'),
    ('private.soft_delete_vault_document(uuid,uuid,text)'),
    ('private.claim_alterity_webhook(text,text,timestamp with time zone,text)'),
    ('private.finalize_alterity_webhook(text,text,text,text)')
), gateways(signature) as (
  values
    ('private.import_workflow_atomic(uuid,uuid,text,integer,jsonb,uuid,text,uuid)'),
    ('private.enqueue_job(text,jsonb,integer)'),
    ('private.read_jobs(text,integer,integer)'),
    ('private.claim_job(text,bigint,text,integer)'),
    ('private.extend_job_visibility(text,bigint,text,integer)'),
    ('private.archive_job(text,bigint,text)'),
    ('private.dead_letter_job(text,bigint,text,text)'),
    ('private.enqueue_maintenance_dispatch(text,text,integer,integer)'),
    ('private.claim_expired_task_artifacts(integer,integer,timestamp with time zone)'),
    ('private.complete_task_artifact_purge(uuid,uuid)'),
    ('private.fail_task_artifact_purge(uuid,uuid,text,boolean)'),
    ('private.request_account_export(uuid,text)'),
    ('private.request_account_deletion(uuid,text,uuid)'),
    ('private.validate_context_item_version()'),
    ('private.register_device(uuid,text,text,text,text,text)'),
    ('private.revoke_device(uuid,uuid,text)'),
    ('private.create_vault_upload_intent(uuid,text,text,bigint,text,text,text)'),
    ('private.finalize_vault_upload(uuid,uuid,text,text)'),
    ('private.soft_delete_vault_document(uuid,uuid,text)'),
    ('private.complete_vault_document_processing(uuid,text,text,text)'),
    ('private.claim_alterity_webhook(text,text,timestamp with time zone,text)'),
    ('private.finalize_alterity_webhook(text,text,text,text)')
)
select ok(
  (select count(*)::bigint
     from expected_api
    where has_function_privilege('swara_api_runtime', signature, 'EXECUTE')) = 10
  and not exists (
    select 1
      from gateways
     where has_function_privilege('swara_api_runtime', signature, 'EXECUTE')
       and not exists (
         select 1 from expected_api where expected_api.signature = gateways.signature
       )
  ),
  'API runtime receives exactly the reviewed API gateway executions'
);

with expected_worker(signature) as (
  values
    ('private.enqueue_job(text,jsonb,integer)'),
    ('private.read_jobs(text,integer,integer)'),
    ('private.claim_job(text,bigint,text,integer)'),
    ('private.extend_job_visibility(text,bigint,text,integer)'),
    ('private.archive_job(text,bigint,text)'),
    ('private.dead_letter_job(text,bigint,text,text)'),
    ('private.enqueue_maintenance_dispatch(text,text,integer,integer)'),
    ('private.claim_expired_task_artifacts(integer,integer,timestamp with time zone)'),
    ('private.complete_task_artifact_purge(uuid,uuid)'),
    ('private.fail_task_artifact_purge(uuid,uuid,text,boolean)'),
    ('private.complete_vault_document_processing(uuid,text,text,text)')
), gateways(signature) as (
  values
    ('private.import_workflow_atomic(uuid,uuid,text,integer,jsonb,uuid,text,uuid)'),
    ('private.enqueue_job(text,jsonb,integer)'),
    ('private.read_jobs(text,integer,integer)'),
    ('private.claim_job(text,bigint,text,integer)'),
    ('private.extend_job_visibility(text,bigint,text,integer)'),
    ('private.archive_job(text,bigint,text)'),
    ('private.dead_letter_job(text,bigint,text,text)'),
    ('private.enqueue_maintenance_dispatch(text,text,integer,integer)'),
    ('private.claim_expired_task_artifacts(integer,integer,timestamp with time zone)'),
    ('private.complete_task_artifact_purge(uuid,uuid)'),
    ('private.fail_task_artifact_purge(uuid,uuid,text,boolean)'),
    ('private.request_account_export(uuid,text)'),
    ('private.request_account_deletion(uuid,text,uuid)'),
    ('private.validate_context_item_version()'),
    ('private.register_device(uuid,text,text,text,text,text)'),
    ('private.revoke_device(uuid,uuid,text)'),
    ('private.create_vault_upload_intent(uuid,text,text,bigint,text,text,text)'),
    ('private.finalize_vault_upload(uuid,uuid,text,text)'),
    ('private.soft_delete_vault_document(uuid,uuid,text)'),
    ('private.complete_vault_document_processing(uuid,text,text,text)'),
    ('private.claim_alterity_webhook(text,text,timestamp with time zone,text)'),
    ('private.finalize_alterity_webhook(text,text,text,text)')
)
select ok(
  (select count(*)::bigint
     from expected_worker
    where has_function_privilege('swara_worker_runtime', signature, 'EXECUTE')) = 11
  and not exists (
    select 1
      from gateways
     where has_function_privilege('swara_worker_runtime', signature, 'EXECUTE')
       and not exists (
         select 1 from expected_worker where expected_worker.signature = gateways.signature
       )
  ),
  'worker runtime receives exactly the reviewed worker gateway executions'
);

select ok(
  not has_table_privilege('authenticated', 'public.workflows', 'INSERT')
  and not has_table_privilege('authenticated', 'public.workflows', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.workflows', 'DELETE')
  and not has_table_privilege('authenticated', 'public.workflow_versions', 'INSERT')
  and not has_table_privilege('authenticated', 'public.workflow_versions', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.workflow_versions', 'DELETE'),
  'authenticated Data API workflow/version writes remain absent'
);

insert into auth.users (id) values
  ('01000000-0000-4000-8000-000000000001'),
  ('02000000-0000-4000-8000-000000000002');

set local role swara_api_runtime;
select
  set_config('m023.workflow_id', workflow_id::text, true),
  set_config('m023.workflow_version_id', version_id::text, true)
from private.import_workflow_atomic(
  '01000000-0000-4000-8000-000000000001',
  null,
  'M023 workflow',
  1,
  '{"steps":[{"action":"click"}]}'::jsonb,
  null,
  'workflow-create-0001',
  '03000000-0000-4000-8000-000000000003'
);
reset role;
select ok(
  exists (
    select 1 from public.workflows
     where id = current_setting('m023.workflow_id')::uuid
  ),
  'SET ROLE swara_api_runtime actually executes the workflow import gateway'
);

set local role swara_api_runtime;
select throws_ok(
  $$select * from private.import_workflow_atomic(
      '01000000-0000-4000-8000-000000000001',
      current_setting('m023.workflow_id')::uuid,
      'M023 workflow missing version',
      1,
      '{"steps":[{"action":"read"}]}'::jsonb,
      null,
      'workflow-update-0002',
      '04000000-0000-4000-8000-000000000004'
    )$$,
  '40001', null,
  'existing workflow import rejects a missing expected current version'
);
select lives_ok(
  $$select * from private.import_workflow_atomic(
      '01000000-0000-4000-8000-000000000001',
      current_setting('m023.workflow_id')::uuid,
      'M023 workflow updated',
      1,
      '{"steps":[{"action":"read"}]}'::jsonb,
      current_setting('m023.workflow_version_id')::uuid,
      'workflow-update-0003',
      '05000000-0000-4000-8000-000000000005'
    )$$,
  'existing workflow import accepts its locked matching expected version'
);
select lives_ok(
  $$select * from private.import_workflow_atomic(
      '01000000-0000-4000-8000-000000000001',
      null,
      'M023 workflow',
      1,
      '{"steps":[{"action":"click"}]}'::jsonb,
      null,
      'workflow-create-0001',
      '06000000-0000-4000-8000-000000000006'
    )$$,
  'completed workflow imports remain idempotent after later pointer changes'
);
select throws_ok(
  $$select * from private.import_workflow_atomic(
      '01000000-0000-4000-8000-000000000001',
      null,
      'Sibling label regression',
      1,
      '{"steps":[{"fieldId":"safe","name":"password","value":"arbitrary-secret"}]}'::jsonb,
      null,
      'workflow-secret-0004',
      '07000000-0000-4000-8000-000000000007'
    )$$,
  '22023', null,
  'a sibling password label cannot be masked by a safe fieldId'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', '01000000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select throws_ok(
  $$insert into public.workflows (user_id, name)
      values ('01000000-0000-4000-8000-000000000001', 'direct workflow')$$,
  '42501', null,
  'authenticated built-in role cannot bypass atomic workflow import'
);
reset role;

select ok(
  exists (
    select 1 from pg_catalog.pg_policies as policy
     where policy.schemaname = 'public'
       and policy.tablename = 'swara_context_items'
       and policy.policyname = 'context_items_insert_own'
       and coalesce(policy.with_check, '') ilike '%status%'
       and coalesce(policy.with_check, '') ilike '%active%'
  ),
  'authenticated context insert policy requires an active row'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '01000000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select throws_ok(
  $$insert into public.swara_context_items (user_id, type, key, value, status)
      values ('01000000-0000-4000-8000-000000000001', 'fact', 'm023-direct-status', 'bad', 'deleted')$$,
  '42501', null,
  'authenticated context insertion cannot start in a terminal status'
);
reset role;

insert into public.swara_context_items (id, user_id, type, key, value)
values (
  '08000000-0000-4000-8000-000000000008',
  '01000000-0000-4000-8000-000000000001',
  'fact', 'm023-correction', 'original'
);
select throws_ok(
  $$insert into public.swara_context_items (id, user_id, type, key, value, version, supersedes_id, status)
      values (
        '09000000-0000-4000-8000-000000000009',
        '01000000-0000-4000-8000-000000000001',
        'correction', 'm023-correction', 'invalid correction', 2,
        '08000000-0000-4000-8000-000000000008', 'superseded'
      )$$,
  '23514', null,
  'context correction trigger requires the replacement row to be active'
);
select ok(
  not has_table_privilege('authenticated', 'public.swara_context_items', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.swara_context_items', 'DELETE'),
  'authenticated context UPDATE and DELETE remain denied'
);

insert into public.devices (id, user_id, installation_hash, browser, extension_version)
values (
  '10000000-0000-4000-8000-000000000010',
  '01000000-0000-4000-8000-000000000001',
  'device-m023-task', 'chrome', '5.6.0'
);
insert into private.browser_sessions (
  id, user_id, device_id, status, interaction_mode, extension_version, policy_version
)
values (
  '11000000-0000-4000-8000-000000000011',
  '01000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000010',
  'active', 'browser', '5.6.0', 'm023'
);
insert into private.agent_tasks (
  id, user_id, session_id, instruction_hash, policy_version, extension_version
)
values (
  '12000000-0000-4000-8000-000000000012',
  '01000000-0000-4000-8000-000000000001',
  '11000000-0000-4000-8000-000000000011',
  repeat('a', 64), 'm023', '5.6.0'
);

select ok(
  pg_catalog.pg_get_functiondef('private.validate_task_step_checkpoint()'::regprocedure)
    like '%swara-task-step-sequence:%'
  and pg_catalog.pg_get_functiondef('private.validate_task_step_checkpoint()'::regprocedure)
    like '%swara-task-step-batch:%'
  and pg_catalog.pg_get_functiondef('private.validate_task_step_checkpoint()'::regprocedure)
    like '%pg_advisory_xact_lock%',
  'task checkpoint trigger locks stable owner/task/sequence and owner/task/batch keys before invariant checks'
);
select lives_ok(
  $$insert into private.task_steps (
      id, user_id, task_id, sequence, batch_id, action_index, action_type
    ) values
      (
        '13000000-0000-4000-8000-000000000013',
        '01000000-0000-4000-8000-000000000001',
        '12000000-0000-4000-8000-000000000012',
        1, '14000000-0000-4000-8000-000000000014', 0, 'read'
      ),
      (
        '13100000-0000-4000-8000-000000000013',
        '01000000-0000-4000-8000-000000000001',
        '12000000-0000-4000-8000-000000000012',
        1, '14000000-0000-4000-8000-000000000014', 1, 'click'
      )$$,
  'multiple actions in one task batch remain accepted'
);
select throws_ok(
  $$insert into private.task_steps (
      id, user_id, task_id, sequence, batch_id, action_index, action_type
    ) values (
      '15000000-0000-4000-8000-000000000015',
      '01000000-0000-4000-8000-000000000001',
      '12000000-0000-4000-8000-000000000012',
      2, '14000000-0000-4000-8000-000000000014', 2, 'click'
    )$$,
  '23514', null,
  'a browser batch cannot span task sequences, including after the lock-protected check'
);

insert into private.task_artifacts (
  id, user_id, task_id, artifact_type, storage_path, mime_type, size_bytes,
  content_hash, created_at, expires_at
) values
  (
    '17000000-0000-4000-8000-000000000017',
    '01000000-0000-4000-8000-000000000001',
    '12000000-0000-4000-8000-000000000012',
    'screenshot',
    '01000000-0000-4000-8000-000000000001/12000000-0000-4000-8000-000000000012/expired.png',
    'image/png', 1, repeat('b', 64),
    pg_catalog.clock_timestamp() - interval '2 hours',
    pg_catalog.clock_timestamp() - interval '1 hour'
  ),
  (
    '18000000-0000-4000-8000-000000000018',
    '01000000-0000-4000-8000-000000000001',
    '12000000-0000-4000-8000-000000000012',
    'screenshot',
    '01000000-0000-4000-8000-000000000001/12000000-0000-4000-8000-000000000012/future.png',
    'image/png', 1, repeat('c', 64),
    pg_catalog.clock_timestamp(),
    pg_catalog.clock_timestamp() + interval '1 hour'
  );

set local role swara_worker_runtime;
select set_config(
  'm023.expired_artifact_lease',
  (
    select lease_token::text
      from private.claim_expired_task_artifacts(1, 30, pg_catalog.clock_timestamp())
     where artifact_id = '17000000-0000-4000-8000-000000000017'
  ),
  true
);
reset role;
select is(
  (select status from private.task_artifacts where id = '17000000-0000-4000-8000-000000000017'),
  'leased',
  'worker claim uses database-clock eligibility'
);
update private.task_artifacts
   set lease_expires_at = pg_catalog.clock_timestamp() - interval '1 second'
 where id = '17000000-0000-4000-8000-000000000017';
set local role swara_worker_runtime;
select is(
  private.complete_task_artifact_purge(
    '17000000-0000-4000-8000-000000000017',
    current_setting('m023.expired_artifact_lease')::uuid
  ),
  false,
  'an expired artifact lease cannot complete work before reclamation'
);
select is(
  private.fail_task_artifact_purge(
    '17000000-0000-4000-8000-000000000017',
    current_setting('m023.expired_artifact_lease')::uuid,
    'lease.expired', false
  ),
  false,
  'an expired artifact lease cannot fail work before reclamation'
);
select throws_ok(
  $$select * from private.claim_expired_task_artifacts(
      1, 30, pg_catalog.clock_timestamp() + interval '30 seconds'
    )$$,
  '22023', null,
  'caller-controlled future claim time cannot claim unexpired artifacts'
);
reset role;

set local role swara_api_runtime;
select throws_ok(
  $$select private.request_account_export(
      '02000000-0000-4000-8000-000000000002', 'bad-key!'
    )$$,
  '22023', null,
  'account lifecycle functions enforce the exact M020 idempotency-key grammar'
);
select set_config(
  'm023.deletion_request_id',
  private.request_account_deletion(
    '02000000-0000-4000-8000-000000000002',
    'account-delete-0001',
    null
  )::text,
  true
);
reset role;
select ok(
  (
    select queue_message_id is not null and queue_enqueued_at is not null
      from private.account_deletion_requests
     where id = current_setting('m023.deletion_request_id')::uuid
  ),
  'new account deletion request atomically stores its queue acknowledgement'
);

set local role swara_api_runtime;
select throws_ok(
  $$select private.request_account_deletion(
      '02000000-0000-4000-8000-000000000002',
      'account-delete-0002', null
    )$$,
  '55000', null,
  'a different idempotency key cannot create a second active deletion job'
);
reset role;
update private.account_deletion_requests
   set status = 'completed',
       completed_at = pg_catalog.clock_timestamp()
 where id = current_setting('m023.deletion_request_id')::uuid;
update private.account_states
   set status = 'deleted',
       deleted_at = pg_catalog.clock_timestamp()
 where user_id = '02000000-0000-4000-8000-000000000002';
set local role swara_api_runtime;
select lives_ok(
  $$select private.request_account_deletion(
      '02000000-0000-4000-8000-000000000002',
      'account-delete-0001', null
    )$$,
  'same-key deletion retry recovers its durable result after the account is deleted'
);
select throws_ok(
  $$select private.request_account_deletion(
      '02000000-0000-4000-8000-000000000002',
      'account-delete-0003', null
    )$$,
  '55000', null,
  'a new deletion key is rejected for an already deleted account'
);
reset role;

select ok(
  has_column_privilege('swara_worker_runtime', 'private.account_states', 'status', 'UPDATE')
  and has_column_privilege('swara_worker_runtime', 'private.account_export_requests', 'status', 'UPDATE')
  and has_column_privilege('swara_worker_runtime', 'private.account_deletion_requests', 'completed_at', 'UPDATE')
  and not has_column_privilege('swara_worker_runtime', 'private.account_export_requests', 'queue_message_id', 'UPDATE')
  and not has_column_privilege('swara_worker_runtime', 'private.account_export_requests', 'queue_enqueued_at', 'UPDATE')
  and not has_column_privilege('swara_worker_runtime', 'private.account_deletion_requests', 'idempotency_key', 'UPDATE')
  and not has_column_privilege('swara_worker_runtime', 'private.account_deletion_requests', 'correlation_id', 'UPDATE')
  and not has_column_privilege('swara_worker_runtime', 'private.account_deletion_requests', 'user_id', 'UPDATE')
  and not has_table_privilege('service_role', 'private.account_states', 'UPDATE')
  and not has_table_privilege('service_role', 'private.account_export_requests', 'UPDATE')
  and not has_table_privilege('service_role', 'private.account_deletion_requests', 'UPDATE'),
  'worker lifecycle UPDATE grants exclude queue, correlation, idempotency, ownership, and service-role writes'
);

set local role swara_worker_runtime;
select throws_ok(
  $$select private.enqueue_maintenance_dispatch(
      'billing-outbox', 'retry_due_billing_outbox', 49, 60
    )$$,
  '22023', null,
  'maintenance dispatch rejects anything except its exact reviewed maximum'
);
reset role;

select ok(
  not exists (
    select 1
      from pg_catalog.pg_policies as policy
     where policy.schemaname = 'storage'
       and policy.tablename = 'objects'
       and policy.policyname in (
         'demo_documents_select',
         'demo_documents_insert',
         'demo_documents_update',
         'demo_documents_delete'
       )
  ),
  'all four hosted demo_documents legacy policies are absent'
);
select ok(
  not exists (
    select 1
      from pg_catalog.pg_policies as policy
     where policy.schemaname = 'storage'
       and policy.tablename = 'objects'
       and (
         'public' = any(policy.roles)
         or 'anon' = any(policy.roles)
         or 'authenticated' = any(policy.roles)
       )
       and (coalesce(policy.qual, '') || coalesce(policy.with_check, '')) ~*
         $$bucket_id\\s*=\\s*'documents'$$
  ),
  'no anon or authenticated Storage policy exposes the legacy documents bucket'
);
select ok(
  exists (
    select 1
      from pg_catalog.pg_policies as policy
     where policy.schemaname = 'storage'
       and policy.tablename = 'objects'
       and policy.policyname = 'swara_vault_originals_insert_own'
       and coalesce(policy.with_check, '') ilike '%vault_documents%'
       and coalesce(policy.with_check, '') ilike '%storage_path%'
       and coalesce(policy.with_check, '') ilike '%pending%'
  )
  and exists (
    select 1
      from pg_catalog.pg_policies as policy
     where policy.schemaname = 'storage'
       and policy.tablename = 'objects'
       and policy.policyname = 'swara_vault_originals_update_own'
       and coalesce(policy.qual, '') like
         '%^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$%'
       and coalesce(policy.with_check, '') like
         '%^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$%'
       and coalesce(policy.qual, '') ilike '%vault_documents%'
       and coalesce(policy.with_check, '') ilike '%storage_path%'
       and coalesce(policy.with_check, '') ilike '%pending%'
  ),
  'Vault original insert/update policies require an exact owned pending intent and the full UUID path'
);

set local role swara_api_runtime;
select set_config(
  'm023.vault_document_id',
  (
    select document_id::text
      from private.create_vault_upload_intent(
        '01000000-0000-4000-8000-000000000001',
        'm023-notes.txt',
        'text/plain',
        42,
        repeat('d', 64),
        'local',
        'vault-intent-0001'
      )
  ),
  true
);
select throws_ok(
  $$select * from private.finalize_vault_upload(
      '01000000-0000-4000-8000-000000000001',
      current_setting('m023.vault_document_id')::uuid,
      repeat('d', 64),
      'vault-finalize-0001'
    )$$,
  '22023', null,
  'Vault finalization fails before an exact owned Storage object exists'
);
reset role;
insert into storage.objects (id, bucket_id, name, owner_id, metadata)
values (
  '19000000-0000-4000-8000-000000000019',
  'vault-originals',
  '01000000-0000-4000-8000-000000000001/' || current_setting('m023.vault_document_id') || '/m023-notes.txt',
  '01000000-0000-4000-8000-000000000001',
  '{"size":42,"mimetype":"text/plain"}'::jsonb
);
set local role swara_api_runtime;
select lives_ok(
  $$select * from private.finalize_vault_upload(
      '01000000-0000-4000-8000-000000000001',
      current_setting('m023.vault_document_id')::uuid,
      repeat('d', 64),
      'vault-finalize-0002'
    )$$,
  'exact owned Storage object permits Vault finalization'
);
reset role;
select is(
  (
    select status from public.vault_documents
     where id = current_setting('m023.vault_document_id')::uuid
  ),
  'processing',
  'Storage-backed finalization advances the pending document to processing'
);

set local role swara_api_runtime;
select is(
  (
    select duplicate
      from private.create_vault_upload_intent(
        '01000000-0000-4000-8000-000000000001',
        'm023-notes.txt',
        'text/plain',
        42,
        repeat('d', 64),
        'local',
        'vault-intent-0002'
      )
  ),
  true,
  'a pre-existing identical same-hash Vault document reports duplicate=true'
);
select throws_ok(
  $$select * from private.create_vault_upload_intent(
      '01000000-0000-4000-8000-000000000001',
      'm023-notes.txt',
      'text/markdown',
      42,
      repeat('d', 64),
      'local',
      'vault-intent-0003'
    )$$,
  '22023', null,
  'same-hash recovery rejects mismatched non-deleted Vault metadata'
);
reset role;
update public.vault_documents
   set status = 'failed',
       error_code = 'ingest.failed',
       error_message = null
 where id = current_setting('m023.vault_document_id')::uuid;
set local role swara_api_runtime;
select is(
  (
    select status || ':' || duplicate::text
      from private.create_vault_upload_intent(
        '01000000-0000-4000-8000-000000000001',
        'm023-notes.txt',
        'text/plain',
        42,
        repeat('d', 64),
        'local',
        'vault-intent-0004'
      )
  ),
  'pending:false',
  'failed Vault document retries only under the exact prior upload contract'
);
select set_config(
  'm023.tracked_vault_document_id',
  (
    select document_id::text
      from private.create_vault_upload_intent(
        '01000000-0000-4000-8000-000000000001',
        'm023-tracked.txt',
        'text/plain',
        9,
        repeat('e', 64),
        'local',
        'vault-intent-0005'
      )
  ),
  true
);
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '01000000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select lives_ok(
  $$insert into storage.objects (id, bucket_id, name, owner_id, metadata)
      values (
        '20000000-0000-4000-8000-000000000020',
        'vault-originals',
        '01000000-0000-4000-8000-000000000001/' || current_setting('m023.tracked_vault_document_id') || '/m023-tracked.txt',
        '01000000-0000-4000-8000-000000000001',
        '{}'::jsonb
      )$$,
  'authenticated user can upload only to an exact pending tracked intent path'
);
select throws_ok(
  $$insert into storage.objects (id, bucket_id, name, owner_id, metadata)
      values (
        '21000000-0000-4000-8000-000000000021',
        'vault-originals',
        '01000000-0000-4000-8000-000000000001/22000000-0000-4000-8000-000000000022/untracked.txt',
        '01000000-0000-4000-8000-000000000001',
        '{}'::jsonb
      )$$,
  '42501', null,
  'authenticated user cannot upload an arbitrary untracked Vault path'
);
reset role;

set local role swara_api_runtime;
select set_config(
  'm023.device_id',
  (
    select device_id::text
      from private.register_device(
        '01000000-0000-4000-8000-000000000001',
        repeat('f', 64),
        'chrome', '5.6.0', null, 'device-register-0001'
      )
  ),
  true
);
reset role;
select ok(
  (
    select result_snapshot_recorded is true and result_revoked_at is null
      from private.device_mutation_requests
     where user_id = '01000000-0000-4000-8000-000000000001'
       and operation = 'register'
       and idempotency_key = 'device-register-0001'
  ),
  'initial device registration records an immutable active result snapshot'
);

set local role swara_api_runtime;
select set_config(
  'm023.original_revoke_at',
  (
    select revoked_at::text
      from private.revoke_device(
        '01000000-0000-4000-8000-000000000001',
        current_setting('m023.device_id')::uuid,
        'device-revoke-0001'
      )
  ),
  true
);
reset role;
select ok(
  current_setting('m023.original_revoke_at')::timestamptz is not null,
  'initial device revocation records its original durable timestamp'
);

set local role swara_api_runtime;
select * from private.register_device(
  '01000000-0000-4000-8000-000000000001',
  repeat('f', 64),
  'chrome', '5.6.0', null, 'device-register-0002'
);
select is(
  (
    select revoked_at
      from private.revoke_device(
        '01000000-0000-4000-8000-000000000001',
        current_setting('m023.device_id')::uuid,
        'device-revoke-0001'
      )
  ),
  current_setting('m023.original_revoke_at')::timestamptz,
  'replayed original revoke returns its historical timestamp after re-registration'
);
select is(
  (
    select duplicate
      from private.revoke_device(
        '01000000-0000-4000-8000-000000000001',
        current_setting('m023.device_id')::uuid,
        'device-revoke-0001'
      )
  ),
  true,
  'replayed original revoke is deterministically marked duplicate'
);
select * from private.revoke_device(
  '01000000-0000-4000-8000-000000000001',
  current_setting('m023.device_id')::uuid,
  'device-revoke-0002'
);
select is(
  (
    select revoked_at
      from private.register_device(
        '01000000-0000-4000-8000-000000000001',
        repeat('f', 64),
        'chrome', '5.6.0', null, 'device-register-0001'
      )
  ),
  null::timestamptz,
  'replayed original registration returns its historical active outcome, not current revocation'
);
select is(
  (
    select duplicate
      from private.register_device(
        '01000000-0000-4000-8000-000000000001',
        repeat('f', 64),
        'chrome', '5.6.0', null, 'device-register-0001'
      )
  ),
  true,
  'replayed original registration is deterministically marked duplicate'
);
reset role;

set local role swara_api_runtime;
select throws_ok(
  $$select * from private.finalize_alterity_webhook(
      'evt.m023.before-claim', repeat('1', 64), 'processed', null
    )$$,
  '22023', null,
  'webhook finalization fails before a matching active claim exists'
);
select throws_ok(
  $$select * from private.claim_alterity_webhook(
      'evt.m023.stale', repeat('1', 64),
      pg_catalog.clock_timestamp() - interval '16 minutes',
      'billing.invoice.paid'
    )$$,
  '22023', null,
  'stale webhook signatures are rejected before a receipt is created'
);
select throws_ok(
  $$select * from private.claim_alterity_webhook(
      'evt.m023.future', repeat('1', 64),
      pg_catalog.clock_timestamp() + interval '6 minutes',
      'billing.invoice.paid'
    )$$,
  '22023', null,
  'future webhook signatures are rejected before a receipt is created'
);
select is(
  (
    select claim_outcome
      from private.claim_alterity_webhook(
        'evt.m023.0001', repeat('2', 64),
        pg_catalog.clock_timestamp(), 'billing.invoice.paid'
      )
  ),
  'first_delivery',
  'only the first verified webhook delivery becomes processable'
);
select is(
  (
    select claim_outcome
      from private.claim_alterity_webhook(
        'evt.m023.0001', repeat('2', 64),
        pg_catalog.clock_timestamp(), 'billing.invoice.paid'
      )
  ),
  'in_progress',
  'same-hash active replay is explicitly non-processable'
);
select is(
  (
    select claim_outcome
      from private.claim_alterity_webhook(
        'evt.m023.0001', repeat('3', 64),
        pg_catalog.clock_timestamp(), 'billing.invoice.paid'
      )
  ),
  'hash_conflict',
  'different body digest is an explicitly non-processable conflict'
);
reset role;
select is(
  (
    select status from private.alterity_webhook_receipts
     where event_id = 'evt.m023.0001'
  ),
  'claimed',
  'hash conflict does not alter the original active webhook claim'
);
set local role swara_api_runtime;
select throws_ok(
  $$select * from private.finalize_alterity_webhook(
      'evt.m023.0001', repeat('3', 64), 'processed', null
    )$$,
  '22023', null,
  'conflicting webhook digest cannot finalize the active claim'
);
select is(
  (
    select status || ':' || finalized::text
      from private.finalize_alterity_webhook(
        'evt.m023.0001', repeat('2', 64), 'processed', null
      )
  ),
  'processed:true',
  'matching active webhook claim finalizes exactly once'
);
select is(
  (
    select claim_outcome
      from private.claim_alterity_webhook(
        'evt.m023.0001', repeat('2', 64),
        pg_catalog.clock_timestamp(), 'billing.invoice.paid'
      )
  ),
  'terminal_replay',
  'terminal webhook replay is explicitly non-processable'
);
select throws_ok(
  $$select * from private.finalize_alterity_webhook(
      'evt.m023.0001', repeat('2', 64), 'processed', null
    )$$,
  '55000', null,
  'terminal replay cannot be finalized because no active matching claim remains'
);
reset role;

select * from finish();
rollback;
