import type { SqlRow, SqlTransaction } from "../_shared/database.ts";
import type { CorsOptions } from "../_shared/types.ts";
import { strictObject, type UnknownRecord, uuid, ValidationError } from "../_shared/validation.ts";

const IDEMPOTENCY_KEY_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]*$/;

export interface AccountExportResult {
  readonly request_id: string;
}

export class AccountExportResultError extends Error {
  constructor() {
    super("The database returned an invalid account export result.");
    this.name = "AccountExportResultError";
  }
}

export function accountExportCorsOptions(value: string | undefined): CorsOptions {
  return lifecycleCorsOptions(value);
}

/** The owner is derived exclusively from the verified JWT. */
export function parseAccountExportInput(value: unknown): Record<never, never> {
  strictObject<UnknownRecord>(value, [], { label: "account export body" });
  return Object.freeze({}) as Record<never, never>;
}

/** Matches the final lifecycle gateway's 8..160-character key contract. */
export function requireAccountExportIdempotencyKey(headers: Headers): string {
  return requireLifecycleIdempotencyKey(headers);
}

export async function requestAccountExportInTransaction(
  transaction: SqlTransaction,
  authenticatedUserId: string,
  idempotencyKey: string,
): Promise<AccountExportResult> {
  const userId = canonicalUuid(authenticatedUserId, "authenticated_user_id");
  const rows = await transaction<SqlRow>`
    select private.request_account_export(
      ${userId}::uuid,
      ${idempotencyKey}::text
    ) as request_id
  `;
  return projectResult(rows);
}

export function lifecycleCorsOptions(value: string | undefined): CorsOptions {
  if (typeof value !== "string" || value.trim() === "") throw new TypeError("SWARA_EXTENSION_ORIGINS is required");
  const origins = value.split(",").map((origin) => origin.trim());
  if (origins.length === 0 || origins.some((origin) => origin === "" || origin === "*") ||
    new Set(origins).size !== origins.length || origins.some((origin) => !isExactOrigin(origin))) {
    throw new TypeError("SWARA_EXTENSION_ORIGINS contains invalid origins");
  }
  return Object.freeze({
    allowedOrigins: Object.freeze(origins),
    allowedMethods: Object.freeze(["POST", "OPTIONS"] as const),
    allowedHeaders: Object.freeze([
      "authorization", "apikey", "content-type", "idempotency-key", "x-client-info", "x-correlation-id",
    ]),
    exposedHeaders: Object.freeze(["x-correlation-id"]),
    allowCredentials: true,
    maxAgeSeconds: 600,
  });
}

export function requireLifecycleIdempotencyKey(headers: Headers): string {
  const value = headers.get("idempotency-key");
  if (value === null || value.length < 8 || value.length > 160 || value.trim() !== value ||
    !IDEMPOTENCY_KEY_PATTERN.test(value)) {
    throw new ValidationError("idempotency-key header is invalid", "idempotency-key");
  }
  return value;
}

export function canonicalUuid(value: unknown, label: string): string {
  if (typeof value !== "string") throw new ValidationError(`${label} must be a UUID`, label);
  const parsed = uuid(value, label);
  if (value !== parsed) throw new ValidationError(`${label} must be canonical`, label);
  return parsed;
}

function projectResult(rows: readonly SqlRow[]): AccountExportResult {
  if (rows.length !== 1 || !isRecord(rows[0])) throw new AccountExportResultError();
  try {
    return Object.freeze({ request_id: canonicalUuid(rows[0].request_id, "request_id") });
  } catch {
    throw new AccountExportResultError();
  }
}

function isRecord(value: unknown): value is SqlRow {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isExactOrigin(origin: string): boolean {
  if (/^chrome-extension:\/\/[a-p]{32}$/.test(origin)) return true;
  try {
    const parsed = new URL(origin);
    return (parsed.protocol === "https:" || parsed.protocol === "http:") && parsed.origin === origin && !parsed.username && !parsed.password;
  } catch {
    return false;
  }
}
