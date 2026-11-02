import type { SqlTransaction } from "../_shared/database.ts";
import { projectBillingEntitlement, type BillingEntitlementProjection } from "../_shared/billing-projection.ts";
import { HttpError } from "../_shared/http.ts";
import { boundedTrimmedString, enumValue, strictObject, type UnknownRecord, uuid, ValidationError } from "../_shared/validation.ts";

const EVENT_TYPE_PATTERN = /^[a-z][a-z0-9._-]*$/u;
const PROPERTY_PATTERN = /^[a-z][a-z0-9._-]{0,63}$/u;
const SOURCE_VERSION_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/u;
const RFC3339_UTC_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/u;
const SUPPORTED_EVENT_TYPES = ["entitlement.updated"] as const;
const LINK_STATUSES = ["pending", "active", "suspended", "revoked"] as const;
const SUBSCRIPTION_STATUSES = ["none", "trialing", "active", "past_due", "paused", "unpaid", "cancelled", "expired", "incomplete"] as const;

export interface AlterityBillingEvent {
  readonly eventType: typeof SUPPORTED_EVENT_TYPES[number];
  readonly projection: BillingEntitlementProjection;
}

export interface AlterityBillingWebhookProof {
  readonly bodySha256: string;
  readonly eventId: string;
  readonly signatureVersion: "v1";
  readonly timestamp: number;
}

export type WebhookClaimOutcome = "first_delivery" | "in_progress" | "terminal_replay" | "hash_conflict";

interface ClaimRow {
  readonly claim_outcome?: unknown;
  readonly status?: unknown;
  readonly attempt_count?: unknown;
}

export class AlterityWebhookDatabaseError extends Error {
  constructor() {
    super("Alterity webhook database operation failed.");
    this.name = "AlterityWebhookDatabaseError";
  }
}

export function parseAlterityBillingEvent(raw: unknown): AlterityBillingEvent {
  const body = strictObject<UnknownRecord>(raw, ["type", "event_type", "data"], {
    requiredKeys: ["data"],
    label: "billing webhook body",
  });
  const typeValue = body.type ?? body.event_type;
  const eventType = boundedTrimmedString(typeValue, {
    minLength: 1,
    maxLength: 80,
    normalize: false,
    label: "event_type",
  });
  if (eventType !== eventType.toLowerCase() || !EVENT_TYPE_PATTERN.test(eventType)) {
    throw new ValidationError("event_type is invalid", "event_type");
  }
  if (body.type !== undefined && body.event_type !== undefined && body.type !== body.event_type) {
    throw new ValidationError("type and event_type must match", "event_type");
  }
  if (!SUPPORTED_EVENT_TYPES.includes(eventType as typeof SUPPORTED_EVENT_TYPES[number])) {
    throw new ValidationError("event_type is unsupported", "event_type");
  }
  return Object.freeze({
    eventType: eventType as typeof SUPPORTED_EVENT_TYPES[number],
    projection: parseProjection(body.data),
  });
}

function parseProjection(value: unknown): BillingEntitlementProjection {
  const data = strictObject<UnknownRecord>(value, [
    "user_id",
    "customer_reference",
    "link_status",
    "plan_code",
    "subscription_status",
    "capabilities",
    "limits",
    "valid_until",
    "source_version",
  ], {
    requiredKeys: [
      "user_id",
      "customer_reference",
      "link_status",
      "plan_code",
      "subscription_status",
      "capabilities",
      "limits",
      "valid_until",
      "source_version",
    ],
    label: "billing entitlement data",
  });
  return Object.freeze({
    userId: uuid(data.user_id, "user_id"),
    customerReference: requiredOpaqueReference(data.customer_reference, "customer_reference"),
    linkStatus: enumValue(data.link_status, LINK_STATUSES, "link_status"),
    planCode: requiredPattern(data.plan_code, /^[a-z0-9][a-z0-9._-]{0,127}$/u, "plan_code", 128),
    subscriptionStatus: enumValue(data.subscription_status, SUBSCRIPTION_STATUSES, "subscription_status"),
    capabilities: boundedProjectionObject(data.capabilities, "capabilities"),
    limits: boundedProjectionObject(data.limits, "limits"),
    validUntil: canonicalTimestamp(data.valid_until),
    sourceVersion: requiredPattern(data.source_version, SOURCE_VERSION_PATTERN, "source_version", 128),
  });
}

function requiredOpaqueReference(value: unknown, label: string): string {
  const result = boundedTrimmedString(value, { minLength: 1, maxLength: 512, normalize: false, label });
  if (result !== value || /[\u0000-\u001f\u007f]/u.test(result)) {
    throw new ValidationError(`${label} is invalid`, label);
  }
  return result;
}

function requiredPattern(value: unknown, pattern: RegExp, label: string, maxLength: number): string {
  const result = boundedTrimmedString(value, { minLength: 1, maxLength, normalize: false, label });
  if (result !== value || !pattern.test(result)) throw new ValidationError(`${label} is invalid`, label);
  return result;
}

function canonicalTimestamp(value: unknown): string {
  const result = boundedTrimmedString(value, { minLength: 20, maxLength: 24, normalize: false, label: "valid_until" });
  if (result !== value || !RFC3339_UTC_PATTERN.test(result) || Number.isNaN(Date.parse(result))) {
    throw new ValidationError("valid_until is invalid", "valid_until");
  }
  return result;
}

function boundedProjectionObject(value: unknown, label: string): Record<string, unknown> {
  let propertyCount = 0;
  const parse = (candidate: unknown, depth: number): unknown => {
    if (candidate === null || typeof candidate === "boolean") return candidate;
    if (typeof candidate === "string") {
      return boundedTrimmedString(candidate, { minLength: 0, maxLength: 256, normalize: true, allowEmpty: true, label });
    }
    if (typeof candidate === "number") {
      if (!Number.isFinite(candidate) || Math.abs(candidate) > 1_000_000_000_000) throw new ValidationError(`${label} is invalid`, label);
      return candidate;
    }
    if (candidate === null || typeof candidate !== "object" || Array.isArray(candidate) || depth >= 4) {
      throw new ValidationError(`${label} is invalid`, label);
    }
    const record = strictObject<UnknownRecord>(candidate, Object.keys(candidate as UnknownRecord), { label });
    const output: Record<string, unknown> = {};
    for (const [key, nested] of Object.entries(record)) {
      propertyCount += 1;
      if (propertyCount > 64 || !PROPERTY_PATTERN.test(key)) throw new ValidationError(`${label} is invalid`, label);
      output[key] = parse(nested, depth + 1);
    }
    return Object.freeze(output);
  };
  const result = parse(value, 0);
  if (result === null || typeof result !== "object" || Array.isArray(result)) throw new ValidationError(`${label} is invalid`, label);
  return result as Record<string, unknown>;
}

export async function claimAlterityWebhook(
  transaction: SqlTransaction,
  proof: AlterityBillingWebhookProof,
  event: AlterityBillingEvent,
): Promise<WebhookClaimOutcome> {
  try {
    const rows = await transaction<ClaimRow>`
      select claim_outcome, status, attempt_count
        from private.claim_alterity_webhook(
          ${proof.eventId}::text,
          ${proof.bodySha256}::text,
          to_timestamp(${proof.timestamp}::double precision),
          ${event.eventType}::text
        )
    `;
    if (rows.length !== 1) throw new AlterityWebhookDatabaseError();
    const outcome = rows[0].claim_outcome;
    if (outcome !== "first_delivery" && outcome !== "in_progress" && outcome !== "terminal_replay" && outcome !== "hash_conflict") {
      throw new AlterityWebhookDatabaseError();
    }
    return outcome;
  } catch (error) {
    if (error instanceof AlterityWebhookDatabaseError) throw error;
    throw new AlterityWebhookDatabaseError();
  }
}

/**
 * Alterity remains authoritative for billing. The current Swara migrations
 * provide a bounded receipt ledger, but no local entitlement projection or
 * provider-sync RPC. A verified first delivery is therefore acknowledged only
 * after its digest/metadata receipt is finalized; the raw body is never stored.
 */
export async function finalizeAlterityWebhook(
  transaction: SqlTransaction,
  proof: AlterityBillingWebhookProof,
): Promise<void> {
  try {
    const rows = await transaction`
      select status, finalized, processed_at
        from private.finalize_alterity_webhook(
          ${proof.eventId}::text,
          ${proof.bodySha256}::text,
          'processed'::text,
          null::text
        )
    `;
    if (rows.length !== 1 || rows[0].finalized !== true || rows[0].status !== "processed") {
      throw new AlterityWebhookDatabaseError();
    }
  } catch (error) {
    if (error instanceof AlterityWebhookDatabaseError) throw error;
    throw new AlterityWebhookDatabaseError();
  }
}

export async function projectAlterityBillingEvent(
  transaction: SqlTransaction,
  event: AlterityBillingEvent,
): Promise<void> {
  try {
    await projectBillingEntitlement(transaction, event.projection);
  } catch {
    throw new AlterityWebhookDatabaseError();
  }
}

export function toAlterityWebhookHttpError(error: unknown): HttpError {
  if (error instanceof HttpError) return error;
  if (error instanceof ValidationError) return new HttpError(400, "bad_request", "The billing webhook body is invalid.");
  if (error instanceof AlterityWebhookDatabaseError) return new HttpError(500, "internal_error", "The billing webhook could not be recorded.");
  return new HttpError(500, "internal_error", "The billing webhook could not be recorded.");
}
