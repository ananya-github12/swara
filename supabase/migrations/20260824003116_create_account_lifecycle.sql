begin;

create table private.account_states (
  user_id uuid primary key references auth.users(id) on delete cascade,
  status text not null default 'active'
    check (status in ('active', 'deleting', 'deleted')),
  deletion_requested_at timestamptz,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((status = 'active' and deletion_requested_at is null and deleted_at is null)
      or (status = 'deleting' and deletion_requested_at is not null and deleted_at is null)
      or (status = 'deleted' and deletion_requested_at is not null and deleted_at is not null))
);

create table private.account_export_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'queued'
    check (status in ('queued', 'processing', 'ready', 'failed', 'expired', 'cancelled')),
  idempotency_key text not null,
  storage_path text,
  requested_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  expires_at timestamptz,
  error_code text,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  unique (user_id, idempotency_key),
  check (idempotency_key = btrim(idempotency_key) and char_length(idempotency_key) between 8 and 255),
  check (storage_path is null or char_length(storage_path) between 1 and 2048),
  check (started_at is null or started_at >= requested_at),
  check (completed_at is null or completed_at >= requested_at),
  check (expires_at is null or expires_at > requested_at),
  check (error_code is null or char_length(error_code) between 1 and 128),
  check (error_message is null or char_length(error_message) between 1 and 2000)
);

create index account_export_requests_user_status_requested_idx
  on private.account_export_requests (user_id, status, requested_at desc);
create index account_export_requests_user_expires_idx
  on private.account_export_requests (user_id, expires_at)
  where expires_at is not null;

create table private.account_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  export_request_id uuid,
  status text not null default 'requested'
    check (status in ('requested', 'export_pending', 'revoking', 'deleting', 'completed', 'failed', 'cancelled')),
  idempotency_key text not null,
  requested_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  error_code text,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  unique (user_id, idempotency_key),
  foreign key (export_request_id, user_id)
    references private.account_export_requests (id, user_id),
  check (idempotency_key = btrim(idempotency_key) and char_length(idempotency_key) between 8 and 255),
  check (started_at is null or started_at >= requested_at),
  check (completed_at is null or completed_at >= requested_at),
  check (error_code is null or char_length(error_code) between 1 and 128),
  check (error_message is null or char_length(error_message) between 1 and 2000)
);

create index account_deletion_requests_user_status_requested_idx
  on private.account_deletion_requests (user_id, status, requested_at desc);

create table audit.events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  event_type text not null,
  actor_type text not null default 'system'
    check (actor_type in ('user', 'service', 'system', 'webhook')),
  subject_hash text,
  correlation_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check (event_type = btrim(event_type) and char_length(event_type) between 1 and 128),
  check (subject_hash is null or subject_hash ~ '^[0-9a-f]{64}$'),
  check (jsonb_typeof(metadata) = 'object')
);

create index audit_events_user_occurred_idx on audit.events (user_id, occurred_at desc);
create index audit_events_type_occurred_idx on audit.events (event_type, occurred_at desc);

create trigger account_states_set_updated_at
  before update on private.account_states
  for each row execute function private.set_updated_at();
create trigger account_export_requests_set_updated_at
  before update on private.account_export_requests
  for each row execute function private.set_updated_at();
create trigger account_deletion_requests_set_updated_at
  before update on private.account_deletion_requests
  for each row execute function private.set_updated_at();

create or replace function audit.reject_event_mutation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception using errcode = '23514', message = 'audit.events is append-only';
end;
$$;

create trigger audit_events_append_only_rows
  before update or delete on audit.events
  for each row execute function audit.reject_event_mutation();
create trigger audit_events_append_only_truncate
  before truncate on audit.events
  for each statement execute function audit.reject_event_mutation();

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'account-exports',
  'account-exports',
  false,
  1073741824,
  array['application/zip', 'application/json']::text[]
);

create policy account_exports_select_own
  on storage.objects for select to authenticated
  using (
    bucket_id = 'account-exports'
    and owner_id = (select auth.uid()::text)
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] = (select auth.uid()::text)
    and (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and storage.filename(name) <> ''
  );

create policy account_exports_delete_own
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'account-exports'
    and owner_id = (select auth.uid()::text)
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] = (select auth.uid()::text)
    and (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and storage.filename(name) <> ''
  );

create or replace function private.ensure_account_active(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text;
begin
  insert into private.account_states (user_id) values (p_user_id)
  on conflict (user_id) do nothing;
  select status into v_status
  from private.account_states where user_id = p_user_id;
  if v_status is distinct from 'active' then
    raise exception using errcode = '55000', message = 'Account is not active';
  end if;
end;
$$;

create or replace function private.request_account_export(
  p_user_id uuid,
  p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_id uuid;
begin
  perform private.ensure_account_active(p_user_id);
  insert into private.account_export_requests (user_id, idempotency_key)
  values (p_user_id, p_idempotency_key)
  on conflict (user_id, idempotency_key) do nothing;
  select id into v_id from private.account_export_requests
   where user_id = p_user_id and idempotency_key = p_idempotency_key;
  insert into audit.events (user_id, event_type, actor_type, metadata)
  values (p_user_id, 'account_export_requested', 'service', jsonb_build_object('request_id', v_id))
  on conflict do nothing;
  return v_id;
end;
$$;

create or replace function private.request_account_deletion(
  p_user_id uuid,
  p_idempotency_key text,
  p_export_request_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_id uuid;
begin
  insert into private.account_states (user_id, status, deletion_requested_at)
  values (p_user_id, 'deleting', now())
  on conflict (user_id) do update
    set status = 'deleting',
        deletion_requested_at = coalesce(private.account_states.deletion_requested_at, now())
    where private.account_states.status <> 'deleted';

  insert into private.account_deletion_requests
    (user_id, export_request_id, status, idempotency_key)
  values
    (p_user_id, p_export_request_id,
     case when p_export_request_id is null then 'requested' else 'export_pending' end,
     p_idempotency_key)
  on conflict (user_id, idempotency_key) do nothing;
  select id into v_id from private.account_deletion_requests
   where user_id = p_user_id and idempotency_key = p_idempotency_key;
  insert into audit.events (user_id, event_type, actor_type, metadata)
  values (p_user_id, 'account_deletion_requested', 'service', jsonb_build_object('request_id', v_id))
  on conflict do nothing;
  return v_id;
end;
$$;

revoke all privileges on table
  private.account_states,
  private.account_export_requests,
  private.account_deletion_requests
  from public, anon, authenticated;
revoke all privileges on table audit.events from public, anon, authenticated;
revoke execute on function audit.reject_event_mutation() from public, anon, authenticated;
revoke execute on function private.ensure_account_active(uuid) from public, anon, authenticated;
revoke execute on function private.request_account_export(uuid, text) from public, anon, authenticated;
revoke execute on function private.request_account_deletion(uuid, text, uuid) from public, anon, authenticated;

grant usage on schema private, audit to service_role;
grant select, insert, update, delete on
  private.account_states,
  private.account_export_requests,
  private.account_deletion_requests
  to service_role;
grant select, insert on audit.events to service_role;
grant execute on function audit.reject_event_mutation() to service_role;
grant execute on function private.ensure_account_active(uuid) to service_role;
grant execute on function private.request_account_export(uuid, text) to service_role;
grant execute on function private.request_account_deletion(uuid, text, uuid) to service_role;

alter table private.account_states enable row level security;
alter table private.account_export_requests enable row level security;
alter table private.account_deletion_requests enable row level security;
alter table audit.events enable row level security;

create policy account_states_service on private.account_states for all to service_role using (true) with check (true);
create policy account_exports_service on private.account_export_requests for all to service_role using (true) with check (true);
create policy account_deletions_service on private.account_deletion_requests for all to service_role using (true) with check (true);
create policy audit_events_service_select on audit.events for select to service_role using (true);
create policy audit_events_service_insert on audit.events for insert to service_role with check (true);

commit;
