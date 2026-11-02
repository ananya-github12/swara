begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(9);

insert into auth.users(id) values ('22222222-2222-4222-8222-222222222222');
insert into private.entitlement_snapshots
 (id,user_id,plan_code,subscription_status,valid_until,source_version)
values
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaab','22222222-2222-4222-8222-222222222222',
  'pro','active',now()+interval '1 day','v1');
insert into private.quota_buckets
 (id,user_id,entitlement_snapshot_id,meter,period_start,period_end,limit_quantity)
values
 ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbc','22222222-2222-4222-8222-222222222222',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaab','llm.tokens',
  date_trunc('day',now()),date_trunc('day',now())+interval '1 day',10);

select ok(
  not has_function_privilege(
    'service_role',
    'private.reserve_usage_atomic(uuid,text,timestamp with time zone,timestamp with time zone,numeric,text,timestamp with time zone)',
    'EXECUTE'
  ),
  'service cannot reserve usage'
);

select lives_ok($$select * from private.reserve_usage_atomic(
 '22222222-2222-4222-8222-222222222222','llm.tokens',date_trunc('day',now()),
 date_trunc('day',now())+interval '1 day',6,'parallel-a',now()+interval '30 minutes')$$,'first contender reserves');
select lives_ok($$select * from private.reserve_usage_atomic(
 '22222222-2222-4222-8222-222222222222','llm.tokens',date_trunc('day',now()),
 date_trunc('day',now())+interval '1 day',4,'parallel-b',now()+interval '30 minutes')$$,'second contender reserves remainder');
select throws_ok($$select * from private.reserve_usage_atomic(
 '22222222-2222-4222-8222-222222222222','llm.tokens',date_trunc('day',now()),
 date_trunc('day',now())+interval '1 day',1,'parallel-c',now()+interval '30 minutes')$$,'23514');
select is((select reserved_quantity from private.quota_buckets where meter='llm.tokens'),10::numeric,'quota never exceeds limit');
select is((select count(*)::integer from private.usage_reservations),2,'failed contender creates no reservation');
select ok(pg_get_functiondef('private.reserve_usage_atomic(uuid,text,timestamp with time zone,timestamp with time zone,numeric,text,timestamp with time zone)'::regprocedure) ilike '%for update%','reserve locks quota row');
select ok(pg_get_functiondef('private.reserve_usage_atomic(uuid,text,timestamp with time zone,timestamp with time zone,numeric,text,timestamp with time zone)'::regprocedure) ilike '%pg_advisory_xact_lock%','reserve serializes idempotency retries');
select ok(
  exists(select 1 from pg_constraint where conrelid='private.quota_buckets'::regclass and conname='quota_buckets_accounted_quantity_check'),
  'database constraint forbids over-accounting'
);

select * from finish();
rollback;
