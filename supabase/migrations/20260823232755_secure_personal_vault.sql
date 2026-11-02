-- Round 2B: client security for the personal Vault.
--
-- Grants and RLS are separate controls.  Client roles receive only the
-- owner-scoped public metadata access defined below; the service role remains
-- the server-side compatibility path, including for legacy `documents`
-- storage references.

begin;

-- Public Vault metadata is private to authenticated owners.  Revoke first so
-- this migration remains safe if an environment still has legacy defaults.
revoke all privileges on table public.vault_documents
  from public, anon, authenticated;
revoke all privileges on table public.swara_context_items
  from public, anon, authenticated;

grant select, insert, update, delete
  on table public.vault_documents to authenticated;
grant select, insert, update, delete
  on table public.swara_context_items to authenticated;

-- The server role is the only compatibility path for service-side work,
-- including rows that still point at the pre-Swara `documents` bucket.
grant select, insert, update, delete
  on table public.vault_documents to service_role;
grant select, insert, update, delete
  on table public.swara_context_items to service_role;

alter table public.vault_documents enable row level security;
alter table public.swara_context_items enable row level security;

create policy vault_documents_select_own
  on public.vault_documents
  for select
  to authenticated
  using ((select auth.uid()) = user_id);

create policy vault_documents_insert_own
  on public.vault_documents
  for insert
  to authenticated
  with check (
    (select auth.uid()) = user_id
    and storage_bucket is distinct from 'documents'
  );

create policy vault_documents_update_own
  on public.vault_documents
  for update
  to authenticated
  using ((select auth.uid()) = user_id)
  with check (
    (select auth.uid()) = user_id
    and storage_bucket is distinct from 'documents'
  );

create policy vault_documents_delete_own
  on public.vault_documents
  for delete
  to authenticated
  using ((select auth.uid()) = user_id);

create policy vault_documents_service_role_all
  on public.vault_documents
  for all
  to service_role
  using (true)
  with check (true);

create policy context_items_select_own
  on public.swara_context_items
  for select
  to authenticated
  using ((select auth.uid()) = user_id);

create policy context_items_insert_own
  on public.swara_context_items
  for insert
  to authenticated
  with check (
    (select auth.uid()) = user_id
    and version >= 1
    and (
      (version = 1 and supersedes_id is null)
      or (version > 1 and supersedes_id is not null)
    )
  );

create policy context_items_update_own
  on public.swara_context_items
  for update
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy context_items_delete_own
  on public.swara_context_items
  for delete
  to authenticated
  using ((select auth.uid()) = user_id);

create policy context_items_service_role_all
  on public.swara_context_items
  for all
  to service_role
  using (true)
  with check (true);

-- Corrections are append-only for client roles.  The UPDATE grant and policy
-- remain explicit for the contract, but an authenticated client cannot
-- destructively overwrite a context row; it must insert the next version.
-- Server-side roles may still perform controlled lifecycle maintenance.
create or replace function private.reject_authenticated_context_item_updates()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $function$
begin
  if current_user = 'authenticated' then
    raise exception using
      errcode = '42501',
      message = 'Context corrections must be inserted as new versions';
  end if;
  return new;
end;
$function$;

revoke execute on function private.reject_authenticated_context_item_updates()
  from public, anon, authenticated;

create trigger context_items_reject_authenticated_updates
  before update on public.swara_context_items
  for each row
  execute function private.reject_authenticated_context_item_updates();

-- Validate the version chain and same-owner supersession at insert time.  The
-- trigger is internal-only and uses a locked search path; it never becomes a
-- client-callable API function.
create or replace function private.validate_context_item_version()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  prior_user_id uuid;
  prior_version bigint;
  prior_key text;
  prior_scope text;
  prior_status text;
begin
  if new.version is null or new.version < 1 then
    raise exception using
      errcode = '23514',
      message = 'Context item versions must be positive';
  end if;

  if new.version = 1 then
    if new.supersedes_id is not null then
      raise exception using
        errcode = '23514',
        message = 'The first context item version cannot supersede a row';
    end if;
    return new;
  end if;

  if new.supersedes_id is null then
    raise exception using
      errcode = '23514',
      message = 'A corrected context item must supersede a prior version';
  end if;

  select c.user_id, c.version, c.key, c.scope, c.status
    into prior_user_id, prior_version, prior_key, prior_scope, prior_status
    from public.swara_context_items as c
   where c.id = new.supersedes_id;

  if not found
     or prior_user_id is distinct from new.user_id
     or prior_version is distinct from new.version - 1
     or prior_key is distinct from new.key
     or prior_scope is distinct from new.scope
     or prior_status is distinct from 'active' then
    raise exception using
      errcode = '23514',
      message = 'Context corrections must reference the prior version for the same user';
  end if;

  -- Retire the prior version in the same transaction before the new active
  -- row is inserted. The partial unique index then guarantees one active
  -- version for each user/key/scope.
  update public.swara_context_items
     set status = 'superseded'
   where id = new.supersedes_id;

  return new;
end;
$function$;

revoke execute on function private.validate_context_item_version()
  from public, anon, authenticated;

create trigger context_items_validate_version
  before insert on public.swara_context_items
  for each row
  execute function private.validate_context_item_version();

-- Chunks are server-only.  Keep both the table and every private helper
-- function unreachable from PUBLIC, anon, and authenticated.
revoke all privileges on schema private
  from public, anon, authenticated;
revoke all privileges on table private.document_chunks
  from public, anon, authenticated;
revoke execute on all functions in schema private
  from public, anon, authenticated;

grant usage on schema private to service_role;
grant select, insert, update, delete
  on table private.document_chunks to service_role;

alter table private.document_chunks enable row level security;

commit;
