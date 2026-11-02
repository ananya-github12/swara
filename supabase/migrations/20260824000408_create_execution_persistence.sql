-- Round 3C: server-only browser, voice, and agent execution persistence.
--
-- This migration deliberately records redacted operational metadata only. It
-- stores no raw instructions, filled values, browser DOM, provider payloads,
-- credentials, or API keys. M011 owns grants, RLS, and internal checkpoint
-- functions; this migration defines schema and referential integrity only.

begin;

-- `public.devices.id` is already a primary key, but this composite key lets
-- internal tables enforce that a referenced device belongs to the same Swara
-- user as the child row.
alter table public.devices
  add constraint devices_id_user_id_key unique (id, user_id);

create table private.browser_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  status text not null default 'starting',
  interaction_mode text not null default 'browser',
  server_region text,
  extension_version text not null,
  policy_version text not null,
  correlation_id uuid not null default gen_random_uuid(),
  started_at timestamptz not null default now(),
  last_heartbeat_at timestamptz,
  ended_at timestamptz,
  error_code text,
  error_message text,
  retention_expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint browser_sessions_id_user_id_key unique (id, user_id),
  constraint browser_sessions_device_owner_fkey
    foreign key (device_id, user_id)
    references public.devices (id, user_id)
    on delete cascade,
  constraint browser_sessions_status_check
    check (status in ('starting', 'active', 'paused', 'ended', 'failed', 'revoked')),
  constraint browser_sessions_interaction_mode_check
    check (interaction_mode in ('browser', 'voice', 'hybrid')),
  constraint browser_sessions_server_region_check
    check (
      server_region is null
      or (
        server_region = btrim(server_region)
        and char_length(server_region) between 1 and 128
      )
    ),
  constraint browser_sessions_extension_version_check
    check (
      extension_version = btrim(extension_version)
      and char_length(extension_version) between 1 and 128
    ),
  constraint browser_sessions_policy_version_check
    check (
      policy_version = btrim(policy_version)
      and char_length(policy_version) between 1 and 255
    ),
  constraint browser_sessions_last_heartbeat_at_check
    check (last_heartbeat_at is null or last_heartbeat_at >= started_at),
  constraint browser_sessions_ended_at_check
    check (ended_at is null or ended_at >= started_at),
  constraint browser_sessions_terminal_status_check
    check (
      (status in ('ended', 'failed', 'revoked')) = (ended_at is not null)
    ),
  constraint browser_sessions_error_code_check
    check (
      error_code is null
      or (
        error_code = btrim(error_code)
        and char_length(error_code) between 1 and 128
      )
    ),
  constraint browser_sessions_error_message_check
    check (
      error_message is null
      or (
        error_message = btrim(error_message)
        and char_length(error_message) between 1 and 2000
      )
    ),
  constraint browser_sessions_retention_expires_at_check
    check (
      retention_expires_at is null
      or retention_expires_at > started_at
    )
);

comment on table private.browser_sessions is
  'Server-side browser or voice session ledger. Client access is added only in the dedicated security migration.';

create index browser_sessions_user_id_status_started_at_idx
  on private.browser_sessions (user_id, status, started_at desc);

create index browser_sessions_user_id_device_id_started_at_idx
  on private.browser_sessions (user_id, device_id, started_at desc);

create index browser_sessions_user_id_correlation_id_idx
  on private.browser_sessions (user_id, correlation_id);

create index browser_sessions_user_id_retention_expires_at_idx
  on private.browser_sessions (user_id, retention_expires_at)
  where retention_expires_at is not null;

create table private.agent_tasks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  session_id uuid not null,
  task_kind text not null default 'browser',
  source_origin text,
  status text not null default 'queued',
  instruction_summary text,
  instruction_hash text not null,
  history_enabled boolean not null default false,
  policy_version text not null,
  extension_version text not null,
  max_steps integer not null default 25,
  completed_steps integer not null default 0,
  correlation_id uuid not null default gen_random_uuid(),
  error_code text,
  error_message text,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  retention_expires_at timestamptz,
  updated_at timestamptz not null default now(),

  constraint agent_tasks_id_user_id_key unique (id, user_id),
  constraint agent_tasks_session_owner_fkey
    foreign key (session_id, user_id)
    references private.browser_sessions (id, user_id)
    on delete cascade,
  constraint agent_tasks_task_kind_check
    check (task_kind in ('browser', 'voice', 'workflow', 'hybrid')),
  constraint agent_tasks_source_origin_check
    check (
      source_origin is null
      or (
        source_origin = lower(btrim(source_origin))
        and char_length(source_origin) between 1 and 2048
        and source_origin !~ '[[:space:]]'
        and position('?' in source_origin) = 0
        and position('#' in source_origin) = 0
      )
    ),
  constraint agent_tasks_status_check
    check (
      status in (
        'queued',
        'running',
        'paused',
        'cancelled',
        'succeeded',
        'failed',
        'safety_blocked',
        'expired'
      )
    ),
  constraint agent_tasks_instruction_summary_check
    check (
      instruction_summary is null
      or (
        instruction_summary = btrim(instruction_summary)
        and char_length(instruction_summary) between 1 and 2000
      )
    ),
  constraint agent_tasks_instruction_hash_check
    check (
      instruction_hash = lower(instruction_hash)
      and instruction_hash ~ '^[0-9a-f]{64}$'
    ),
  constraint agent_tasks_policy_version_check
    check (
      policy_version = btrim(policy_version)
      and char_length(policy_version) between 1 and 255
    ),
  constraint agent_tasks_extension_version_check
    check (
      extension_version = btrim(extension_version)
      and char_length(extension_version) between 1 and 128
    ),
  constraint agent_tasks_max_steps_check
    check (max_steps between 1 and 1000),
  constraint agent_tasks_completed_steps_check
    check (completed_steps between 0 and max_steps),
  constraint agent_tasks_started_at_check
    check (started_at is null or started_at >= created_at),
  constraint agent_tasks_completed_at_check
    check (
      completed_at is null
      or (
        completed_at >= created_at
        and (started_at is null or completed_at >= started_at)
      )
    ),
  constraint agent_tasks_terminal_status_check
    check (
      (status in ('cancelled', 'succeeded', 'failed', 'safety_blocked', 'expired'))
      = (completed_at is not null)
    ),
  constraint agent_tasks_error_code_check
    check (
      error_code is null
      or (
        error_code = btrim(error_code)
        and char_length(error_code) between 1 and 128
      )
    ),
  constraint agent_tasks_error_message_check
    check (
      error_message is null
      or (
        error_message = btrim(error_message)
        and char_length(error_message) between 1 and 2000
      )
    ),
  constraint agent_tasks_retention_expires_at_check
    check (
      retention_expires_at is null
      or retention_expires_at > created_at
    )
);

comment on table private.agent_tasks is
  'User-owned execution tasks. It intentionally has no raw instruction column; persisted instruction diagnostics are a redacted summary and SHA-256 hash.';

create index agent_tasks_user_id_status_created_at_idx
  on private.agent_tasks (user_id, status, created_at desc);

create index agent_tasks_user_id_session_id_created_at_idx
  on private.agent_tasks (user_id, session_id, created_at desc);

create index agent_tasks_user_id_correlation_id_idx
  on private.agent_tasks (user_id, correlation_id);

create index agent_tasks_user_id_retention_expires_at_idx
  on private.agent_tasks (user_id, retention_expires_at)
  where retention_expires_at is not null;

create table private.task_steps (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  task_id uuid not null,
  sequence integer not null,
  batch_id uuid,
  action_type text not null,
  target_fingerprint_hash text,
  status text not null default 'planned',
  healed boolean not null default false,
  healing_status text not null default 'not_attempted',
  healing_confidence numeric(5, 4),
  healing_metadata jsonb not null default '{}'::jsonb,
  verification jsonb not null default '{}'::jsonb,
  latency_ms integer,
  error_code text,
  error_message text,
  correlation_id uuid not null default gen_random_uuid(),
  created_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  retention_expires_at timestamptz,
  updated_at timestamptz not null default now(),

  constraint task_steps_id_task_id_user_id_key unique (id, task_id, user_id),
  constraint task_steps_user_id_task_id_sequence_key
    unique (user_id, task_id, sequence),
  constraint task_steps_task_owner_fkey
    foreign key (task_id, user_id)
    references private.agent_tasks (id, user_id)
    on delete cascade,
  constraint task_steps_sequence_check
    check (sequence >= 1),
  constraint task_steps_action_type_check
    check (
      action_type in (
        'navigate',
        'read',
        'click',
        'fill',
        'select',
        'scroll',
        'wait',
        'download',
        'upload',
        'submit',
        'script',
        'safety_check',
        'other'
      )
    ),
  constraint task_steps_target_fingerprint_hash_check
    check (
      target_fingerprint_hash is null
      or (
        target_fingerprint_hash = lower(target_fingerprint_hash)
        and target_fingerprint_hash ~ '^[0-9a-f]{64}$'
      )
    ),
  constraint task_steps_status_check
    check (
      status in (
        'planned',
        'dispatched',
        'running',
        'paused',
        'skipped',
        'cancelled',
        'succeeded',
        'failed',
        'safety_blocked'
      )
    ),
  constraint task_steps_healing_status_check
    check (healing_status in ('not_attempted', 'attempted', 'healed', 'rejected')),
  constraint task_steps_healed_state_check
    check ((healing_status = 'healed') = healed),
  constraint task_steps_healing_confidence_check
    check (
      healing_confidence is null
      or (
        healing_status <> 'not_attempted'
        and healing_confidence between 0 and 1
      )
    ),
  constraint task_steps_healing_metadata_object_check
    check (jsonb_typeof(healing_metadata) = 'object'),
  constraint task_steps_verification_object_check
    check (jsonb_typeof(verification) = 'object'),
  constraint task_steps_latency_ms_check
    check (latency_ms is null or latency_ms >= 0),
  constraint task_steps_started_at_check
    check (started_at is null or started_at >= created_at),
  constraint task_steps_completed_at_check
    check (
      completed_at is null
      or (
        completed_at >= created_at
        and (started_at is null or completed_at >= started_at)
      )
    ),
  constraint task_steps_terminal_status_check
    check (
      (status in ('skipped', 'cancelled', 'succeeded', 'failed', 'safety_blocked'))
      = (completed_at is not null)
    ),
  constraint task_steps_error_code_check
    check (
      error_code is null
      or (
        error_code = btrim(error_code)
        and char_length(error_code) between 1 and 128
      )
    ),
  constraint task_steps_error_message_check
    check (
      error_message is null
      or (
        error_message = btrim(error_message)
        and char_length(error_message) between 1 and 2000
      )
    ),
  constraint task_steps_retention_expires_at_check
    check (
      retention_expires_at is null
      or retention_expires_at > created_at
    )
);

comment on table private.task_steps is
  'Ordered task checkpoints. Filled values and raw browser content are intentionally excluded; verification and healing metadata must be redacted.';

create index task_steps_user_id_task_id_status_sequence_idx
  on private.task_steps (user_id, task_id, status, sequence);

create index task_steps_user_id_correlation_id_idx
  on private.task_steps (user_id, correlation_id);

create index task_steps_user_id_retention_expires_at_idx
  on private.task_steps (user_id, retention_expires_at)
  where retention_expires_at is not null;

create table private.task_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  task_id uuid not null,
  step_id uuid,
  sequence integer not null,
  event_type text not null,
  event_metadata jsonb not null default '{}'::jsonb,
  correlation_id uuid not null default gen_random_uuid(),
  error_code text,
  error_message text,
  occurred_at timestamptz not null default now(),
  retention_expires_at timestamptz,
  created_at timestamptz not null default now(),

  constraint task_events_user_id_task_id_sequence_key
    unique (user_id, task_id, sequence),
  constraint task_events_task_owner_fkey
    foreign key (task_id, user_id)
    references private.agent_tasks (id, user_id)
    on delete cascade,
  constraint task_events_step_owner_fkey
    foreign key (step_id, task_id, user_id)
    references private.task_steps (id, task_id, user_id)
    on delete cascade,
  constraint task_events_sequence_check
    check (sequence >= 1),
  constraint task_events_event_type_check
    check (
      event_type in (
        'planned',
        'dispatched',
        'paused',
        'resumed',
        'skipped',
        'cancelled',
        'succeeded',
        'failed',
        'safety-blocked',
        'selector-healed'
      )
    ),
  constraint task_events_selector_healed_step_check
    check (event_type <> 'selector-healed' or step_id is not null),
  constraint task_events_metadata_object_check
    check (jsonb_typeof(event_metadata) = 'object'),
  constraint task_events_error_code_check
    check (
      error_code is null
      or (
        error_code = btrim(error_code)
        and char_length(error_code) between 1 and 128
      )
    ),
  constraint task_events_error_message_check
    check (
      error_message is null
      or (
        error_message = btrim(error_message)
        and char_length(error_message) between 1 and 2000
      )
    ),
  constraint task_events_retention_expires_at_check
    check (
      retention_expires_at is null
      or retention_expires_at > occurred_at
    )
);

comment on table private.task_events is
  'Append-only ordered execution timeline. M011 prevents client mutation; event metadata is restricted to redacted operational signals.';

create index task_events_user_id_task_id_occurred_at_idx
  on private.task_events (user_id, task_id, occurred_at);

create index task_events_user_id_correlation_id_idx
  on private.task_events (user_id, correlation_id);

create index task_events_user_id_retention_expires_at_idx
  on private.task_events (user_id, retention_expires_at)
  where retention_expires_at is not null;

create table private.task_artifacts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  task_id uuid not null,
  step_id uuid,
  artifact_type text not null,
  storage_bucket text not null default 'task-artifacts',
  storage_path text not null,
  mime_type text not null default 'application/octet-stream',
  size_bytes bigint not null default 0,
  content_hash text not null,
  correlation_id uuid not null default gen_random_uuid(),
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),

  constraint task_artifacts_user_id_storage_location_key
    unique (user_id, storage_bucket, storage_path),
  constraint task_artifacts_task_owner_fkey
    foreign key (task_id, user_id)
    references private.agent_tasks (id, user_id)
    on delete cascade,
  constraint task_artifacts_step_owner_fkey
    foreign key (step_id, task_id, user_id)
    references private.task_steps (id, task_id, user_id)
    on delete cascade,
  constraint task_artifacts_type_check
    check (
      artifact_type in (
        'screenshot',
        'downloaded_result',
        'diagnostic_dom_fragment'
      )
    ),
  constraint task_artifacts_storage_bucket_check
    check (storage_bucket = 'task-artifacts'),
  constraint task_artifacts_storage_path_check
    check (
      storage_path = btrim(storage_path)
      and char_length(storage_path) between 1 and 2048
      and storage_path !~ '^/'
      and storage_path like (user_id::text || '/%')
    ),
  constraint task_artifacts_mime_type_check
    check (
      mime_type = btrim(mime_type)
      and char_length(mime_type) between 1 and 255
    ),
  constraint task_artifacts_size_bytes_check
    check (size_bytes >= 0),
  constraint task_artifacts_content_hash_check
    check (
      content_hash = lower(content_hash)
      and content_hash ~ '^[0-9a-f]{64}$'
    ),
  constraint task_artifacts_expires_at_check
    check (expires_at > created_at)
);

comment on table private.task_artifacts is
  'Metadata only for optional, short-lived task artifacts in the future private task-artifacts bucket. No artifact bytes are stored in Postgres.';

create index task_artifacts_user_id_task_id_created_at_idx
  on private.task_artifacts (user_id, task_id, created_at desc);

create index task_artifacts_user_id_correlation_id_idx
  on private.task_artifacts (user_id, correlation_id);

create index task_artifacts_user_id_expires_at_idx
  on private.task_artifacts (user_id, expires_at);

create table private.provider_calls (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  task_id uuid not null,
  step_id uuid,
  provider text not null,
  model text,
  operation text not null,
  status text not null default 'queued',
  input_tokens bigint not null default 0,
  output_tokens bigint not null default 0,
  audio_input_seconds numeric(14, 3) not null default 0,
  audio_output_seconds numeric(14, 3) not null default 0,
  ocr_pages integer not null default 0,
  latency_ms integer,
  retry_count integer not null default 0,
  provider_request_id text,
  estimated_cost_micros bigint not null default 0,
  billed_cost_micros bigint not null default 0,
  currency_code text not null default 'USD',
  correlation_id uuid not null default gen_random_uuid(),
  error_code text,
  error_message text,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  retention_expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint provider_calls_task_owner_fkey
    foreign key (task_id, user_id)
    references private.agent_tasks (id, user_id)
    on delete cascade,
  constraint provider_calls_step_owner_fkey
    foreign key (step_id, task_id, user_id)
    references private.task_steps (id, task_id, user_id)
    on delete cascade,
  constraint provider_calls_provider_check
    check (
      provider = lower(btrim(provider))
      and char_length(provider) between 1 and 128
    ),
  constraint provider_calls_model_check
    check (
      model is null
      or (
        model = btrim(model)
        and char_length(model) between 1 and 255
      )
    ),
  constraint provider_calls_operation_check
    check (operation in ('llm', 'stt', 'tts', 'ocr', 'embedding', 'browser', 'other')),
  constraint provider_calls_status_check
    check (status in ('queued', 'running', 'succeeded', 'failed', 'cancelled')),
  constraint provider_calls_input_tokens_check
    check (input_tokens >= 0),
  constraint provider_calls_output_tokens_check
    check (output_tokens >= 0),
  constraint provider_calls_audio_input_seconds_check
    check (audio_input_seconds >= 0),
  constraint provider_calls_audio_output_seconds_check
    check (audio_output_seconds >= 0),
  constraint provider_calls_ocr_pages_check
    check (ocr_pages >= 0),
  constraint provider_calls_latency_ms_check
    check (latency_ms is null or latency_ms >= 0),
  constraint provider_calls_retry_count_check
    check (retry_count >= 0),
  constraint provider_calls_provider_request_id_check
    check (
      provider_request_id is null
      or (
        provider_request_id = btrim(provider_request_id)
        and char_length(provider_request_id) between 1 and 512
      )
    ),
  constraint provider_calls_estimated_cost_micros_check
    check (estimated_cost_micros >= 0),
  constraint provider_calls_billed_cost_micros_check
    check (billed_cost_micros >= 0),
  constraint provider_calls_currency_code_check
    check (currency_code ~ '^[A-Z]{3}$'),
  constraint provider_calls_error_code_check
    check (
      error_code is null
      or (
        error_code = btrim(error_code)
        and char_length(error_code) between 1 and 128
      )
    ),
  constraint provider_calls_error_message_check
    check (
      error_message is null
      or (
        error_message = btrim(error_message)
        and char_length(error_message) between 1 and 2000
      )
    ),
  constraint provider_calls_completed_at_check
    check (completed_at is null or completed_at >= started_at),
  constraint provider_calls_terminal_status_check
    check (
      (status in ('succeeded', 'failed', 'cancelled')) = (completed_at is not null)
    ),
  constraint provider_calls_retention_expires_at_check
    check (
      retention_expires_at is null
      or retention_expires_at > created_at
    )
);

comment on table private.provider_calls is
  'Provider reliability and billing metrics only. Raw request/response payloads, credentials, and API keys are deliberately not persisted.';

create index provider_calls_user_id_task_id_started_at_idx
  on private.provider_calls (user_id, task_id, started_at desc);

create index provider_calls_user_id_provider_model_started_at_idx
  on private.provider_calls (user_id, provider, model, started_at desc);

create index provider_calls_user_id_correlation_id_idx
  on private.provider_calls (user_id, correlation_id);

create index provider_calls_user_id_retention_expires_at_idx
  on private.provider_calls (user_id, retention_expires_at)
  where retention_expires_at is not null;

create trigger browser_sessions_set_updated_at
  before update on private.browser_sessions
  for each row execute function private.set_updated_at();

create trigger agent_tasks_set_updated_at
  before update on private.agent_tasks
  for each row execute function private.set_updated_at();

create trigger task_steps_set_updated_at
  before update on private.task_steps
  for each row execute function private.set_updated_at();

create trigger provider_calls_set_updated_at
  before update on private.provider_calls
  for each row execute function private.set_updated_at();

commit;
