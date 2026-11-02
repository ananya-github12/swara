begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(14);

select has_table('private','browser_sessions','browser sessions exist');
select has_table('private','agent_tasks','agent tasks exist');
select has_table('private','task_steps','task steps exist');
select has_table('private','task_events','task events exist');
select has_table('private','task_artifacts','task artifacts exist');
select has_table('private','provider_calls','provider calls exist');

select is(
  (select count(*)::integer from information_schema.columns
   where table_schema='private'
     and table_name in ('browser_sessions','agent_tasks','task_steps','task_events','task_artifacts','provider_calls')
     and column_name in ('raw_instruction','filled_value','filled_values','api_key','request_payload','response_payload','raw_dom')),
  0,
  'execution schema contains no raw secret or provider payload columns'
);
select ok(not has_schema_privilege('authenticated','private','USAGE'), 'authenticated cannot use private schema');
select ok(not has_schema_privilege('anon','private','USAGE'), 'anon cannot use private schema');
select ok(has_table_privilege('swara_api_runtime','private.agent_tasks','SELECT'), 'API runtime can read tasks');
select ok(not has_table_privilege('swara_api_runtime','private.task_events','UPDATE'), 'events have no API update grant');
select ok(not has_schema_privilege('service_role','private','USAGE'), 'service role cannot use private schema');
select ok(not has_table_privilege('service_role','private.agent_tasks','SELECT'), 'service role cannot read tasks');
select is(
  (select count(*)::integer from pg_trigger
   where tgrelid='private.task_events'::regclass and not tgisinternal),
  3,
  'task events have ownership and append-only triggers'
);

select * from finish();
rollback;
