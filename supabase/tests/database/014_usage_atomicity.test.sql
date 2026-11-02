begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(16);

insert into auth.users(id) values ('11111111-1111-4111-8111-111111111111');
insert into private.entitlement_snapshots
  (id,user_id,plan_code,subscription_status,valid_until,source_version)
values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','11111111-1111-4111-8111-111111111111',
   'pro','active',now()+interval '1 day','v1');
insert into private.quota_buckets
  (id,user_id,entitlement_snapshot_id,meter,period_start,period_end,limit_quantity)
values
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','11111111-1111-4111-8111-111111111111',
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','voice.seconds',
   date_trunc('day',now()),date_trunc('day',now())+interval '1 day',10);

select ok(
  not has_function_privilege(
    'service_role',
    'private.reserve_usage_atomic(uuid,text,timestamp with time zone,timestamp with time zone,numeric,text,timestamp with time zone)',
    'EXECUTE'
  ),
  'service cannot reserve usage'
);

select lives_ok(
 $$select * from private.reserve_usage_atomic(
   '11111111-1111-4111-8111-111111111111','voice.seconds',
   date_trunc('day',now()),date_trunc('day',now())+interval '1 day',
   3,'reserve-0001',now()+interval '30 minutes')$$,
 'reserve succeeds'
);
select is((select reserved_quantity from private.quota_buckets where id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),3::numeric,'reserve increments quota');

select lives_ok(
 $$select * from private.reserve_usage_atomic(
   '11111111-1111-4111-8111-111111111111','voice.seconds',
   date_trunc('day',now()),date_trunc('day',now())+interval '1 day',
   3,'reserve-0001',now()+interval '30 minutes')$$,
 'reserve retry is idempotent'
);
select is((select count(*)::integer from private.usage_reservations),1,'reserve retry creates one row');

select throws_ok(
 $$select * from private.reserve_usage_atomic(
   '11111111-1111-4111-8111-111111111111','voice.seconds',
   date_trunc('day',now()),date_trunc('day',now())+interval '1 day',
   8,'reserve-over-limit',now()+interval '30 minutes')$$,
 '23514'
);

select lives_ok(
 $$select * from private.reserve_usage_atomic(
   '11111111-1111-4111-8111-111111111111','voice.seconds',
   date_trunc('day',now()),date_trunc('day',now())+interval '1 day',
   2,'reserve-0002',now()+interval '30 minutes')$$,
 'second reserve succeeds'
);

select lives_ok(
 $$select * from private.commit_usage_atomic(
   '11111111-1111-4111-8111-111111111111',
   (select id from private.usage_reservations where idempotency_key='reserve-0001'),
   2,'commit-0001',null,null)$$,
 'commit succeeds'
);
select results_eq(
 $$select reserved_quantity,committed_quantity from private.quota_buckets where id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'$$,
 $$values (2::numeric,2::numeric)$$,
 'commit atomically moves quota'
);
select is((select count(*)::integer from private.usage_events),1,'commit creates one usage event');
select is((select count(*)::integer from private.billing_outbox),1,'commit creates one outbox row');

select lives_ok(
 $$select * from private.commit_usage_atomic(
   '11111111-1111-4111-8111-111111111111',
   (select id from private.usage_reservations where idempotency_key='reserve-0001'),
   2,'commit-0001',null,null)$$,
 'commit retry is idempotent'
);
select is((select count(*)::integer from private.usage_events),1,'commit retry creates no duplicate');

select lives_ok(
 $$select * from private.release_usage_reservation_atomic(
   '11111111-1111-4111-8111-111111111111',
   (select id from private.usage_reservations where idempotency_key='reserve-0002'),
   'pre_provider_failure')$$,
 'release succeeds'
);
select results_eq(
 $$select reserved_quantity,committed_quantity from private.quota_buckets where id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'$$,
 $$values (0::numeric,2::numeric)$$,
 'release returns reserved quota'
);

select lives_ok(
 $$select * from private.release_usage_reservation_atomic(
   '11111111-1111-4111-8111-111111111111',
   (select id from private.usage_reservations where idempotency_key='reserve-0002'),
   'pre_provider_failure')$$,
 'release retry is idempotent'
);

select * from finish();
rollback;
