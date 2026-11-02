-- Individual Swara identity data. Security policies and role grants are added
-- separately in M003. The timestamp helper is owned by M001.

create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  locale text not null default 'en',
  timezone text not null default 'UTC',
  onboarding_state text not null default 'new',
  avatar_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,

  constraint profiles_display_name_trimmed_check
    check (display_name is null or display_name = btrim(display_name)),
  constraint profiles_display_name_length_check
    check (display_name is null or char_length(display_name) between 1 and 160),
  constraint profiles_locale_trimmed_check
    check (locale = btrim(locale) and char_length(locale) between 2 and 35),
  constraint profiles_timezone_trimmed_check
    check (timezone = btrim(timezone) and char_length(timezone) between 1 and 255),
  constraint profiles_onboarding_state_check
    check (onboarding_state in ('new', 'active', 'completed', 'blocked')),
  constraint profiles_avatar_path_trimmed_check
    check (avatar_path is null or avatar_path = btrim(avatar_path)),
  constraint profiles_avatar_path_length_check
    check (avatar_path is null or char_length(avatar_path) between 1 and 2048),
  constraint profiles_deleted_at_check
    check (deleted_at is null or deleted_at >= created_at)
);

create table public.user_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  preferred_language text not null default 'en',
  voice_config jsonb not null default '{}'::jsonb,
  privacy_mode text not null default 'standard',
  history_retention_days integer not null default 30,
  save_transcripts boolean not null default false,
  cloud_workflow_sync boolean not null default false,
  personalization_enabled boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint user_settings_preferred_language_trimmed_check
    check (
      preferred_language = btrim(preferred_language)
      and char_length(preferred_language) between 2 and 35
    ),
  constraint user_settings_voice_config_object_check
    check (jsonb_typeof(voice_config) = 'object'),
  constraint user_settings_privacy_mode_check
    check (privacy_mode in ('standard', 'minimal-history', 'local-first')),
  constraint user_settings_history_retention_days_check
    check (history_retention_days between 0 and 3650)
);

create table public.devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  installation_hash text not null,
  browser text not null,
  extension_version text not null,
  device_public_key text,
  last_seen_at timestamptz not null default now(),
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint devices_user_id_installation_hash_key unique (user_id, installation_hash),
  constraint devices_installation_hash_trimmed_check
    check (
      installation_hash = btrim(installation_hash)
      and char_length(installation_hash) between 1 and 512
    ),
  constraint devices_browser_trimmed_check
    check (browser = btrim(browser) and char_length(browser) between 1 and 128),
  constraint devices_extension_version_trimmed_check
    check (
      extension_version = btrim(extension_version)
      and char_length(extension_version) between 1 and 128
    ),
  constraint devices_device_public_key_trimmed_check
    check (
      device_public_key is null
      or (
        device_public_key = btrim(device_public_key)
        and char_length(device_public_key) between 1 and 16384
      )
    ),
  constraint devices_revoked_at_check
    check (revoked_at is null or revoked_at >= created_at)
);

create index devices_user_id_last_seen_at_idx
  on public.devices (user_id, last_seen_at desc);

create table public.domain_policies (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  domain_pattern text not null,
  allow_read boolean not null default false,
  allow_fill boolean not null default false,
  allow_navigation boolean not null default false,
  allow_download boolean not null default false,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint domain_policies_user_id_domain_pattern_key unique (user_id, domain_pattern),
  constraint domain_policies_domain_pattern_check
    check (
      domain_pattern = lower(domain_pattern)
      and domain_pattern = btrim(domain_pattern)
      and char_length(domain_pattern) between 1 and 253
      and domain_pattern !~ '[[:space:]]'
    ),
  constraint domain_policies_expires_at_check
    check (expires_at is null or expires_at > created_at)
);

create index domain_policies_user_id_expires_at_idx
  on public.domain_policies (user_id, expires_at);

create table public.consent_records (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  consent_type text not null,
  policy_version text not null,
  granted boolean not null,
  metadata jsonb not null default '{}'::jsonb,
  recorded_at timestamptz not null default now(),

  constraint consent_records_consent_type_check
    check (
      consent_type in (
        'terms',
        'privacy_policy',
        'vault_processing',
        'transcript_history',
        'analytics',
        'company_knowledge_connector'
      )
    ),
  constraint consent_records_policy_version_trimmed_check
    check (
      policy_version = btrim(policy_version)
      and char_length(policy_version) between 1 and 255
    ),
  constraint consent_records_metadata_object_check
    check (jsonb_typeof(metadata) = 'object')
);

comment on table public.consent_records is
  'Append-only consent ledger. Consent changes are represented by new rows.';

create index consent_records_user_id_type_recorded_at_idx
  on public.consent_records (user_id, consent_type, recorded_at desc);

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function private.set_updated_at();

create trigger user_settings_set_updated_at
  before update on public.user_settings
  for each row execute function private.set_updated_at();

create trigger devices_set_updated_at
  before update on public.devices
  for each row execute function private.set_updated_at();

create trigger domain_policies_set_updated_at
  before update on public.domain_policies
  for each row execute function private.set_updated_at();
