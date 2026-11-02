begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(15);

insert into auth.users (id)
values
  ('11111111-1111-4111-8111-111111111111'),
  ('22222222-2222-4222-8222-222222222222');

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select lives_ok(
  $$insert into public.profiles (user_id, display_name)
    values ('11111111-1111-4111-8111-111111111111', 'User A')$$,
  'a user can create their own profile'
);

select throws_ok(
  $$insert into public.profiles (user_id, display_name)
    values ('22222222-2222-4222-8222-222222222222', 'Claimed User B')$$,
  '42501'
);

reset role;
insert into public.profiles (user_id, display_name)
values ('22222222-2222-4222-8222-222222222222', 'User B');

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select results_eq(
  $$select user_id from public.profiles order by user_id$$,
  array['11111111-1111-4111-8111-111111111111'::uuid],
  'a user can only select their own profile'
);

select lives_ok(
  $$update public.profiles
    set display_name = 'User A Updated'
    where user_id = '11111111-1111-4111-8111-111111111111'$$,
  'a user can update their own profile'
);

select results_eq(
  $$update public.profiles
    set display_name = 'Cross-user update'
    where user_id = '22222222-2222-4222-8222-222222222222'
    returning user_id$$,
  $$select null::uuid where false$$,
  'cross-user profile updates affect no rows'
);

select results_eq(
  $$delete from public.profiles
    where user_id = '22222222-2222-4222-8222-222222222222'
    returning user_id$$,
  $$select null::uuid where false$$,
  'cross-user profile deletes affect no rows'
);

select lives_ok(
  $$insert into public.user_settings (user_id)
    values ('11111111-1111-4111-8111-111111111111')$$,
  'a user can create their own settings'
);

select throws_ok(
  $$insert into public.user_settings (user_id)
    values ('22222222-2222-4222-8222-222222222222')$$,
  '42501'
);

select lives_ok(
  $$insert into public.consent_records
      (user_id, consent_type, policy_version, granted)
    values
      ('11111111-1111-4111-8111-111111111111', 'terms', '1.0', true)$$,
  'a user can append their own consent record'
);

select throws_ok(
  $$insert into public.consent_records
      (user_id, consent_type, policy_version, granted)
    values
      ('22222222-2222-4222-8222-222222222222', 'terms', '1.0', true)$$,
  '42501'
);

select throws_ok(
  $$update public.consent_records set granted = false
    where user_id = '11111111-1111-4111-8111-111111111111'$$,
  '42501'
);

select throws_ok(
  $$delete from public.consent_records
    where user_id = '11111111-1111-4111-8111-111111111111'$$,
  '42501'
);

select ok(
  not has_table_privilege('anon', 'public.profiles', 'SELECT'),
  'anon has no profile select privilege'
);

select ok(
  not has_table_privilege('authenticated', 'public.consent_records', 'UPDATE'),
  'authenticated users have no consent update privilege'
);

select ok(
  not has_table_privilege('authenticated', 'public.consent_records', 'DELETE'),
  'authenticated users have no consent delete privilege'
);

select * from finish();
rollback;
