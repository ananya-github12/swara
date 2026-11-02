-- Round 5 / M020: the only Swara gateway to durable PGMQ queues.
--
-- Queue messages intentionally contain only opaque routing identifiers.  A
-- worker must load any job-specific state from the private database after it
-- has claimed a message; raw documents, browser observations, credentials,
-- provider payloads, and user-entered content never enter PGMQ.

begin;

do $roles$
begin
  if not exists (
    select 1
    from pg_catalog.pg_roles
    where rolname = 'swara_api_runtime'
  ) or not exists (
    select 1
    from pg_catalog.pg_roles
    where rolname = 'swara_worker_runtime'
  ) then
    raise exception using
      errcode = '55000',
      message = 'M020 requires the M018 Swara runtime permission groups';
  end if;
end;
$roles$;

create table private.worker_job_runs (
  queue_name text not null,
  idempotency_key text not null,
  message_id bigint not null,
  envelope jsonb not null,
  status text not null default 'queued',
  attempt_count integer not null default 0,
  lease_expires_at timestamptz,
  completed_at timestamptz,
  archived_at timestamptz,
  last_error_code text,
  correlation_id uuid not null,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),

  constraint worker_job_runs_pkey primary key (queue_name, idempotency_key),
  constraint worker_job_runs_queue_message_key unique (queue_name, message_id),
  constraint worker_job_runs_queue_name_check check (
    queue_name in (
      'vault-ingest',
      'ocr-fallback',
      'generate-embeddings',
      'billing-outbox',
      'usage-reconciliation',
      'account-export',
      'account-deletion',
      'artifact-retention'
    )
  ),
  constraint worker_job_runs_idempotency_key_check check (
    idempotency_key = pg_catalog.btrim(idempotency_key)
    and pg_catalog.char_length(idempotency_key) between 8 and 160
    and idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$'
  ),
  constraint worker_job_runs_envelope_check check (
    pg_catalog.jsonb_typeof(envelope) = 'object'
  ),
  constraint worker_job_runs_status_check check (
    status in ('queued', 'leased', 'completed', 'dead_lettered')
  ),
  constraint worker_job_runs_attempt_count_check check (
    attempt_count between 0 and 5
  ),
  constraint worker_job_runs_state_check check (
    (status = 'queued'
      and lease_expires_at is null
      and completed_at is null
      and archived_at is null)
    or (status = 'leased'
      and lease_expires_at is not null
      and completed_at is null
      and archived_at is null)
    or (status in ('completed', 'dead_lettered')
      and lease_expires_at is null
      and completed_at is not null)
  ),
  constraint worker_job_runs_error_code_check check (
    last_error_code is null
    or (
      pg_catalog.char_length(last_error_code) between 1 and 64
      and last_error_code ~ '^[a-z0-9][a-z0-9._-]*$'
    )
  ),
  constraint worker_job_runs_dead_letter_error_check check (
    status <> 'dead_lettered' or last_error_code is not null
  )
);

create index worker_job_runs_active_lease_idx
  on private.worker_job_runs (status, lease_expires_at)
  where status = 'leased';

create table private.worker_dead_letters (
  queue_name text not null,
  message_id bigint not null,
  idempotency_key text not null,
  envelope jsonb not null,
  payload_sha256 text not null,
  final_error_code text not null,
  correlation_id uuid not null,
  attempt_count integer not null,
  created_at timestamptz not null default pg_catalog.now(),

  constraint worker_dead_letters_pkey primary key (queue_name, message_id),
  constraint worker_dead_letters_run_fkey foreign key (queue_name, idempotency_key)
    references private.worker_job_runs (queue_name, idempotency_key)
    on delete restrict,
  constraint worker_dead_letters_queue_name_check check (
    queue_name in (
      'vault-ingest',
      'ocr-fallback',
      'generate-embeddings',
      'billing-outbox',
      'usage-reconciliation',
      'account-export',
      'account-deletion',
      'artifact-retention'
    )
  ),
  constraint worker_dead_letters_idempotency_key_check check (
    idempotency_key = pg_catalog.btrim(idempotency_key)
    and pg_catalog.char_length(idempotency_key) between 8 and 160
    and idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$'
  ),
  constraint worker_dead_letters_envelope_check check (
    pg_catalog.jsonb_typeof(envelope) = 'object'
  ),
  constraint worker_dead_letters_payload_sha256_check check (
    payload_sha256 = pg_catalog.lower(payload_sha256)
    and payload_sha256 ~ '^[0-9a-f]{64}$'
  ),
  constraint worker_dead_letters_error_code_check check (
    pg_catalog.char_length(final_error_code) between 1 and 64
    and final_error_code ~ '^[a-z0-9][a-z0-9._-]*$'
  ),
  constraint worker_dead_letters_attempt_count_check check (
    attempt_count = 5
  )
);

alter table private.worker_job_runs enable row level security;
alter table private.worker_dead_letters enable row level security;

revoke all privileges on table private.worker_job_runs, private.worker_dead_letters
  from public, anon, authenticated, service_role,
       swara_api_runtime, swara_worker_runtime;

-- The allowlist is deliberately repeated in the table constraints above.  It
-- prevents a future DML mistake from widening this dynamic PGMQ boundary.
create or replace function private.assert_swara_queue(p_queue_name text)
returns void
language plpgsql
security invoker
set search_path = ''
as $function$
begin
  if p_queue_name is null or p_queue_name not in (
    'vault-ingest',
    'ocr-fallback',
    'generate-embeddings',
    'billing-outbox',
    'usage-reconciliation',
    'account-export',
    'account-deletion',
    'artifact-retention'
  ) then
    raise exception using
      errcode = '22023',
      message = 'Unknown Swara queue';
  end if;
end;
$function$;

create or replace function private.assert_queue_idempotency_key(
  p_idempotency_key text
)
returns void
language plpgsql
security invoker
set search_path = ''
as $function$
begin
  if p_idempotency_key is null
     or p_idempotency_key <> pg_catalog.btrim(p_idempotency_key)
     or pg_catalog.char_length(p_idempotency_key) not between 8 and 160
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$' then
    raise exception using
      errcode = '22023',
      message = 'Queue idempotency key is invalid';
  end if;
end;
$function$;

-- An envelope has exactly five primitive fields.  This closed schema is what
-- rejects unknown nested content as well as explicit document, transcript,
-- DOM, filled-value, provider-payload, and secret keys.
create or replace function private.assert_queue_envelope(p_envelope jsonb)
returns void
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  v_job_type text;
  v_job_id text;
  v_idempotency_key text;
  v_correlation_id text;
begin
  if p_envelope is null
     or pg_catalog.jsonb_typeof(p_envelope) is distinct from 'object' then
    raise exception using
      errcode = '22023',
      message = 'Queue envelope must be a JSON object';
  end if;

  if pg_catalog.octet_length(p_envelope::text) > 4096 then
    raise exception using
      errcode = '22023',
      message = 'Queue envelope exceeds permitted size';
  end if;

  if not (p_envelope ?& array[
    'schema_version',
    'job_type',
    'job_id',
    'idempotency_key',
    'correlation_id'
  ])
     or exists (
       select 1
       from pg_catalog.jsonb_object_keys(p_envelope) as field_name(name)
       where field_name.name not in (
         'schema_version',
         'job_type',
         'job_id',
         'idempotency_key',
         'correlation_id'
       )
     ) then
    raise exception using
      errcode = '22023',
      message = 'Queue envelope contains unsupported fields';
  end if;

  if pg_catalog.jsonb_typeof(p_envelope -> 'schema_version') is distinct from 'number'
     or p_envelope ->> 'schema_version' is distinct from '1' then
    raise exception using
      errcode = '22023',
      message = 'Queue envelope schema version is invalid';
  end if;

  if pg_catalog.jsonb_typeof(p_envelope -> 'job_type') is distinct from 'string'
     or pg_catalog.jsonb_typeof(p_envelope -> 'job_id') is distinct from 'string'
     or pg_catalog.jsonb_typeof(p_envelope -> 'idempotency_key') is distinct from 'string'
     or pg_catalog.jsonb_typeof(p_envelope -> 'correlation_id') is distinct from 'string' then
    raise exception using
      errcode = '22023',
      message = 'Queue envelope fields are invalid';
  end if;

  v_job_type := p_envelope ->> 'job_type';
  v_job_id := p_envelope ->> 'job_id';
  v_idempotency_key := p_envelope ->> 'idempotency_key';
  v_correlation_id := p_envelope ->> 'correlation_id';

  if pg_catalog.char_length(v_job_type) not between 1 and 80
     or v_job_type !~ '^[a-z][a-z0-9._-]*$' then
    raise exception using
      errcode = '22023',
      message = 'Queue job type is invalid';
  end if;

  if v_job_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     or v_correlation_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception using
      errcode = '22023',
      message = 'Queue identifiers must be UUIDs';
  end if;

  perform private.assert_queue_idempotency_key(v_idempotency_key);
end;
$function$;

create or replace function private.enqueue_job(
  p_queue_name text,
  p_envelope jsonb,
  p_delay_seconds integer default 0
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_idempotency_key text;
  v_message_id bigint;
  v_existing_message_id bigint;
  v_existing_envelope jsonb;
begin
  perform private.assert_swara_queue(p_queue_name);
  perform private.assert_queue_envelope(p_envelope);

  if p_delay_seconds is null or p_delay_seconds not between 0 and 3600 then
    raise exception using
      errcode = '22023',
      message = 'Queue delay is outside the permitted range';
  end if;

  v_idempotency_key := p_envelope ->> 'idempotency_key';

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'swara-queue-enqueue:' || p_queue_name || ':' || v_idempotency_key,
      8072026::bigint
    )
  );

  select job.message_id, job.envelope
    into v_existing_message_id, v_existing_envelope
    from private.worker_job_runs as job
   where job.queue_name = p_queue_name
     and job.idempotency_key = v_idempotency_key
   for update;

  if found then
    if v_existing_envelope is distinct from p_envelope then
      raise exception using
        errcode = '22023',
        message = 'Queue idempotency key is bound to a different envelope';
    end if;

    return v_existing_message_id;
  end if;

  select pgmq.send(p_queue_name, p_envelope, p_delay_seconds)
    into v_message_id;

  if v_message_id is null then
    raise exception using
      errcode = '55000',
      message = 'Queue message could not be enqueued';
  end if;

  insert into private.worker_job_runs (
    queue_name,
    idempotency_key,
    message_id,
    envelope,
    correlation_id
  )
  values (
    p_queue_name,
    v_idempotency_key,
    v_message_id,
    p_envelope,
    (p_envelope ->> 'correlation_id')::uuid
  );

  return v_message_id;
end;
$function$;

create or replace function private.read_jobs(
  p_queue_name text,
  p_visibility_seconds integer,
  p_quantity integer
)
returns table (
  message_id bigint,
  read_count integer,
  enqueued_at timestamptz,
  visibility_expires_at timestamptz,
  envelope jsonb
)
language plpgsql
security definer
set search_path = ''
as $function$
begin
  perform private.assert_swara_queue(p_queue_name);

  if p_visibility_seconds is null or p_visibility_seconds not between 1 and 900 then
    raise exception using
      errcode = '22023',
      message = 'Queue visibility timeout is outside the permitted range';
  end if;

  if p_quantity is null or p_quantity not between 1 and 25 then
    raise exception using
      errcode = '22023',
      message = 'Queue read quantity is outside the permitted range';
  end if;

  -- PGMQ 1.5.1 exposes read(text, integer, integer, jsonb).  The condition
  -- keeps pre-gateway/legacy payloads out of workers even if an operator has
  -- manually inserted a message outside this boundary.
  return query
  select
    queued.msg_id,
    queued.read_ct,
    queued.enqueued_at,
    queued.vt,
    queued.message
  from pgmq.read(
    p_queue_name,
    p_visibility_seconds,
    p_quantity,
    pg_catalog.jsonb_build_object('schema_version', 1)
  ) as queued
  join private.worker_job_runs as job
    on job.queue_name = p_queue_name
   and job.message_id = queued.msg_id
   and job.envelope = queued.message
  where job.status in ('queued', 'leased')
    and job.archived_at is null;
end;
$function$;

create or replace function private.extend_job_visibility(
  p_queue_name text,
  p_message_id bigint,
  p_idempotency_key text,
  p_visibility_seconds integer
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_status text;
  v_lease_expires_at timestamptz;
  v_message_id bigint;
  v_updated_count integer;
begin
  perform private.assert_swara_queue(p_queue_name);
  perform private.assert_queue_idempotency_key(p_idempotency_key);

  if p_message_id is null or p_message_id < 1 then
    raise exception using
      errcode = '22023',
      message = 'Queue message identifier is invalid';
  end if;

  -- Zero is a bounded, explicit retry release.  Positive values extend the
  -- active lease; neither mode can hide a message for more than 15 minutes.
  if p_visibility_seconds is null or p_visibility_seconds not between 0 and 900 then
    raise exception using
      errcode = '22023',
      message = 'Queue visibility timeout is outside the permitted range';
  end if;

  select job.status, job.lease_expires_at, job.message_id
    into v_status, v_lease_expires_at, v_message_id
    from private.worker_job_runs as job
   where job.queue_name = p_queue_name
     and job.idempotency_key = p_idempotency_key
   for update;

  if not found or v_message_id is distinct from p_message_id then
    raise exception using
      errcode = '22023',
      message = 'Queue job is not available';
  end if;

  if v_status is distinct from 'leased'
     or v_lease_expires_at is null
     or v_lease_expires_at <= pg_catalog.clock_timestamp() then
    return false;
  end if;

  select pg_catalog.count(*)::integer
    into v_updated_count
    from pgmq.set_vt(p_queue_name, p_message_id, p_visibility_seconds);

  if v_updated_count <> 1 then
    raise exception using
      errcode = '55000',
      message = 'Queue visibility could not be updated';
  end if;

  update private.worker_job_runs as job
     set lease_expires_at = pg_catalog.clock_timestamp()
                              + pg_catalog.make_interval(secs => p_visibility_seconds),
         updated_at = pg_catalog.clock_timestamp()
   where job.queue_name = p_queue_name
     and job.idempotency_key = p_idempotency_key;

  return true;
end;
$function$;

create or replace function private.dead_letter_job(
  p_queue_name text,
  p_message_id bigint,
  p_idempotency_key text,
  p_error_code text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_status text;
  v_run_message_id bigint;
  v_envelope jsonb;
  v_correlation_id uuid;
  v_attempt_count integer;
  v_archived_at timestamptz;
  v_archived boolean;
begin
  perform private.assert_swara_queue(p_queue_name);
  perform private.assert_queue_idempotency_key(p_idempotency_key);

  if p_message_id is null or p_message_id < 1 then
    raise exception using
      errcode = '22023',
      message = 'Queue message identifier is invalid';
  end if;

  if p_error_code is null
     or pg_catalog.char_length(p_error_code) not between 1 and 64
     or p_error_code !~ '^[a-z0-9][a-z0-9._-]*$' then
    raise exception using
      errcode = '22023',
      message = 'Queue error code is invalid';
  end if;

  select
    job.status,
    job.message_id,
    job.envelope,
    job.correlation_id,
    job.attempt_count,
    job.archived_at
  into
    v_status,
    v_run_message_id,
    v_envelope,
    v_correlation_id,
    v_attempt_count,
    v_archived_at
  from private.worker_job_runs as job
  where job.queue_name = p_queue_name
    and job.idempotency_key = p_idempotency_key
  for update;

  if not found or v_run_message_id is distinct from p_message_id then
    raise exception using
      errcode = '22023',
      message = 'Queue job is not available';
  end if;

  if v_status = 'dead_lettered' and v_archived_at is not null then
    return true;
  end if;

  if v_status is distinct from 'leased' or v_attempt_count < 5 then
    raise exception using
      errcode = '22023',
      message = 'Queue job has not reached the dead-letter attempt limit';
  end if;

  -- Persist the durable terminal state before touching PGMQ.  PostgreSQL
  -- transactions make the state change and archive atomic on a failure.
  insert into private.worker_dead_letters (
    queue_name,
    message_id,
    idempotency_key,
    envelope,
    payload_sha256,
    final_error_code,
    correlation_id,
    attempt_count
  )
  values (
    p_queue_name,
    p_message_id,
    p_idempotency_key,
    v_envelope,
    pg_catalog.encode(
      extensions.digest(
        pg_catalog.convert_to(v_envelope::text, 'UTF8'),
        'sha256'
      ),
      'hex'
    ),
    p_error_code,
    v_correlation_id,
    v_attempt_count
  )
  on conflict (queue_name, message_id) do nothing;

  update private.worker_job_runs as job
     set status = 'dead_lettered',
         lease_expires_at = null,
         completed_at = pg_catalog.clock_timestamp(),
         last_error_code = p_error_code,
         updated_at = pg_catalog.clock_timestamp()
   where job.queue_name = p_queue_name
     and job.idempotency_key = p_idempotency_key;

  select pgmq.archive(p_queue_name, p_message_id)
    into v_archived;

  if v_archived is distinct from true then
    raise exception using
      errcode = '55000',
      message = 'Queue message could not be archived';
  end if;

  update private.worker_job_runs as job
     set archived_at = pg_catalog.clock_timestamp(),
         updated_at = pg_catalog.clock_timestamp()
   where job.queue_name = p_queue_name
     and job.idempotency_key = p_idempotency_key;

  return true;
end;
$function$;

create or replace function private.claim_job(
  p_queue_name text,
  p_message_id bigint,
  p_idempotency_key text,
  p_lease_seconds integer
)
returns text
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_status text;
  v_run_message_id bigint;
  v_lease_expires_at timestamptz;
  v_attempt_count integer;
  v_updated_count integer;
begin
  perform private.assert_swara_queue(p_queue_name);
  perform private.assert_queue_idempotency_key(p_idempotency_key);

  if p_message_id is null or p_message_id < 1 then
    raise exception using
      errcode = '22023',
      message = 'Queue message identifier is invalid';
  end if;

  if p_lease_seconds is null or p_lease_seconds not between 1 and 900 then
    raise exception using
      errcode = '22023',
      message = 'Queue lease is outside the permitted range';
  end if;

  select
    job.status,
    job.message_id,
    job.lease_expires_at,
    job.attempt_count
  into
    v_status,
    v_run_message_id,
    v_lease_expires_at,
    v_attempt_count
  from private.worker_job_runs as job
  where job.queue_name = p_queue_name
    and job.idempotency_key = p_idempotency_key
  for update;

  if not found or v_run_message_id is distinct from p_message_id then
    raise exception using
      errcode = '22023',
      message = 'Queue job is not available';
  end if;

  if v_status in ('completed', 'dead_lettered') then
    return 'completed';
  end if;

  if v_status = 'leased'
     and v_lease_expires_at > pg_catalog.clock_timestamp() then
    return 'busy';
  end if;

  -- A worker may crash after its fifth claim.  The next visibility delivery
  -- closes that loop rather than permitting an unbounded sixth execution.
  if v_attempt_count >= 5 then
    perform private.dead_letter_job(
      p_queue_name,
      p_message_id,
      p_idempotency_key,
      'max_attempts_exceeded'
    );
    return 'completed';
  end if;

  select pg_catalog.count(*)::integer
    into v_updated_count
    from pgmq.set_vt(p_queue_name, p_message_id, p_lease_seconds);

  if v_updated_count <> 1 then
    raise exception using
      errcode = '55000',
      message = 'Queue lease could not be claimed';
  end if;

  update private.worker_job_runs as job
     set status = 'leased',
         attempt_count = v_attempt_count + 1,
         lease_expires_at = pg_catalog.clock_timestamp()
                              + pg_catalog.make_interval(secs => p_lease_seconds),
         updated_at = pg_catalog.clock_timestamp()
   where job.queue_name = p_queue_name
     and job.idempotency_key = p_idempotency_key;

  return 'claimed';
end;
$function$;

create or replace function private.archive_job(
  p_queue_name text,
  p_message_id bigint,
  p_idempotency_key text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_status text;
  v_run_message_id bigint;
  v_lease_expires_at timestamptz;
  v_archived_at timestamptz;
  v_archived boolean;
begin
  perform private.assert_swara_queue(p_queue_name);
  perform private.assert_queue_idempotency_key(p_idempotency_key);

  if p_message_id is null or p_message_id < 1 then
    raise exception using
      errcode = '22023',
      message = 'Queue message identifier is invalid';
  end if;

  select
    job.status,
    job.message_id,
    job.lease_expires_at,
    job.archived_at
  into
    v_status,
    v_run_message_id,
    v_lease_expires_at,
    v_archived_at
  from private.worker_job_runs as job
  where job.queue_name = p_queue_name
    and job.idempotency_key = p_idempotency_key
  for update;

  if not found or v_run_message_id is distinct from p_message_id then
    raise exception using
      errcode = '22023',
      message = 'Queue job is not available';
  end if;

  if v_archived_at is not null then
    return true;
  end if;

  if v_status = 'leased' then
    if v_lease_expires_at is null
       or v_lease_expires_at <= pg_catalog.clock_timestamp() then
      raise exception using
        errcode = '22023',
        message = 'Queue job is not actively leased';
    end if;

    -- This is the durable completion acknowledgement.  Callers must commit
    -- their job's own database state before acknowledging through this
    -- function; PGMQ archival happens only after this terminal row exists.
    update private.worker_job_runs as job
       set status = 'completed',
           lease_expires_at = null,
           completed_at = pg_catalog.clock_timestamp(),
           updated_at = pg_catalog.clock_timestamp()
     where job.queue_name = p_queue_name
       and job.idempotency_key = p_idempotency_key;
  elsif v_status not in ('completed', 'dead_lettered') then
    raise exception using
      errcode = '22023',
      message = 'Queue job is not ready to archive';
  end if;

  select pgmq.archive(p_queue_name, p_message_id)
    into v_archived;

  if v_archived is distinct from true then
    raise exception using
      errcode = '55000',
      message = 'Queue message could not be archived';
  end if;

  update private.worker_job_runs as job
     set archived_at = pg_catalog.clock_timestamp(),
         updated_at = pg_catalog.clock_timestamp()
   where job.queue_name = p_queue_name
     and job.idempotency_key = p_idempotency_key;

  return true;
end;
$function$;

-- M017's dispatcher predates the closed message envelope.  Retain its
-- operational allowlist and schedule contract, but route it through M020 so
-- Cron does not bypass the ledger or reintroduce untyped messages.
create or replace function private.enqueue_maintenance_dispatch(
  p_queue_name text,
  p_operation text,
  p_max_items integer,
  p_interval_seconds integer
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_expected_queue_name text;
  v_expected_interval_seconds integer;
  v_max_allowed_items integer;
  v_window_start timestamptz;
  v_idempotency_key text;
  v_job_digest text;
  v_correlation_digest text;
  v_job_id uuid;
  v_correlation_id uuid;
begin
  case p_operation
    when 'retry_due_billing_outbox' then
      v_expected_queue_name := 'billing-outbox';
      v_expected_interval_seconds := 60;
      v_max_allowed_items := 50;
    when 'release_expired_usage_reservations' then
      v_expected_queue_name := 'usage-reconciliation';
      v_expected_interval_seconds := 300;
      v_max_allowed_items := 100;
    when 'detect_stuck_vault_ingestion' then
      v_expected_queue_name := 'vault-ingest';
      v_expected_interval_seconds := 600;
      v_max_allowed_items := 50;
    when 'refresh_near_expiry_entitlements' then
      v_expected_queue_name := 'billing-outbox';
      v_expected_interval_seconds := 900;
      v_max_allowed_items := 50;
    when 'purge_expired_task_artifacts' then
      v_expected_queue_name := 'artifact-retention';
      v_expected_interval_seconds := 3600;
      v_max_allowed_items := 100;
    when 'reconcile_usage' then
      v_expected_queue_name := 'usage-reconciliation';
      v_expected_interval_seconds := 86400;
      v_max_allowed_items := 100;
    when 'cleanup_expired_account_exports' then
      v_expected_queue_name := 'account-export';
      v_expected_interval_seconds := 86400;
      v_max_allowed_items := 100;
    else
      raise exception using
        errcode = '22023',
        message = 'Unknown Swara maintenance dispatch operation';
  end case;

  if p_queue_name is distinct from v_expected_queue_name
     or p_interval_seconds is distinct from v_expected_interval_seconds
     or p_max_items is null
     or p_max_items < 1
     or p_max_items > v_max_allowed_items then
    raise exception using
      errcode = '22023',
      message = 'Invalid Swara maintenance dispatch contract';
  end if;

  if not pg_catalog.pg_try_advisory_xact_lock(
    pg_catalog.hashtextextended(
      pg_catalog.format('swara-maintenance-dispatch:%s', p_operation),
      0::bigint
    )
  ) then
    return null;
  end if;

  v_window_start := pg_catalog.to_timestamp(
    (
      pg_catalog.floor(
        extract(epoch from pg_catalog.clock_timestamp()) / p_interval_seconds
      ) * p_interval_seconds
    )::double precision
  );

  v_idempotency_key := pg_catalog.format(
    'swara-maintenance:%s:%s',
    p_operation,
    pg_catalog.to_char(
      v_window_start at time zone 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS"Z"'
    )
  );

  v_job_digest := pg_catalog.md5('job:' || v_idempotency_key);
  v_correlation_digest := pg_catalog.md5('correlation:' || v_idempotency_key);
  v_job_id := (
    pg_catalog.substr(v_job_digest, 1, 8) || '-'
    || pg_catalog.substr(v_job_digest, 9, 4) || '-'
    || pg_catalog.substr(v_job_digest, 13, 4) || '-'
    || pg_catalog.substr(v_job_digest, 17, 4) || '-'
    || pg_catalog.substr(v_job_digest, 21, 12)
  )::uuid;
  v_correlation_id := (
    pg_catalog.substr(v_correlation_digest, 1, 8) || '-'
    || pg_catalog.substr(v_correlation_digest, 9, 4) || '-'
    || pg_catalog.substr(v_correlation_digest, 13, 4) || '-'
    || pg_catalog.substr(v_correlation_digest, 17, 4) || '-'
    || pg_catalog.substr(v_correlation_digest, 21, 12)
  )::uuid;

  return private.enqueue_job(
    p_queue_name,
    pg_catalog.jsonb_build_object(
      'schema_version', 1,
      'job_type', 'maintenance.' || p_operation,
      'job_id', v_job_id::text,
      'idempotency_key', v_idempotency_key,
      'correlation_id', v_correlation_id::text
    ),
    0
  );
end;
$function$;

-- M018 closed the legacy broad grants; repeat the PGMQ revokes after all
-- previous queue-creating migrations so this is the final ACL layer.
revoke all privileges on schema pgmq
  from public, anon, authenticated, service_role,
       swara_api_runtime, swara_worker_runtime;
revoke all privileges on all tables in schema pgmq
  from public, anon, authenticated, service_role,
       swara_api_runtime, swara_worker_runtime;
revoke all privileges on all sequences in schema pgmq
  from public, anon, authenticated, service_role,
       swara_api_runtime, swara_worker_runtime;
revoke execute on all functions in schema pgmq
  from public, anon, authenticated, service_role,
       swara_api_runtime, swara_worker_runtime;

do $pgmq_public$
begin
  if exists (
    select 1
    from pg_catalog.pg_namespace
    where nspname = 'pgmq_public'
  ) then
    execute 'revoke all privileges on schema pgmq_public from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime';
    execute 'revoke all privileges on all tables in schema pgmq_public from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime';
    execute 'revoke all privileges on all sequences in schema pgmq_public from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime';
    execute 'revoke execute on all functions in schema pgmq_public from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime';
  end if;
end;
$pgmq_public$;

revoke all privileges on function private.assert_swara_queue(text)
  from public, anon, authenticated, service_role,
       swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.assert_queue_idempotency_key(text)
  from public, anon, authenticated, service_role,
       swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.assert_queue_envelope(jsonb)
  from public, anon, authenticated, service_role,
       swara_api_runtime, swara_worker_runtime;

revoke all privileges on function private.enqueue_job(text, jsonb, integer)
  from public, anon, authenticated, service_role,
       swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.read_jobs(text, integer, integer)
  from public, anon, authenticated, service_role,
       swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.claim_job(text, bigint, text, integer)
  from public, anon, authenticated, service_role,
       swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.extend_job_visibility(text, bigint, text, integer)
  from public, anon, authenticated, service_role,
       swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.archive_job(text, bigint, text)
  from public, anon, authenticated, service_role,
       swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.dead_letter_job(text, bigint, text, text)
  from public, anon, authenticated, service_role,
       swara_api_runtime, swara_worker_runtime;

grant usage on schema private to swara_worker_runtime;
grant execute on function private.enqueue_job(text, jsonb, integer)
  to swara_worker_runtime;
grant execute on function private.read_jobs(text, integer, integer)
  to swara_worker_runtime;
grant execute on function private.claim_job(text, bigint, text, integer)
  to swara_worker_runtime;
grant execute on function private.extend_job_visibility(text, bigint, text, integer)
  to swara_worker_runtime;
grant execute on function private.archive_job(text, bigint, text)
  to swara_worker_runtime;
grant execute on function private.dead_letter_job(text, bigint, text, text)
  to swara_worker_runtime;

comment on table private.worker_job_runs is
  'Private PGMQ worker ledger. Queue messages contain only a closed, opaque envelope and terminal archival state.';
comment on table private.worker_dead_letters is
  'Private terminal queue ledger with a safe envelope, SHA-256 payload fingerprint, and bounded error code.';
comment on function private.enqueue_job(text, jsonb, integer) is
  'Security-definer, bounded PGMQ enqueue gateway. Only swara_worker_runtime may execute it.';
comment on function private.read_jobs(text, integer, integer) is
  'Security-definer PGMQ read gateway; uses visibility leases and never pgmq.pop.';
comment on function private.claim_job(text, bigint, text, integer) is
  'Security-definer idempotent worker claim gateway returning claimed, busy, or completed.';
comment on function private.extend_job_visibility(text, bigint, text, integer) is
  'Security-definer PGMQ visibility gateway. Zero seconds explicitly releases a retry lease.';
comment on function private.archive_job(text, bigint, text) is
  'Security-definer completion acknowledgement: archives only after durable terminal state is recorded.';
comment on function private.dead_letter_job(text, bigint, text, text) is
  'Security-definer bounded dead-letter gateway. It archives only after durable terminal state is recorded.';

commit;
