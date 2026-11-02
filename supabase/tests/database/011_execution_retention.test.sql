begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(15);

select has_column('private','browser_sessions','retention_expires_at','sessions expire');
select has_column('private','agent_tasks','retention_expires_at','tasks expire');
select has_column('private','task_steps','retention_expires_at','steps expire');
select has_column('private','task_events','retention_expires_at','events expire');
select has_column('private','provider_calls','retention_expires_at','provider metrics expire');
select has_column('private','task_artifacts','expires_at','artifacts expire');
select has_column('private','task_artifacts','purge_requested_at','legacy artifact purge marker is retained only for compatibility');

select ok(not has_function_privilege('authenticated','private.claim_expired_task_artifacts(integer,integer,timestamp with time zone)','EXECUTE'), 'clients cannot claim expired artifacts');
select ok(not has_function_privilege('authenticated','private.complete_task_artifact_purge(uuid,uuid)','EXECUTE'), 'clients cannot complete purges');
select ok(has_function_privilege('swara_worker_runtime','private.claim_expired_task_artifacts(integer,integer,timestamp with time zone)','EXECUTE'), 'worker can claim expired artifacts');
select ok(has_function_privilege('swara_worker_runtime','private.complete_task_artifact_purge(uuid,uuid)','EXECUTE'), 'worker can complete a matching purge lease');
select ok(not has_function_privilege('service_role','private.claim_expired_task_artifacts(integer,integer,timestamp with time zone)','EXECUTE'), 'service cannot claim expired artifacts');
select ok(not has_function_privilege('service_role','private.complete_task_artifact_purge(uuid,uuid)','EXECUTE'), 'service cannot complete purges');

select throws_ok($$select * from private.claim_expired_task_artifacts(0,30,now())$$,'22023');
select throws_ok($$select * from private.claim_expired_task_artifacts(101,30,now())$$,'22023');

select * from finish();
rollback;
