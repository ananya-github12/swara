-- Round 2A: user-owned personal Vault schema.
--
-- This migration defines metadata and private chunk storage only. It does not
-- create Storage buckets, alter the legacy `documents` bucket, map legacy
-- objects, add grants/RLS, or create queues. Those concerns belong to later
-- migrations.

begin;

-- Keep the extension unpinned so Supabase can use its supported pgvector
-- release. `extensions.vector` without a dimension typmod deliberately allows
-- model versions with different embedding dimensions in one table.
create extension if not exists vector with schema extensions;

create table public.vault_documents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  filename text not null,
  mime_type text not null default 'application/octet-stream',
  size_bytes bigint not null,
  sha256 text not null,
  storage_bucket text not null default 'vault-originals',
  storage_path text not null,
  extraction_method text not null,
  status text not null default 'pending',
  error_code text,
  error_message text,
  retention_expires_at timestamptz,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- The composite key supports owner-safe source references from derived rows.
  constraint vault_documents_id_user_id_key unique (id, user_id),
  constraint vault_documents_user_id_sha256_key unique (user_id, sha256),
  constraint vault_documents_user_id_storage_location_key
    unique (user_id, storage_bucket, storage_path),
  constraint vault_documents_filename_check
    check (
      filename = btrim(filename)
      and char_length(filename) between 1 and 1024
    ),
  constraint vault_documents_mime_type_check
    check (
      mime_type = btrim(mime_type)
      and char_length(mime_type) between 1 and 255
    ),
  constraint vault_documents_size_bytes_check
    check (size_bytes >= 0),
  constraint vault_documents_sha256_check
    check (sha256 = lower(sha256) and sha256 ~ '^[0-9a-f]{64}$'),
  constraint vault_documents_storage_bucket_check
    check (storage_bucket in ('vault-originals', 'vault-derived', 'documents')),
  constraint vault_documents_storage_path_check
    check (
      storage_path = btrim(storage_path)
      and char_length(storage_path) between 1 and 2048
    ),
  constraint vault_documents_extraction_method_check
    check (extraction_method in ('local', 'ocr', 'manual')),
  constraint vault_documents_status_check
    check (status in ('pending', 'processing', 'ready', 'failed', 'deleted')),
  constraint vault_documents_error_code_check
    check (
      error_code is null
      or (
        error_code = btrim(error_code)
        and char_length(error_code) between 1 and 128
      )
    ),
  constraint vault_documents_error_message_check
    check (
      error_message is null
      or (
        error_message = btrim(error_message)
        and char_length(error_message) between 1 and 2000
      )
    ),
  constraint vault_documents_retention_expires_at_check
    check (
      retention_expires_at is null
      or retention_expires_at > created_at
    ),
  constraint vault_documents_deleted_at_check
    check (deleted_at is null or deleted_at >= created_at),
  constraint vault_documents_deleted_status_check
    check ((status = 'deleted') = (deleted_at is not null))
);

comment on column public.vault_documents.storage_bucket is
  'Allowed values include the untouched legacy documents bucket only for a later, explicitly verified ownership mapping.';

create index vault_documents_user_id_status_created_at_idx
  on public.vault_documents (user_id, status, created_at desc);

create index vault_documents_user_id_retention_expires_at_idx
  on public.vault_documents (user_id, retention_expires_at)
  where retention_expires_at is not null;

create table public.swara_context_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  type text not null,
  key text not null,
  value text not null,
  category text not null default 'general',
  sensitivity text not null default 'standard',
  source_document_id uuid,
  source_type text not null default 'manual',
  scope text not null default 'persistent',
  status text not null default 'active',
  version integer not null default 1,
  supersedes_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- This composite key makes self-references owner-safe as well as unique.
  constraint context_items_id_user_id_key unique (id, user_id),
  constraint context_items_type_check
    check (type in ('fact', 'preference', 'correction', 'instruction', 'document')),
  constraint context_items_key_check
    check (key = btrim(key) and char_length(key) between 1 and 512),
  constraint context_items_value_check
    check (char_length(value) between 1 and 65535),
  constraint context_items_category_check
    check (category = btrim(category) and char_length(category) between 1 and 128),
  constraint context_items_sensitivity_check
    check (sensitivity in ('standard', 'sensitive', 'restricted')),
  constraint context_items_source_type_check
    check (
      source_type = btrim(source_type)
      and char_length(source_type) between 1 and 128
    ),
  constraint context_items_scope_check
    check (scope in ('persistent', 'session', 'task')),
  constraint context_items_status_check
    check (status in ('active', 'superseded', 'archived', 'deleted')),
  constraint context_items_version_check
    check (version >= 1),
  constraint context_items_supersedes_not_self_check
    check (supersedes_id is null or supersedes_id <> id),
  constraint context_items_correction_reference_check
    check (
      (type = 'correction' and supersedes_id is not null)
      or (type <> 'correction' and supersedes_id is null)
    )
);

-- A context item may only point at a document owned by the same Swara user.
alter table public.swara_context_items
  add constraint context_items_source_document_owner_fkey
  foreign key (source_document_id, user_id)
  references public.vault_documents (id, user_id)
  on delete cascade;

-- Corrections form an owner-scoped immutable history chain. A later security
-- migration controls which fields clients may update; this schema prevents a
-- chain from crossing between users and requires a distinct correction row.
alter table public.swara_context_items
  add constraint context_items_supersedes_owner_fkey
  foreign key (supersedes_id, user_id)
  references public.swara_context_items (id, user_id)
  on delete cascade;

create unique index context_items_user_id_key_scope_version_key
  on public.swara_context_items (user_id, key, scope, version);

create unique index context_items_user_id_active_key_scope_key
  on public.swara_context_items (user_id, key, scope)
  where status = 'active';

create index context_items_user_id_status_updated_at_idx
  on public.swara_context_items (user_id, status, updated_at desc);

create index context_items_user_id_source_document_id_idx
  on public.swara_context_items (user_id, source_document_id)
  where source_document_id is not null;

create index context_items_user_id_supersedes_id_idx
  on public.swara_context_items (user_id, supersedes_id)
  where supersedes_id is not null;

create table private.document_chunks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  document_id uuid not null,
  chunk_index integer not null,
  content text not null,
  token_count integer not null,
  embedding extensions.vector,
  embedding_model text not null,
  embedding_dimensions integer not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint document_chunks_user_doc_chunk_model_dim_key
    unique (user_id, document_id, chunk_index, embedding_model, embedding_dimensions),
  constraint document_chunks_document_owner_fkey
    foreign key (document_id, user_id)
    references public.vault_documents (id, user_id)
    on delete cascade,
  constraint document_chunks_chunk_index_check
    check (chunk_index >= 0),
  constraint document_chunks_content_check
    check (char_length(content) between 1 and 1048576),
  constraint document_chunks_token_count_check
    check (token_count >= 0),
  constraint document_chunks_embedding_model_check
    check (
      embedding_model = btrim(embedding_model)
      and char_length(embedding_model) between 1 and 512
    ),
  constraint document_chunks_embedding_dimensions_check
    check (embedding_dimensions between 1 and 16000),
  constraint document_chunks_embedding_dimension_match_check
    check (
      embedding is null
      or extensions.vector_dims(embedding) = embedding_dimensions
    ),
  constraint document_chunks_metadata_object_check
    check (jsonb_typeof(metadata) = 'object')
);

comment on column private.document_chunks.embedding is
  'Variable-dimension pgvector embedding. No HNSW index is created until a model/dimension corpus is selected.';

create index document_chunks_user_id_document_id_chunk_index_idx
  on private.document_chunks (user_id, document_id, chunk_index);

create index document_chunks_user_id_embedding_version_idx
  on private.document_chunks (user_id, embedding_model, embedding_dimensions);

create trigger vault_documents_set_updated_at
  before update on public.vault_documents
  for each row execute function private.set_updated_at();

create trigger context_items_set_updated_at
  before update on public.swara_context_items
  for each row execute function private.set_updated_at();

create trigger document_chunks_set_updated_at
  before update on private.document_chunks
  for each row execute function private.set_updated_at();

commit;
