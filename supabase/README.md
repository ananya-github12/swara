# Swara Supabase

This directory defines the Swara project database only. Swara owns its own
individual-user identities and data; it does not share an Auth database or
database connection with Alterity.

## Foundation rules

- The Data API exposes only `public` and `graphql_public`.
- `private` and `audit` are internal schemas. `PUBLIC`, `anon`, and
  `authenticated` have no schema or function access to either schema.
- Database functions are not executable by client roles unless a later,
  reviewed migration grants that permission explicitly.
- This foundation intentionally makes no Storage, Auth-user, extension, queue,
  or legacy `documents` bucket changes.
- `seed.sql` intentionally contains no users, secrets, credentials, or
  production data.

## Runtime access model

Swara intentionally uses three separate database paths:

- Browser and user-owned reads use a caller-scoped Supabase client with the
  user's verified JWT and `public` RLS policies.
- API operations on `private` data use a separately provisioned login that
  inherits only the `swara_api_runtime` NOLOGIN role.
- Queue consumers and maintenance workers use a different login that inherits
  only the `swara_worker_runtime` NOLOGIN role.

The runtime login roles and their passwords are provisioned outside migrations.
Do not put login passwords in SQL, source control, Edge Function settings files,
or extension configuration. Edge Functions receive only
`SWARA_API_DATABASE_URL` or `SWARA_WORKER_DATABASE_URL`; they never use the
platform-provided broad `SUPABASE_DB_URL`. Remote URLs must require TLS and use
the transaction pooler. Prepared statements are disabled by the shared runtime
adapter.

Provision hosted function secrets separately from migrations:

```sh
supabase secrets set --project-ref <project-ref> \
  SWARA_EXTENSION_ORIGINS=chrome-extension://<extension-id> \
  SWARA_API_DATABASE_URL='postgresql://<dedicated-api-login>:<password>@<pooler-host>:6543/postgres?sslmode=require' \
  SWARA_WORKER_DATABASE_URL='postgresql://<dedicated-worker-login>:<password>@<pooler-host>:6543/postgres?sslmode=require' \
  SWARA_WORKER_TOKEN='<random-worker-token>'
```

Billing additionally needs `ALTERITY_CONTROL_PLANE_URL`; the webhook needs
`ALTERITY_WEBHOOK_SECRET`. Never use `SUPABASE_DB_URL`, `service_role`, or a
browser key as a runtime database credential.

Workers that call external services additionally require the narrowly scoped
secrets `ALTERITY_SWARA_SERVICE_TOKEN`, `SWARA_VAULT_INGESTION_URL` plus its
optional `SWARA_VAULT_INGESTION_TOKEN`, `SUPABASE_URL`,
`SWARA_STORAGE_ADMIN_KEY`, and `SWARA_AUTH_ADMIN_KEY`. The storage and Auth
admin keys are Edge Function secrets only; they are never shipped to the
extension.

`service_role` is limited to Supabase-managed administrative surfaces. It does
not receive direct access to Swara's `private`, `audit`, or `pgmq` schemas.

## Local verification

Start the local Supabase stack, then apply the migration and run the database
checks:

```sh
supabase start
supabase db reset --local
supabase db lint --local --schema public,private,audit --level warning --fail-on error
supabase test db
```

The configured local database uses PostgreSQL 17 and project-specific ports so
it can run beside other Supabase projects. Keep `private`, `audit`, and `pgmq`
out of `[api].schemas`, and keep anonymous Auth sign-ins disabled.

## Hosted promotion

Never push migrations directly from an unverified working tree. The promotion
gate is:

1. clean local reset, lint, and complete pgTAP pass;
2. migration diff and ownership/grant review;
3. preview-branch validation against a fresh database;
4. explicit environment confirmation and approval before production changes;
5. post-push migration-history, advisor, Auth, Storage, queue, and function
   checks.

Legacy unowned objects are quarantined in place. No migration or account
deletion workflow may claim, move, expose, or delete them without an explicit,
verified owner-mapping plan.
