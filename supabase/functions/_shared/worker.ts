import { RuntimeDatabase, type SqlRow, type SqlTransaction } from "./database.ts";

export type WorkerName =
  | "meter-usage"
  | "refresh-entitlements"
  | "reconcile-billing"
  | "dispatch-vault-ingestion"
  | "purge-expired-artifacts"
  | "complete-account-deletion"
  | "account-export";

type QueueName =
  | "billing-outbox"
  | "usage-reconciliation"
  | "vault-ingest"
  | "artifact-retention"
  | "account-deletion"
  | "account-export";

type JobRow = SqlRow & {
  message_id: number;
  envelope: Record<string, unknown>;
};

type RawJobRow = SqlRow & {
  message_id: number | string;
  envelope: Record<string, unknown>;
};

const QUEUE_BY_WORKER: Record<WorkerName, QueueName> = {
  "meter-usage": "usage-reconciliation",
  "refresh-entitlements": "usage-reconciliation",
  "reconcile-billing": "billing-outbox",
  "dispatch-vault-ingestion": "vault-ingest",
  "purge-expired-artifacts": "artifact-retention",
  "complete-account-deletion": "account-deletion",
  "account-export": "account-export",
};

const WORKER_TOKEN_HEADER = "x-swara-worker-token";
const MAX_BATCH = 25;

export interface WorkerOptions {
  readonly worker: WorkerName;
  readonly environment?: (name: string) => string | undefined;
  readonly createDatabase?: () => Promise<RuntimeDatabase>;
  readonly now?: () => Date;
}

export function createWorkerHandler(options: WorkerOptions): (request: Request) => Promise<Response> {
  const environment = options.environment ?? ((name: string) => Deno.env.get(name));
  const now = options.now ?? (() => new Date());
  return async (request) => {
    if (request.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);
    if (!constantTimeEqual(request.headers.get(WORKER_TOKEN_HEADER), environment("SWARA_WORKER_TOKEN"))) {
      return json({ ok: false, error: "unauthorized" }, 401);
    }

    const limit = await requestedLimit(request);
    if (limit === null) return json({ ok: false, error: "invalid_limit" }, 400);

    let database: RuntimeDatabase | undefined;
    try {
      database = await (options.createDatabase ?? (() => RuntimeDatabase.fromEnvironment("worker")))();
      const result = await database.transaction(async (transaction) => {
        const jobs = await readJobs(transaction, QUEUE_BY_WORKER[options.worker], limit);
        let claimed = 0;
        let completed = 0;
        for (const job of jobs) {
          const envelope = validateEnvelope(job.envelope);
          const claim = await claimJob(
            transaction,
            QUEUE_BY_WORKER[options.worker],
            job.message_id,
            envelope.idempotency_key,
          );
          if (claim !== "claimed") continue;
          claimed += 1;
          // The queue envelope is intentionally opaque. Domain workers load
          // state by job_id in their own reviewed transaction; no user input,
          // document bytes, or provider payload is accepted from the queue.
          await processJob(transaction, options.worker, envelope, now(), environment);
          await archiveJob(transaction, QUEUE_BY_WORKER[options.worker], job.message_id, envelope.idempotency_key);
          completed += 1;
        }
        return { queue: QUEUE_BY_WORKER[options.worker], read: jobs.length, claimed, completed };
      });
      return json({ ok: true, data: result });
    } catch {
      return json({ ok: false, error: "worker_unavailable" }, 500);
    } finally {
      if (database) await database.close().catch(() => undefined);
    }
  };
}

async function readJobs(transaction: SqlTransaction, queue: QueueName, limit: number): Promise<JobRow[]> {
  const rows = await transaction<RawJobRow>`
    select message_id, envelope
      from private.read_jobs(${queue}::text, 300::integer, ${limit}::integer)
  `;
  return rows.flatMap((row) => {
    const messageId = typeof row.message_id === "string" ? Number(row.message_id) : row.message_id;
    return Number.isSafeInteger(messageId) && messageId > 0 && isObject(row.envelope)
      ? [{ envelope: row.envelope, message_id: messageId as number }]
      : [];
  });
}

async function claimJob(transaction: SqlTransaction, queue: QueueName, messageId: number, key: string): Promise<string> {
  const rows = await transaction<{ result: unknown }>`
    select private.claim_job(${queue}::text, ${messageId}::bigint, ${key}::text, 300::integer) as result
  `;
  const result = rows[0]?.result;
  return result === "claimed" || result === "busy" || result === "completed" ? result : "completed";
}

async function archiveJob(transaction: SqlTransaction, queue: QueueName, messageId: number, key: string): Promise<void> {
  const rows = await transaction<{ archived: unknown }>`
    select private.archive_job(${queue}::text, ${messageId}::bigint, ${key}::text) as archived
  `;
  if (rows[0]?.archived !== true) throw new Error("Queue archive failed");
}

type Envelope = { readonly schema_version: 1; readonly job_type: string; readonly job_id: string; readonly idempotency_key: string; readonly correlation_id: string };

function validateEnvelope(value: Record<string, unknown>): Envelope {
  const keys = Object.keys(value).sort().join(",");
  if (keys !== "correlation_id,idempotency_key,job_id,job_type,schema_version" ||
    value.schema_version !== 1 || typeof value.job_type !== "string" ||
    typeof value.job_id !== "string" || typeof value.idempotency_key !== "string" ||
    typeof value.correlation_id !== "string") throw new Error("Invalid queue envelope");
  return value as unknown as Envelope;
}

async function processJob(
  transaction: SqlTransaction,
  worker: WorkerName,
  envelope: Envelope,
  at: Date,
  environment: (name: string) => string | undefined,
): Promise<void> {
  if (!envelope.job_id || !envelope.idempotency_key || !envelope.correlation_id) throw new Error("Invalid job identifiers");
  switch (worker) {
    case "meter-usage":
      await releaseExpiredReservations(transaction, at);
      return;
    case "refresh-entitlements":
      if (envelope.job_type === "maintenance.retry_due_billing_outbox") await deliverBillingOutbox(transaction, at, environment);
      else await refreshEntitlements(transaction, at, environment);
      return;
    case "reconcile-billing":
      if (envelope.job_type === "maintenance.refresh_near_expiry_entitlements") await refreshEntitlements(transaction, at, environment);
      else await deliverBillingOutbox(transaction, at, environment);
      return;
    case "dispatch-vault-ingestion":
      if (envelope.job_type === "maintenance.detect_stuck_vault_ingestion") await failStuckVaultIngestion(transaction, at);
      else await dispatchVaultIngestion(transaction, envelope, environment);
      return;
    case "purge-expired-artifacts":
      await purgeExpiredArtifacts(transaction, at, environment);
      return;
    case "complete-account-deletion":
      await completeAccountDeletion(transaction, envelope, environment);
      return;
    case "account-export":
      if (envelope.job_type === "maintenance.cleanup_expired_account_exports") await cleanupExpiredExports(transaction, environment);
      else await processAccountExport(transaction, envelope, environment);
      return;
  }
}

async function releaseExpiredReservations(transaction: SqlTransaction, at: Date): Promise<void> {
  const rows = await transaction<{ id: string; user_id: string }>`
    select id, user_id
      from private.usage_reservations
     where status = 'reserved'
       and expires_at <= ${at.toISOString()}::timestamptz
     order by expires_at, id
     limit 100
     for update skip locked
  `;
  for (const row of rows) {
    await transaction`
      select private.release_usage_reservation_atomic(
        ${row.user_id}::uuid, ${row.id}::uuid, 'expired'::text
      )
    `;
  }
}

async function deliverBillingOutbox(transaction: SqlTransaction, at: Date, environment: (name: string) => string | undefined): Promise<void> {
  const endpoint = requiredHttpsUrl(environment("ALTERITY_CONTROL_PLANE_URL"));
  const token = requiredSecret(environment("ALTERITY_SWARA_SERVICE_TOKEN"));
  const rows = await transaction<{ id: string; user_id: string; event_type: string; payload: Record<string, unknown>; idempotency_key: string }>`
    select id, user_id, event_type, payload, idempotency_key
      from private.billing_outbox
     where status in ('pending', 'retrying')
       and next_attempt_at <= ${at.toISOString()}::timestamptz
       and attempt_count < max_attempts
     order by next_attempt_at, created_at, id
     limit 25
     for update skip locked
  `;
  for (const row of rows) {
    const attempt = await alterityRequest(endpoint, token, row.event_type === "usage.committed" ? "commit_usage" : row.event_type, row.payload, row.idempotency_key);
    const settled = settlement(attempt);
    await transaction`
      update private.billing_outbox
         set status = 'delivered', attempt_count = attempt_count + 1,
             last_attempt_at = ${at.toISOString()}::timestamptz,
             delivered_at = ${at.toISOString()}::timestamptz,
             locked_at = null, lock_expires_at = null,
             last_error_code = null, last_error_message = null,
             updated_at = ${at.toISOString()}::timestamptz
       where id = ${row.id}::uuid
         and status in ('pending', 'retrying')
    `;
    if (settled && row.event_type === "usage.committed") {
      await transaction`
        update private.usage_events
           set alterity_receipt_id = ${settled.receiptId},
               billed_amount_micros = ${settled.amountMicros},
               billed_currency_code = ${settled.currency},
               settled_at = ${at.toISOString()}::timestamptz
         where id = (${row.payload}->>'usage_event_id')::uuid
           and alterity_receipt_id is null
      `;
    }
  }
}

async function refreshEntitlements(transaction: SqlTransaction, at: Date, environment: (name: string) => string | undefined): Promise<void> {
  const endpoint = requiredHttpsUrl(environment("ALTERITY_CONTROL_PLANE_URL"));
  const token = requiredSecret(environment("ALTERITY_SWARA_SERVICE_TOKEN"));
  const links = await transaction<{ user_id: string; external_customer_id: string }>`
    select user_id, external_customer_id
      from private.billing_links
     where link_status in ('pending', 'active')
     order by updated_at asc
     limit 25
     for update skip locked
  `;
  for (const link of links) {
    const body = await alterityRequest(endpoint, token, "refresh_entitlements", {
      external_customer_id: link.external_customer_id,
    }, `entitlements:${link.user_id}:${at.toISOString().slice(0, 13)}`);
    const entitlement = projectEntitlement(body, at);
    await transaction`
      insert into private.entitlement_snapshots (
        user_id, plan_code, subscription_status, capabilities, limits, valid_until, source_version, refreshed_at
      ) values (
        ${link.user_id}::uuid, ${entitlement.planCode}, ${entitlement.subscriptionStatus},
        ${JSON.stringify(entitlement.capabilities)}::jsonb, ${JSON.stringify(entitlement.limits)}::jsonb,
        ${entitlement.validUntil.toISOString()}::timestamptz, ${entitlement.sourceVersion}, ${at.toISOString()}::timestamptz
      ) on conflict (user_id, source_version) do update set
        plan_code = excluded.plan_code, subscription_status = excluded.subscription_status,
        capabilities = excluded.capabilities, limits = excluded.limits,
        valid_until = excluded.valid_until, refreshed_at = excluded.refreshed_at
    `;
    await transaction`
      update private.billing_links set link_status = 'active', updated_at = ${at.toISOString()}::timestamptz
       where user_id = ${link.user_id}::uuid
    `;
  }
}

async function dispatchVaultIngestion(transaction: SqlTransaction, envelope: Envelope, environment: (name: string) => string | undefined): Promise<void> {
  const endpoint = requiredHttpsUrl(environment("SWARA_VAULT_INGESTION_URL"));
  const rows = await transaction<{ document_id: string; user_id: string; sha256: string; mime_type: string; size_bytes: number; storage_bucket: string; storage_path: string }>`
    select * from private.prepare_vault_ingestion(${envelope.job_id}::uuid)
  `;
  const document = rows[0];
  if (!document) return;
  const body = await postJson(endpoint, {
    document_id: document.document_id, user_id: document.user_id, sha256: document.sha256,
    mime_type: document.mime_type, size_bytes: document.size_bytes,
    storage_bucket: document.storage_bucket, storage_path: document.storage_path,
  }, environment("SWARA_VAULT_INGESTION_TOKEN"));
  const result = projectIngestionResult(body);
  await transaction`
    select private.complete_vault_document_processing(
      ${document.document_id}::uuid, ${document.sha256}::text,
      ${result.status}::text, ${result.errorCode}::text
    )
  `;
}

async function failStuckVaultIngestion(transaction: SqlTransaction, at: Date): Promise<void> {
  const rows = await transaction<{ id: string; sha256: string }>`
    select document_id as id, sha256 from private.select_stuck_vault_ingestion(${at.toISOString()}::timestamptz)
  `;
  for (const row of rows) {
    await transaction`select private.complete_vault_document_processing(${row.id}::uuid, ${row.sha256}::text, 'failed'::text, 'ingestion_timeout'::text)`;
  }
}

async function purgeExpiredArtifacts(transaction: SqlTransaction, at: Date, environment: (name: string) => string | undefined): Promise<void> {
  const rows = await transaction<{ artifact_id: string; lease_token: string; storage_bucket: string; storage_path: string }>`
    select artifact_id, lease_token, storage_bucket, storage_path
      from private.claim_expired_task_artifacts(25, 300, ${at.toISOString()}::timestamptz)
  `;
  for (const row of rows) {
    try {
      await deleteStorageObject(row.storage_bucket, row.storage_path, environment);
      await transaction`select private.complete_task_artifact_purge(${row.artifact_id}::uuid, ${row.lease_token}::uuid)`;
    } catch {
      await transaction`select private.fail_task_artifact_purge(${row.artifact_id}::uuid, ${row.lease_token}::uuid, 'storage_delete_failed'::text, false)`;
    }
  }
}

async function processAccountExport(transaction: SqlTransaction, envelope: Envelope, environment: (name: string) => string | undefined): Promise<void> {
  const rows = await transaction<{ request_id: string; user_id: string; payload: Record<string, unknown> }>`
    select * from private.prepare_account_export(${envelope.job_id}::uuid)
  `;
  const exportRow = rows[0];
  if (!exportRow || Object.keys(exportRow.payload).length === 0) return;
  const path = `${exportRow.user_id}/${exportRow.request_id}/export.json`;
  await putStorageObject("account-exports", path, new TextEncoder().encode(JSON.stringify(exportRow.payload)), "application/json", environment);
  await transaction`select private.complete_account_export(${exportRow.request_id}::uuid, ${path}::text)`;
}

async function cleanupExpiredExports(transaction: SqlTransaction, environment: (name: string) => string | undefined): Promise<void> {
  const rows = await transaction<{ request_id: string; user_id: string; storage_path: string }>`
    select request_id, user_id, storage_path from private.claim_expired_account_exports(100)
  `;
  for (const row of rows) await deleteStorageObject("account-exports", row.storage_path, environment);
}

async function completeAccountDeletion(transaction: SqlTransaction, envelope: Envelope, environment: (name: string) => string | undefined): Promise<void> {
  const rows = await transaction<{ user_id: string; status: string }>`
    select user_id, status from private.account_deletion_requests where id = ${envelope.job_id}::uuid for update
  `;
  const request = rows[0];
  if (!request || request.status === "completed") return;
  await transaction`update private.account_deletion_requests set status = 'revoking', started_at = coalesce(started_at, now()) where id = ${envelope.job_id}::uuid`;
  await transaction`select private.revoke_account_sessions(${request.user_id}::uuid)`;
  const objects = await transaction<{ storage_bucket: string; storage_path: string }>`
    select storage_bucket, storage_path from private.list_account_storage_objects(${request.user_id}::uuid)
  `;
  for (const object of objects) await deleteStorageObject(object.storage_bucket, object.storage_path, environment);
  const adminBase = requiredHttpsUrl(environment("SUPABASE_URL"));
  const adminKey = requiredSecret(environment("SWARA_AUTH_ADMIN_KEY"));
  const response = await fetch(`${adminBase}/auth/v1/admin/users/${encodeURIComponent(request.user_id)}`, {
    method: "DELETE", headers: { authorization: `Bearer ${adminKey}`, apikey: adminKey },
  });
  if (!response.ok && response.status !== 404) throw new Error("Auth deletion failed");
}

async function alterityRequest(endpoint: string, token: string, action: string, payload: Record<string, unknown>, idempotencyKey: string): Promise<Record<string, unknown>> {
  return await postJson(endpoint, { action, product: "swara", ...payload }, token, { "idempotency-key": idempotencyKey, "x-alterity-product": "swara" });
}

async function postJson(endpoint: string, body: Record<string, unknown>, token?: string, extra: Record<string, string> = {}): Promise<Record<string, unknown>> {
  const response = await fetch(endpoint, { method: "POST", headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}), ...extra }, body: JSON.stringify(body) });
  if (!response.ok) throw new Error("External worker request failed");
  const value = await response.json();
  if (!isObject(value)) throw new Error("External worker response was invalid");
  return value;
}

async function deleteStorageObject(bucket: string, path: string, environment: (name: string) => string | undefined): Promise<void> {
  const base = requiredHttpsUrl(environment("SUPABASE_URL"));
  const key = requiredSecret(environment("SWARA_STORAGE_ADMIN_KEY"));
  const response = await fetch(`${base}/storage/v1/object/${encodeURIComponent(bucket)}/${path.split("/").map(encodeURIComponent).join("/")}`, { method: "DELETE", headers: { authorization: `Bearer ${key}`, apikey: key } });
  if (!response.ok && response.status !== 404) throw new Error("Storage delete failed");
}

async function putStorageObject(bucket: string, path: string, bytes: Uint8Array, contentType: string, environment: (name: string) => string | undefined): Promise<void> {
  const base = requiredHttpsUrl(environment("SUPABASE_URL"));
  const key = requiredSecret(environment("SWARA_STORAGE_ADMIN_KEY"));
  const response = await fetch(`${base}/storage/v1/object/${encodeURIComponent(bucket)}/${path.split("/").map(encodeURIComponent).join("/")}`, { method: "POST", headers: { authorization: `Bearer ${key}`, apikey: key, "content-type": contentType, "x-upsert": "true" }, body: bytes.buffer as ArrayBuffer });
  if (!response.ok) throw new Error("Storage upload failed");
}

function requiredSecret(value: string | undefined): string {
  if (!value || value.length < 16) throw new Error("Required worker secret is not configured");
  return value;
}

function requiredHttpsUrl(value: string | undefined): string {
  if (!value) throw new Error("Required worker endpoint is not configured");
  const parsed = new URL(value);
  if (parsed.protocol !== "https:") throw new Error("Worker endpoint must use HTTPS");
  return parsed.toString();
}

type Settlement = { receiptId: string; amountMicros: number; currency: string };
function settlement(value: Record<string, unknown>): Settlement | null {
  const receiptId = value.receipt_id ?? value.receiptId;
  const amount = value.amount_micros ?? value.amountMicros;
  const currency = value.currency ?? value.currency_code;
  return typeof receiptId === "string" && typeof amount === "number" && Number.isSafeInteger(amount) && amount >= 0 && typeof currency === "string" && /^[A-Z]{3}$/.test(currency)
    ? { receiptId, amountMicros: amount, currency }
    : null;
}

function projectEntitlement(value: Record<string, unknown>, at: Date): { planCode: string; subscriptionStatus: string; capabilities: Record<string, unknown>; limits: Record<string, unknown>; validUntil: Date; sourceVersion: string } {
  const source = isObject(value.entitlement) ? value.entitlement : value;
  const plan = source.plan_code ?? source.plan;
  const status = source.subscription_status ?? source.status ?? (source.enabled === false ? "cancelled" : "active");
  const valid = source.valid_until ?? source.validUntil;
  const sourceVersion = source.source_version ?? source.sourceVersion;
  if (typeof plan !== "string" || !/^[a-z0-9][a-z0-9._-]{0,127}$/.test(plan) || typeof status !== "string" || !["none", "trialing", "active", "past_due", "paused", "unpaid", "cancelled", "expired", "incomplete"].includes(status) || !isObject(source.capabilities) || !isObject(source.limits) || typeof sourceVersion !== "string") throw new Error("Entitlement response was invalid");
  const validUntil = typeof valid === "string" ? new Date(valid) : new Date(at.getTime() + 3600_000);
  if (Number.isNaN(validUntil.getTime()) || validUntil <= at) throw new Error("Entitlement expiry was invalid");
  return { planCode: plan, subscriptionStatus: status, capabilities: source.capabilities, limits: source.limits, validUntil, sourceVersion };
}

function projectIngestionResult(value: Record<string, unknown>): { status: "ready" | "failed"; errorCode: string | null } {
  const status = value.status;
  if (status === "ready") return { status, errorCode: null };
  if (status === "failed" && typeof value.error_code === "string" && /^[a-z0-9][a-z0-9_.:-]{0,127}$/.test(value.error_code)) return { status, errorCode: value.error_code };
  throw new Error("Ingestion response was invalid");
}

async function requestedLimit(request: Request): Promise<number | null> {
  const length = request.headers.get("content-length");
  if (length === "0" || length === null) return MAX_BATCH;
  try {
    const body = await request.json() as unknown;
    if (!isObject(body) || body.limit === undefined) return MAX_BATCH;
    return typeof body.limit === "number" && Number.isSafeInteger(body.limit) && body.limit >= 1 && body.limit <= MAX_BATCH ? body.limit : null;
  } catch {
    return null;
  }
}

function constantTimeEqual(actual: string | null, expected: string | undefined): boolean {
  if (!actual || !expected) return false;
  const a = new TextEncoder().encode(actual);
  const b = new TextEncoder().encode(expected);
  if (a.byteLength !== b.byteLength) return false;
  let difference = 0;
  for (let index = 0; index < a.length; index += 1) difference |= a[index] ^ b[index];
  return difference === 0;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}
