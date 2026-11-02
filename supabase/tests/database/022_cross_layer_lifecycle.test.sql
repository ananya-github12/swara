begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(55);

select has_column('private', 'task_steps', 'action_index', 'task steps support multiple actions per batch');
select has_column('public', 'swara_context_items', 'browser_session_id', 'session context is bound to a browser session');
select has_column('public', 'swara_context_items', 'task_id', 'task context is bound to a task');
select has_column('private', 'task_artifacts', 'status', 'artifact purge has a durable status');
select has_column('private', 'task_artifacts', 'lease_expires_at', 'artifact purge has an expiring lease');
select has_column('private', 'task_artifacts', 'attempt_count', 'artifact purge tracks attempts');
select has_column('private', 'task_artifacts', 'completed_at', 'artifact purge records terminal completion');
select ok(
  not exists (
    select 1
      from pg_catalog.pg_constraint as constraint_row
     where constraint_row.conrelid = 'audit.events'::pg_catalog.regclass
       and constraint_row.contype = 'f'
       and constraint_row.confrelid = 'auth.users'::pg_catalog.regclass
  ),
  'append-only audit events no longer have an Auth-user foreign key'
);
select ok(
  has_function_privilege('swara_api_runtime', 'private.request_account_export(uuid,text)', 'EXECUTE'),
  'API runtime can request account exports'
);
select ok(
  has_function_privilege('swara_api_runtime', 'private.request_account_deletion(uuid,text,uuid)', 'EXECUTE'),
  'API runtime can request account deletions'
);
select ok(
  not has_function_privilege('swara_api_runtime', 'private.claim_expired_task_artifacts(integer,integer,timestamp with time zone)', 'EXECUTE'),
  'API runtime cannot claim artifact purge work'
);
select ok(
  has_function_privilege('swara_worker_runtime', 'private.claim_expired_task_artifacts(integer,integer,timestamp with time zone)', 'EXECUTE'),
  'worker runtime can claim artifact purge work'
);
select ok(
  not has_function_privilege('service_role', 'private.claim_expired_task_artifacts(integer,integer,timestamp with time zone)', 'EXECUTE'),
  'service role cannot claim artifact purge work'
);
select ok(
  not has_function_privilege('service_role', 'private.request_account_export(uuid,text)', 'EXECUTE'),
  'service role cannot request account exports'
);

insert into auth.users (id) values
  ('a1000000-0000-4000-8000-000000000001'),
  ('a1000000-0000-4000-8000-000000000002'),
  ('a1000000-0000-4000-8000-000000000003');

insert into public.devices (id, user_id, installation_hash, browser, extension_version) values
  ('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001', 'device-a-022', 'chrome', '0.22.0'),
  ('b1000000-0000-4000-8000-000000000002', 'a1000000-0000-4000-8000-000000000002', 'device-b-022', 'chrome', '0.22.0');

insert into private.browser_sessions (
  id, user_id, device_id, status, interaction_mode, extension_version, policy_version
) values
  ('c1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001', 'active', 'browser', '0.22.0', 'policy-022'),
  ('c1000000-0000-4000-8000-000000000002', 'a1000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001', 'active', 'browser', '0.22.0', 'policy-022'),
  ('c1000000-0000-4000-8000-000000000003', 'a1000000-0000-4000-8000-000000000002', 'b1000000-0000-4000-8000-000000000002', 'active', 'browser', '0.22.0', 'policy-022');

insert into private.agent_tasks (
  id, user_id, session_id, instruction_hash, policy_version, extension_version
) values
  ('d1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001', repeat('1', 64), 'policy-022', '0.22.0'),
  ('d1000000-0000-4000-8000-000000000002', 'a1000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000002', repeat('2', 64), 'policy-022', '0.22.0');

select lives_ok(
  $$insert into private.task_steps (
      id,user_id,task_id,sequence,batch_id,action_index,action_type
    ) values (
      'f1000000-0000-4000-8000-000000000001',
      'a1000000-0000-4000-8000-000000000001',
      'd1000000-0000-4000-8000-000000000001',1,
      'e1000000-0000-4000-8000-000000000001',0,'read'
    )$$,
  'first action in a browser batch is accepted'
);
select lives_ok(
  $$insert into private.task_steps (
      id,user_id,task_id,sequence,batch_id,action_index,action_type
    ) values (
      'f1000000-0000-4000-8000-000000000002',
      'a1000000-0000-4000-8000-000000000001',
      'd1000000-0000-4000-8000-000000000001',1,
      'e1000000-0000-4000-8000-000000000001',1,'click'
    )$$,
  'second action in the same browser batch is accepted'
);
select lives_ok(
  $$insert into private.task_steps (
      id,user_id,task_id,sequence,batch_id,action_index,action_type
    ) values (
      'f1000000-0000-4000-8000-000000000003',
      'a1000000-0000-4000-8000-000000000001',
      'd1000000-0000-4000-8000-000000000001',2,
      'e1000000-0000-4000-8000-000000000002',0,'read'
    )$$,
  'a later batch is accepted after a prior batch exists'
);
select throws_ok(
  $$insert into private.task_steps (
      id,user_id,task_id,sequence,batch_id,action_index,action_type
    ) values (
      'f1000000-0000-4000-8000-000000000004',
      'a1000000-0000-4000-8000-000000000001',
      'd1000000-0000-4000-8000-000000000001',2,
      'e1000000-0000-4000-8000-000000000002',0,'click'
    )$$,
  '23505'
);
select throws_ok(
  $$insert into private.task_steps (
      id,user_id,task_id,sequence,batch_id,action_index,action_type
    ) values (
      'f1000000-0000-4000-8000-000000000005',
      'a1000000-0000-4000-8000-000000000001',
      'd1000000-0000-4000-8000-000000000001',2,
      'e1000000-0000-4000-8000-000000000003',1,'click'
    )$$,
  '23514'
);
select lives_ok(
  $$insert into private.task_steps (
      id,user_id,task_id,sequence,batch_id,action_index,action_type
    ) values (
      'f1000000-0000-4000-8000-000000000006',
      'a1000000-0000-4000-8000-000000000001',
      'd1000000-0000-4000-8000-000000000002',1,
      'e1000000-0000-4000-8000-000000000004',4,'read'
    )$$,
  'the first batch does not require a predecessor action'
);
select throws_ok(
  $$insert into private.task_steps (
      id,user_id,task_id,sequence,batch_id,action_index,action_type
    ) values (
      'f1000000-0000-4000-8000-000000000007',
      'a1000000-0000-4000-8000-000000000001',
      'd1000000-0000-4000-8000-000000000002',3,
      'e1000000-0000-4000-8000-000000000005',0,'read'
    )$$,
  '23514'
);
select throws_ok(
  $$insert into private.task_steps (
      id,user_id,task_id,sequence,batch_id,action_index,action_type
    ) values (
      'f1000000-0000-4000-8000-000000000008',
      'a1000000-0000-4000-8000-000000000001',
      'd1000000-0000-4000-8000-000000000002',1,
      'e1000000-0000-4000-8000-000000000006',-1,'read'
    )$$,
  '23514'
);

select lives_ok(
  $$insert into public.swara_context_items (id,user_id,type,key,value)
    values (
      '01000000-0000-4000-8000-000000000001',
      'a1000000-0000-4000-8000-000000000001',
      'fact','persistent-022','persistent value'
    )$$,
  'persistent context has no temporary owner'
);
select throws_ok(
  $$insert into public.swara_context_items (id,user_id,type,key,value,scope)
    values (
      '01000000-0000-4000-8000-000000000002',
      'a1000000-0000-4000-8000-000000000001',
      'fact','unowned-session-022','unsafe value','session'
    )$$,
  '23514'
);
select lives_ok(
  $$insert into public.swara_context_items (
      id,user_id,type,key,value,scope,browser_session_id
    ) values (
      '01000000-0000-4000-8000-000000000003',
      'a1000000-0000-4000-8000-000000000001',
      'fact','session-022','session value','session',
      'c1000000-0000-4000-8000-000000000001'
    )$$,
  'session context is bound to an owned browser session'
);
select throws_ok(
  $$insert into public.swara_context_items (
      id,user_id,type,key,value,scope,browser_session_id
    ) values (
      '01000000-0000-4000-8000-000000000004',
      'a1000000-0000-4000-8000-000000000001',
      'fact','cross-user-session-022','unsafe value','session',
      'c1000000-0000-4000-8000-000000000003'
    )$$,
  '23503'
);
select throws_ok(
  $$insert into public.swara_context_items (id,user_id,type,key,value,scope)
    values (
      '01000000-0000-4000-8000-000000000005',
      'a1000000-0000-4000-8000-000000000001',
      'fact','unowned-task-022','unsafe value','task'
    )$$,
  '23514'
);
select lives_ok(
  $$insert into public.swara_context_items (id,user_id,type,key,value,scope,task_id)
    values (
      '01000000-0000-4000-8000-000000000006',
      'a1000000-0000-4000-8000-000000000001',
      'fact','task-022','task value','task',
      'd1000000-0000-4000-8000-000000000001'
    )$$,
  'task context is bound to an owned task'
);
select is(
  (select browser_session_id from public.swara_context_items where id = '01000000-0000-4000-8000-000000000006'),
  null::uuid,
  'task context derives its browser session through the owned task'
);
select throws_ok(
  $$insert into public.swara_context_items (
      id,user_id,type,key,value,scope,version,supersedes_id,browser_session_id
    ) values (
      '01000000-0000-4000-8000-000000000007',
      'a1000000-0000-4000-8000-000000000001',
      'correction','session-022','new value','session',2,
      '01000000-0000-4000-8000-000000000003',
      'c1000000-0000-4000-8000-000000000002'
    )$$,
  '23514'
);

insert into private.task_artifacts (
  id,user_id,task_id,artifact_type,storage_path,mime_type,size_bytes,content_hash,created_at,expires_at
) values
  (
    '11110000-0000-4000-8000-000000000001',
    'a1000000-0000-4000-8000-000000000001',
    'd1000000-0000-4000-8000-000000000001',
    'screenshot',
    'a1000000-0000-4000-8000-000000000001/d1000000-0000-4000-8000-000000000001/first.png',
    'image/png',0,repeat('a',64),now() - interval '4 hours',now() - interval '2 hours'
  ),
  (
    '11110000-0000-4000-8000-000000000002',
    'a1000000-0000-4000-8000-000000000001',
    'd1000000-0000-4000-8000-000000000001',
    'screenshot',
    'a1000000-0000-4000-8000-000000000001/d1000000-0000-4000-8000-000000000001/second.png',
    'image/png',0,repeat('b',64),now() - interval '3 hours',now() - interval '1 hour'
  );

set local role swara_worker_runtime;
select count(*)::integer from private.claim_expired_task_artifacts(1, 30, now());
reset role;
select is(
  (select status from private.task_artifacts where id = '11110000-0000-4000-8000-000000000001'),
  'leased',
  'claimed artifact is leased'
);
select is(
  (select attempt_count from private.task_artifacts where id = '11110000-0000-4000-8000-000000000001'),
  1,
  'first claim increments the attempt count'
);
select ok(
  (select lease_token is not null from private.task_artifacts where id = '11110000-0000-4000-8000-000000000001'),
  'worker claim creates an opaque lease token'
);
select set_config(
  'swara_test.artifact_one_lease',
  (select lease_token::text from private.task_artifacts where id = '11110000-0000-4000-8000-000000000001'),
  true
);
set local role swara_worker_runtime;
select private.complete_task_artifact_purge(
  '11110000-0000-4000-8000-000000000001',
  current_setting('swara_test.artifact_one_lease')::uuid
);
reset role;
select is(
  (select status from private.task_artifacts where id = '11110000-0000-4000-8000-000000000001'),
  'completed',
  'completed artifact is no longer reclaimable'
);
select ok(
  (select completed_at is not null from private.task_artifacts where id = '11110000-0000-4000-8000-000000000001'),
  'matching worker lease records task-artifact completion'
);

set local role swara_worker_runtime;
select count(*)::integer from private.claim_expired_task_artifacts(1, 30, now());
reset role;
select is(
  (select attempt_count from private.task_artifacts where id = '11110000-0000-4000-8000-000000000002'),
  1,
  'initial second-artifact claim is recorded'
);
select is(
  (select status from private.task_artifacts where id = '11110000-0000-4000-8000-000000000002'),
  'leased',
  'worker claims only the next bounded expired artifact'
);
select set_config(
  'swara_test.artifact_two_stale_lease',
  (select lease_token::text from private.task_artifacts where id = '11110000-0000-4000-8000-000000000002'),
  true
);
update private.task_artifacts
   set lease_expires_at = pg_catalog.clock_timestamp() - interval '1 second'
 where id = '11110000-0000-4000-8000-000000000002';
set local role swara_worker_runtime;
select count(*)::integer from private.claim_expired_task_artifacts(1, 30, now());
reset role;
select is(
  (select attempt_count from private.task_artifacts where id = '11110000-0000-4000-8000-000000000002'),
  2,
  'reclaim increments the durable attempt count'
);
select set_config(
  'swara_test.artifact_two_current_lease',
  (select lease_token::text from private.task_artifacts where id = '11110000-0000-4000-8000-000000000002'),
  true
);
select ok(
  (select lease_token::text from private.task_artifacts where id = '11110000-0000-4000-8000-000000000002')
    <> current_setting('swara_test.artifact_two_stale_lease'),
  'reclaim replaces the previous worker lease token'
);
set local role swara_worker_runtime;
select private.complete_task_artifact_purge(
  '11110000-0000-4000-8000-000000000002',
  current_setting('swara_test.artifact_two_stale_lease')::uuid
);
reset role;
select is(
  (select status from private.task_artifacts where id = '11110000-0000-4000-8000-000000000002'),
  'leased',
  'a stale worker cannot complete a reclaimed artifact'
);
set local role swara_worker_runtime;
select private.fail_task_artifact_purge(
  '11110000-0000-4000-8000-000000000002',
  current_setting('swara_test.artifact_two_current_lease')::uuid,
  'storage_not_found',
  true
);
reset role;
select is(
  (select status from private.task_artifacts where id = '11110000-0000-4000-8000-000000000002'),
  'failed',
  'terminal artifact failure is durable'
);
select ok(
  (select completed_at is not null from private.task_artifacts where id = '11110000-0000-4000-8000-000000000002'),
  'terminal artifact failure records completion time'
);
select is(
  (select last_error_code from private.task_artifacts where id = '11110000-0000-4000-8000-000000000002'),
  'storage_not_found',
  'terminal artifact failure records only its safe error code'
);
select ok(
  pg_catalog.to_regprocedure('private.request_expired_task_artifact_purge(integer,timestamp with time zone)') is null,
  'one-way artifact purge handoff function is removed'
);

set local role swara_api_runtime;
select private.request_account_export(
  'a1000000-0000-4000-8000-000000000001',
  'account-export-022-0001'
);
select private.request_account_export(
  'a1000000-0000-4000-8000-000000000001',
  'account-export-022-0001'
);
reset role;
select is(
  (select count(*)::integer from private.account_export_requests
    where user_id = 'a1000000-0000-4000-8000-000000000001'
      and idempotency_key = 'account-export-022-0001'),
  1,
  'account export retry creates one durable request'
);
select ok(
  (select queue_message_id is not null and queue_enqueued_at is not null
     from private.account_export_requests
    where user_id = 'a1000000-0000-4000-8000-000000000001'
      and idempotency_key = 'account-export-022-0001'),
  'account export request stores its queue acknowledgement'
);
select is(
  (select count(*)::integer from private.worker_job_runs
    where queue_name = 'account-export'
      and idempotency_key = 'account-export-022-0001'),
  1,
  'account export retries create one queue-ledger entry'
);
select is(
  (select count(*)::integer from audit.events
    where event_type = 'account_export_queued'
      and user_id = 'a1000000-0000-4000-8000-000000000001'),
  1,
  'account export queue acknowledgement is recorded once'
);
select set_config(
  'swara_test.export_request_id',
  (select id::text from private.account_export_requests
    where user_id = 'a1000000-0000-4000-8000-000000000001'
      and idempotency_key = 'account-export-022-0001'),
  true
);
set local role swara_api_runtime;
select private.request_account_deletion(
  'a1000000-0000-4000-8000-000000000001',
  'account-deletion-022-0001',
  current_setting('swara_test.export_request_id')::uuid
);
select private.request_account_deletion(
  'a1000000-0000-4000-8000-000000000001',
  'account-deletion-022-0001',
  current_setting('swara_test.export_request_id')::uuid
);
reset role;
select is(
  (select count(*)::integer from private.account_deletion_requests
    where user_id = 'a1000000-0000-4000-8000-000000000001'
      and idempotency_key = 'account-deletion-022-0001'),
  1,
  'account deletion retry creates one durable request'
);
select ok(
  (select queue_message_id is not null and queue_enqueued_at is not null
     from private.account_deletion_requests
    where user_id = 'a1000000-0000-4000-8000-000000000001'
      and idempotency_key = 'account-deletion-022-0001'),
  'account deletion request stores its queue acknowledgement'
);
select is(
  (select status from private.account_states
    where user_id = 'a1000000-0000-4000-8000-000000000001'),
  'deleting',
  'account deletion request blocks new account work before the worker runs'
);
select is(
  (select count(*)::integer from private.worker_job_runs
    where queue_name = 'account-deletion'
      and idempotency_key = 'account-deletion-022-0001'),
  1,
  'account deletion retries create one queue-ledger entry'
);

insert into audit.events (user_id, event_type, actor_type, subject_hash, metadata)
values (
  'a1000000-0000-4000-8000-000000000003',
  'account_audit_delete_022',
  'system',
  repeat('f', 64),
  '{}'::jsonb
);
select lives_ok(
  $$delete from auth.users where id = 'a1000000-0000-4000-8000-000000000003'$$,
  'Auth user deletion does not attempt to mutate append-only audit history'
);
select is(
  (select user_id::text from audit.events where event_type = 'account_audit_delete_022'),
  'a1000000-0000-4000-8000-000000000003',
  'audit history retains the historical Auth UUID after deletion'
);
select is(
  (select subject_hash from audit.events where event_type = 'account_audit_delete_022'),
  repeat('f', 64),
  'audit history retains its durable subject hash after deletion'
);

select * from finish();
rollback;
