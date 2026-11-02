-- Round 2C: private Storage for the personal Vault.
--
-- This migration is intentionally limited to the two new Vault buckets.  The
-- legacy private `documents` bucket is not named in any DML, DDL, grant, or
-- policy below: its four unowned objects remain untouched and unmapped.

begin;

-- A pre-existing Vault bucket is an unexpected state.  Do not use an upsert
-- here: failing preserves its configuration and contents for explicit review
-- instead of silently changing a potentially non-empty bucket.
insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values
  (
    'vault-originals',
    'vault-originals',
    false,
    52428800,
    array[
      'application/pdf',
      'application/msword',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'application/vnd.ms-excel',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'application/vnd.ms-powerpoint',
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'application/vnd.oasis.opendocument.text',
      'application/vnd.oasis.opendocument.spreadsheet',
      'application/vnd.oasis.opendocument.presentation',
      'application/rtf',
      'application/epub+zip',
      'text/plain',
      'text/markdown',
      'text/csv',
      'text/rtf',
      'image/jpeg',
      'image/png',
      'image/webp',
      'image/tiff'
    ]::text[]
  ),
  (
    'vault-derived',
    'vault-derived',
    false,
    26214400,
    array[
      'application/json',
      'application/pdf',
      'text/plain',
      'text/markdown',
      'text/csv',
      'image/jpeg',
      'image/png',
      'image/webp'
    ]::text[]
  );

-- Supabase Storage evaluates both Postgres grants and RLS policies.  The
-- storage schema normally provides these grants already, but spelling them
-- out keeps authenticated uploads and upserts reproducible without changing
-- the legacy bucket or its policies.
grant usage on schema storage to authenticated;
grant select, insert, update, delete on table storage.objects to authenticated;

-- Each path must be exactly:
--   {auth.uid()}/{resource UUID}/{filename}
-- `owner_id` is a text column in the current Supabase Storage schema.  The
-- path check and owner check are both required: the path prevents a user from
-- selecting another user's namespace, while owner_id prevents access to an
-- object whose ownership does not match that namespace.
create policy vault_storage_select_own
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id in ('vault-originals', 'vault-derived')
    and owner_id = (select auth.uid()::text)
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] = (select auth.uid()::text)
    and (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and storage.filename(name) <> ''
  );

create policy vault_storage_insert_own
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id in ('vault-originals', 'vault-derived')
    and owner_id = (select auth.uid()::text)
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] = (select auth.uid()::text)
    and (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and storage.filename(name) <> ''
  );

-- SELECT and UPDATE are both necessary for the Storage API's upsert path.
-- WITH CHECK prevents a user from changing ownership, bucket, or path while
-- updating an otherwise permitted object.
create policy vault_storage_update_own
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id in ('vault-originals', 'vault-derived')
    and owner_id = (select auth.uid()::text)
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] = (select auth.uid()::text)
    and (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and storage.filename(name) <> ''
  )
  with check (
    bucket_id in ('vault-originals', 'vault-derived')
    and owner_id = (select auth.uid()::text)
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] = (select auth.uid()::text)
    and (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and storage.filename(name) <> ''
  );

create policy vault_storage_delete_own
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id in ('vault-originals', 'vault-derived')
    and owner_id = (select auth.uid()::text)
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] = (select auth.uid()::text)
    and (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and storage.filename(name) <> ''
  );

commit;
