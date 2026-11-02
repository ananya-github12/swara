-- Round 4A: server-only billing links, entitlement cache, usage accounting
-- primitives, and a durable billing outbox.
--
-- Alterity remains authoritative for checkout, subscriptions, invoices, and
-- price calculation. This schema stores only an opaque customer reference,
-- entitlement cache data, and Swara-local operational accounting state.
-- Atomic reserve/commit/release functions are intentionally deferred to M014.

begin;

create table private.billing_links (
  user_id uuid primary key references auth.users(id) on delete cascade,
  provider text not null default 'alterity',
  external_customer_id text not null,
  link_status text not null default 'pending',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint billing_links_provider_check
    check (provider = 'alterity'),
  constraint billing_links_external_customer_id_check
    check (
      external_customer_id = btrim(external_customer_id)
      and char_length(external_customer_id) between 1 and 512
    ),
  constraint billing_links_link_status_check
    check (link_status in ('pending', 'active', 'suspended', 'revoked')),
  constraint billing_links_provider_external_customer_id_key
    unique (provider, external_customer_id)
);

comment on table private.billing_links is
  'One opaque Alterity customer reference per Swara user; no external identity or organization records are mirrored here.';

create table private.entitlement_snapshots (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  plan_code text not null,
  subscription_status text not null,
  capabilities jsonb not null default '{}'::jsonb,
  limits jsonb not null default '{}'::jsonb,
  valid_until timestamptz not null,
  source_version text not null,
  refreshed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),

  constraint entitlement_snapshots_id_user_id_key unique (id, user_id),
  constraint entitlement_snapshots_user_id_source_version_key
    unique (user_id, source_version),
  constraint entitlement_snapshots_plan_code_check
    check (
      plan_code = lower(btrim(plan_code))
      and plan_code ~ '^[a-z0-9][a-z0-9._-]{0,127}$'
    ),
  constraint entitlement_snapshots_subscription_status_check
    check (
      subscription_status in (
        'none',
        'trialing',
        'active',
        'past_due',
        'paused',
        'unpaid',
        'cancelled',
        'expired',
        'incomplete'
      )
    ),
  constraint entitlement_snapshots_capabilities_object_check
    check (jsonb_typeof(capabilities) = 'object'),
  constraint entitlement_snapshots_limits_object_check
    check (jsonb_typeof(limits) = 'object'),
  constraint entitlement_snapshots_source_version_check
    check (
      source_version = btrim(source_version)
      and char_length(source_version) between 1 and 512
    )
);

comment on table private.entitlement_snapshots is
  'Versioned cache of externally authoritative billing entitlements. Capabilities and limits are JSON objects so billing-plan changes do not require a schema migration.';

create table private.quota_buckets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  entitlement_snapshot_id uuid not null,
  meter text not null,
  period_start timestamptz not null,
  period_end timestamptz not null,
  limit_quantity numeric(20, 6) not null,
  reserved_quantity numeric(20, 6) not null default 0,
  committed_quantity numeric(20, 6) not null default 0,
  status text not null default 'open',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint quota_buckets_id_user_id_meter_key unique (id, user_id, meter),
  constraint quota_buckets_user_id_meter_period_start_key
    unique (user_id, meter, period_start),
  constraint quota_buckets_entitlement_owner_fkey
    foreign key (entitlement_snapshot_id, user_id)
    references private.entitlement_snapshots (id, user_id)
    on delete cascade,
  constraint quota_buckets_meter_check
    check (
      meter = lower(btrim(meter))
      and meter ~ '^[a-z0-9][a-z0-9._:-]{0,127}$'
    ),
  constraint quota_buckets_period_check
    check (period_end > period_start),
  constraint quota_buckets_limit_quantity_check
    check (limit_quantity >= 0),
  constraint quota_buckets_reserved_quantity_check
    check (reserved_quantity >= 0),
  constraint quota_buckets_committed_quantity_check
    check (committed_quantity >= 0),
  constraint quota_buckets_accounted_quantity_check
    check (reserved_quantity + committed_quantity <= limit_quantity),
  constraint quota_buckets_status_check
    check (status in ('open', 'closed', 'expired'))
);

comment on table private.quota_buckets is
  'Per-user, per-meter period counters. M014 owns the lock-safe counter transitions.';

create table private.usage_reservations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  quota_bucket_id uuid not null,
  meter text not null,
  event_id uuid not null default gen_random_uuid(),
  idempotency_key text not null,
  reserved_quantity numeric(20, 6) not null,
  status text not null default 'reserved',
  reserved_at timestamptz not null default now(),
  expires_at timestamptz not null,
  committed_at timestamptz,
  released_at timestamptz,
  release_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint usage_reservations_id_user_id_meter_key
    unique (id, user_id, meter),
  constraint usage_reservations_event_id_key unique (event_id),
  constraint usage_reservations_user_id_idempotency_key_key
    unique (user_id, idempotency_key),
  constraint usage_reservations_quota_bucket_owner_meter_fkey
    foreign key (quota_bucket_id, user_id, meter)
    references private.quota_buckets (id, user_id, meter)
    on delete cascade,
  constraint usage_reservations_idempotency_key_check
    check (
      idempotency_key = btrim(idempotency_key)
      and char_length(idempotency_key) between 1 and 512
    ),
  constraint usage_reservations_reserved_quantity_check
    check (reserved_quantity > 0),
  constraint usage_reservations_status_check
    check (status in ('reserved', 'committed', 'released', 'expired')),
  constraint usage_reservations_expiry_check
    check (expires_at > reserved_at),
  constraint usage_reservations_transition_timestamps_check
    check (
      (status = 'reserved' and committed_at is null and released_at is null)
      or (status = 'committed' and committed_at is not null and released_at is null)
      or (status in ('released', 'expired') and committed_at is null and released_at is not null)
    ),
  constraint usage_reservations_committed_at_check
    check (committed_at is null or committed_at >= reserved_at),
  constraint usage_reservations_released_at_check
    check (released_at is null or released_at >= reserved_at),
  constraint usage_reservations_release_reason_check
    check (
      (status in ('released', 'expired')) = (release_reason is not null)
      and (
        release_reason is null
        or (
          release_reason = lower(btrim(release_reason))
          and release_reason ~ '^[a-z0-9][a-z0-9._:-]{0,127}$'
        )
      )
    )
);

comment on table private.usage_reservations is
  'Durable idempotent usage holds. Reservation state changes are made only by the atomic accounting operations introduced in M014.';

create table private.usage_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  reservation_id uuid not null,
  task_id uuid,
  session_id uuid,
  meter text not null,
  idempotency_key text not null,
  actual_quantity numeric(20, 6) not null,
  alterity_receipt_id text,
  billed_amount_micros bigint,
  billed_currency_code text,
  committed_at timestamptz not null default now(),
  settled_at timestamptz,
  created_at timestamptz not null default now(),

  constraint usage_events_id_user_id_key unique (id, user_id),
  constraint usage_events_reservation_id_key unique (reservation_id),
  constraint usage_events_user_id_idempotency_key_key
    unique (user_id, idempotency_key),
  constraint usage_events_reservation_owner_meter_fkey
    foreign key (reservation_id, user_id, meter)
    references private.usage_reservations (id, user_id, meter)
    on delete cascade,
  constraint usage_events_task_owner_fkey
    foreign key (task_id, user_id)
    references private.agent_tasks (id, user_id)
    on delete restrict,
  constraint usage_events_session_owner_fkey
    foreign key (session_id, user_id)
    references private.browser_sessions (id, user_id)
    on delete restrict,
  constraint usage_events_idempotency_key_check
    check (
      idempotency_key = btrim(idempotency_key)
      and char_length(idempotency_key) between 1 and 512
    ),
  constraint usage_events_actual_quantity_check
    check (actual_quantity > 0),
  constraint usage_events_alterity_receipt_id_check
    check (
      alterity_receipt_id is null
      or (
        alterity_receipt_id = btrim(alterity_receipt_id)
        and char_length(alterity_receipt_id) between 1 and 512
      )
    ),
  constraint usage_events_billed_amount_micros_check
    check (billed_amount_micros is null or billed_amount_micros >= 0),
  constraint usage_events_billed_currency_code_check
    check (
      billed_currency_code is null
      or billed_currency_code ~ '^[A-Z]{3}$'
    ),
  constraint usage_events_settlement_check
    check (
      (
        alterity_receipt_id is null
        and billed_amount_micros is null
        and billed_currency_code is null
        and settled_at is null
      )
      or (
        alterity_receipt_id is not null
        and billed_amount_micros is not null
        and billed_currency_code is not null
        and settled_at is not null
        and settled_at >= committed_at
      )
    )
);

comment on table private.usage_events is
  'Append-only actual usage ledger. Only settlement fields may be filled after the initial committed usage record is written.';

create unique index usage_events_alterity_receipt_id_key
  on private.usage_events (alterity_receipt_id)
  where alterity_receipt_id is not null;

create table private.billing_outbox (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  usage_event_id uuid,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  idempotency_key text not null,
  status text not null default 'pending',
  attempt_count integer not null default 0,
  max_attempts integer not null default 12,
  next_attempt_at timestamptz not null default now(),
  last_attempt_at timestamptz,
  locked_at timestamptz,
  lock_expires_at timestamptz,
  delivered_at timestamptz,
  last_error_code text,
  last_error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint billing_outbox_id_user_id_key unique (id, user_id),
  constraint billing_outbox_idempotency_key_key unique (idempotency_key),
  constraint billing_outbox_usage_event_owner_fkey
    foreign key (usage_event_id, user_id)
    references private.usage_events (id, user_id)
    on delete cascade,
  constraint billing_outbox_event_type_check
    check (
      event_type = lower(btrim(event_type))
      and event_type ~ '^[a-z][a-z0-9._:-]{0,127}$'
    ),
  constraint billing_outbox_payload_object_check
    check (jsonb_typeof(payload) = 'object'),
  constraint billing_outbox_idempotency_key_check
    check (
      idempotency_key = btrim(idempotency_key)
      and char_length(idempotency_key) between 1 and 512
    ),
  constraint billing_outbox_status_check
    check (
      status in (
        'pending',
        'processing',
        'retrying',
        'delivered',
        'dead_letter',
        'cancelled'
      )
    ),
  constraint billing_outbox_attempt_count_check
    check (attempt_count between 0 and max_attempts),
  constraint billing_outbox_max_attempts_check
    check (max_attempts between 1 and 100),
  constraint billing_outbox_last_attempt_at_check
    check (last_attempt_at is null or last_attempt_at >= created_at),
  constraint billing_outbox_next_attempt_at_check
    check (next_attempt_at >= created_at),
  constraint billing_outbox_delivery_state_check
    check (
      (
        status = 'processing'
        and attempt_count >= 1
        and locked_at is not null
        and lock_expires_at is not null
        and lock_expires_at > locked_at
        and delivered_at is null
      )
      or (
        status = 'retrying'
        and attempt_count >= 1
        and last_attempt_at is not null
        and next_attempt_at > last_attempt_at
        and locked_at is null
        and lock_expires_at is null
        and delivered_at is null
      )
      or (
        status = 'delivered'
        and last_attempt_at is not null
        and delivered_at is not null
        and delivered_at >= last_attempt_at
        and locked_at is null
        and lock_expires_at is null
      )
      or (
        status = 'dead_letter'
        and attempt_count >= 1
        and last_attempt_at is not null
        and locked_at is null
        and lock_expires_at is null
        and delivered_at is null
      )
      or (
        status in ('pending', 'cancelled')
        and locked_at is null
        and lock_expires_at is null
        and delivered_at is null
      )
    ),
  constraint billing_outbox_last_error_code_check
    check (
      last_error_code is null
      or (
        last_error_code = lower(btrim(last_error_code))
        and last_error_code ~ '^[a-z0-9][a-z0-9._:-]{0,127}$'
      )
    ),
  constraint billing_outbox_last_error_message_check
    check (
      last_error_message is null
      or (
        last_error_message = btrim(last_error_message)
        and char_length(last_error_message) between 1 and 2000
      )
    )
);

comment on table private.billing_outbox is
  'Durable, idempotent server-only delivery ledger for billing events. Payloads must contain only operational billing data.';

-- Every application-facing ownership lookup starts with user_id. The final
-- partial index is intentionally global because the retry worker claims due
-- messages across users.
create index entitlement_snapshots_user_id_refreshed_at_idx
  on private.entitlement_snapshots (user_id, refreshed_at desc);

create index entitlement_snapshots_user_id_valid_until_idx
  on private.entitlement_snapshots (user_id, valid_until);

create index quota_buckets_user_id_meter_period_end_idx
  on private.quota_buckets (user_id, meter, period_end);

create index quota_buckets_user_id_status_period_end_idx
  on private.quota_buckets (user_id, status, period_end);

create index usage_reservations_user_id_status_expires_at_idx
  on private.usage_reservations (user_id, status, expires_at);

create index usage_reservations_user_id_quota_bucket_created_at_idx
  on private.usage_reservations (user_id, quota_bucket_id, created_at desc);

create index usage_events_user_id_meter_committed_at_idx
  on private.usage_events (user_id, meter, committed_at desc);

create index usage_events_user_id_task_id_committed_at_idx
  on private.usage_events (user_id, task_id, committed_at desc)
  where task_id is not null;

create index usage_events_user_id_session_id_committed_at_idx
  on private.usage_events (user_id, session_id, committed_at desc)
  where session_id is not null;

create index billing_outbox_user_id_status_next_attempt_at_idx
  on private.billing_outbox (user_id, status, next_attempt_at);

create index billing_outbox_user_id_usage_event_id_idx
  on private.billing_outbox (user_id, usage_event_id)
  where usage_event_id is not null;

create index billing_outbox_dispatch_due_idx
  on private.billing_outbox (status, next_attempt_at)
  where status in ('pending', 'retrying');

-- Private billing state is a server-only interface. Grants and RLS are kept
-- separate so client roles fail before any policy evaluation.
revoke all privileges on schema private from public, anon, authenticated;

revoke all privileges on table
  private.billing_links,
  private.entitlement_snapshots,
  private.quota_buckets,
  private.usage_reservations,
  private.usage_events,
  private.billing_outbox
  from public, anon, authenticated, service_role;

grant usage on schema private to service_role;

grant select, insert, update, delete
  on table
    private.billing_links,
    private.entitlement_snapshots,
    private.quota_buckets,
    private.usage_reservations,
    private.billing_outbox
  to service_role;

-- Usage consumption itself is append-only. A worker may later attach only the
-- provider settlement receipt and amount; it cannot rewrite the measured use.
grant select, insert
  on table private.usage_events
  to service_role;

grant update (
  alterity_receipt_id,
  billed_amount_micros,
  billed_currency_code,
  settled_at
) on table private.usage_events to service_role;

alter table private.billing_links enable row level security;
alter table private.billing_links force row level security;

alter table private.entitlement_snapshots enable row level security;
alter table private.entitlement_snapshots force row level security;

alter table private.quota_buckets enable row level security;
alter table private.quota_buckets force row level security;

alter table private.usage_reservations enable row level security;
alter table private.usage_reservations force row level security;

alter table private.usage_events enable row level security;
alter table private.usage_events force row level security;

alter table private.billing_outbox enable row level security;
alter table private.billing_outbox force row level security;

create policy billing_links_service_role_all
  on private.billing_links
  for all
  to service_role
  using (true)
  with check (true);

create policy entitlement_snapshots_service_role_all
  on private.entitlement_snapshots
  for all
  to service_role
  using (true)
  with check (true);

create policy quota_buckets_service_role_all
  on private.quota_buckets
  for all
  to service_role
  using (true)
  with check (true);

create policy usage_reservations_service_role_all
  on private.usage_reservations
  for all
  to service_role
  using (true)
  with check (true);

create policy usage_events_service_role_select
  on private.usage_events
  for select
  to service_role
  using (true);

create policy usage_events_service_role_insert
  on private.usage_events
  for insert
  to service_role
  with check (true);

create policy usage_events_service_role_update_settlement
  on private.usage_events
  for update
  to service_role
  using (true)
  with check (true);

create policy billing_outbox_service_role_all
  on private.billing_outbox
  for all
  to service_role
  using (true)
  with check (true);

create trigger billing_links_set_updated_at
  before update on private.billing_links
  for each row execute function private.set_updated_at();

create trigger quota_buckets_set_updated_at
  before update on private.quota_buckets
  for each row execute function private.set_updated_at();

create trigger usage_reservations_set_updated_at
  before update on private.usage_reservations
  for each row execute function private.set_updated_at();

create trigger billing_outbox_set_updated_at
  before update on private.billing_outbox
  for each row execute function private.set_updated_at();

commit;
