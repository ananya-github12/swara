import type { SqlRow, SqlTransaction } from "../_shared/database.ts";
import type { CorsOptions } from "../_shared/types.ts";
import {
  boundedTrimmedString,
  strictObject,
  type UnknownRecord,
  uuid,
  validateVaultStoragePath,
  VAULT_ORIGINALS_BUCKET,
  vaultStorageBucket,
  ValidationError,
} from "../_shared/validation.ts";

const VAULT_FINALIZE_UPLOAD_FIELDS = ["document_id", "sha256"] as const;
const IDEMPOTENCY_KEY_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]*$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const FINALIZED_VAULT_STATUSES = ["processing", "ready"] as const;

export interface VaultFinalizeUploadInput {
  readonly document_id: string;
  readonly sha256: string;
}

export interface VaultFinalizeUploadResult {
  readonly document_id: string;
  readonly storage_bucket: typeof VAULT_ORIGINALS_BUCKET;
  readonly storage_path: string;
  readonly status: (typeof FINALIZED_VAULT_STATUSES)[number];
  readonly duplicate: boolean;
  readonly next_step: string;
}

export class VaultFinalizeConflictError extends Error {
  constructor() {
    super("The Vault upload cannot be finalized from its current state.");
    this.name = "VaultFinalizeConflictError";
  }
}

export class VaultFinalizeResultError extends Error {
  constructor() {
    super("The database returned an invalid Vault finalization result.");
    this.name = "VaultFinalizeResultError";
  }
}

/** Parse exact extension origins without a wildcard or an implicit web origin. */
export function vaultFinalizeUploadCorsOptions(value: string | undefined): CorsOptions {
  if (typeof value !== "string" || value.trim() === "") {
    throw new TypeError("SWARA_EXTENSION_ORIGINS is required");
  }

  const origins = value.split(",").map((origin) => origin.trim());
  if (origins.length === 0 || origins.some((origin) => origin === "" || origin === "*")) {
    throw new TypeError("SWARA_EXTENSION_ORIGINS must contain exact origins");
  }
  if (new Set(origins).size !== origins.length || origins.some((origin) => !isExactOrigin(origin))) {
    throw new TypeError("SWARA_EXTENSION_ORIGINS contains an invalid origin");
  }

  return Object.freeze({
    allowedOrigins: Object.freeze(origins),
    allowedMethods: Object.freeze(["POST", "OPTIONS"] as const),
    allowedHeaders: Object.freeze([
      "authorization",
      "apikey",
      "content-type",
      "idempotency-key",
      "x-client-info",
      "x-correlation-id",
    ]),
    exposedHeaders: Object.freeze(["x-correlation-id"]),
    allowCredentials: true,
    maxAgeSeconds: 600,
  });
}

/** No caller may provide an owner, Storage bucket, Storage path, or object ID. */
export function parseVaultFinalizeUploadInput(value: unknown): VaultFinalizeUploadInput {
  const input = strictObject<UnknownRecord>(value, VAULT_FINALIZE_UPLOAD_FIELDS, {
    label: "vault-finalize-upload body",
    requiredKeys: VAULT_FINALIZE_UPLOAD_FIELDS,
  });
  return Object.freeze({
    document_id: canonicalUuid(input.document_id, "document_id"),
    sha256: canonicalSha256(input.sha256),
  });
}

/** The idempotency key is header-only and matches M022/M023's 8..200 rule. */
export function requireVaultFinalizeUploadIdempotencyKey(headers: Headers): string {
  const value = headers.get("idempotency-key");
  if (value === null) {
    throw new ValidationError("idempotency-key header is required", "idempotency-key");
  }
  if (
    value.length < 8 ||
    value.length > 200 ||
    value.trim() !== value ||
    !IDEMPOTENCY_KEY_PATTERN.test(value)
  ) {
    throw new ValidationError("idempotency-key header is invalid", "idempotency-key");
  }
  return value;
}

/**
 * Invoke the M022/M023 SECURITY DEFINER boundary.  It—not this handler—checks
 * the owned, pending Storage object and changes Vault metadata state.
 */
export async function finalizeVaultUploadInTransaction(
  transaction: SqlTransaction,
  authenticatedUserId: string,
  input: VaultFinalizeUploadInput,
  idempotencyKey: string,
): Promise<VaultFinalizeUploadResult> {
  const userId = canonicalUuid(authenticatedUserId, "authenticated_user_id");
  const rows = await transaction<SqlRow>`
    select document_id, storage_bucket, storage_path, status, duplicate
      from private.finalize_vault_upload(
        ${userId}::uuid,
        ${input.document_id}::uuid,
        ${input.sha256}::text,
        ${idempotencyKey}::text
      )
  `;
  return projectVaultFinalizeUploadResult(rows, userId);
}

/** Only safe state signals are permitted to become a public HTTP 409. */
export function isSafeVaultFinalizeConflict(error: unknown): boolean {
  if (error instanceof VaultFinalizeConflictError) return true;
  const code = !!error && typeof error === "object" ? (error as { code?: unknown }).code : undefined;
  return code === "22023" || code === "23505" || code === "42501" || code === "P0001";
}

function projectVaultFinalizeUploadResult(
  rows: readonly SqlRow[],
  authenticatedUserId: string,
): VaultFinalizeUploadResult {
  if (rows.length !== 1 || !isRecord(rows[0])) throw new VaultFinalizeConflictError();
  const row = rows[0];
  const documentId = resultUuid(row.document_id, "document_id");
  const storageBucket = resultOriginalsBucket(row.storage_bucket);
  const storagePath = resultStoragePath(row.storage_path, authenticatedUserId, documentId);
  const status = resultStatus(row.status);
  if (typeof row.duplicate !== "boolean") throw new VaultFinalizeResultError();

  return Object.freeze({
    document_id: documentId,
    storage_bucket: storageBucket,
    storage_path: storagePath,
    status,
    duplicate: row.duplicate,
    next_step: status === "ready"
      ? "The document is already ready in your Vault."
      : "Vault processing has started; read the document metadata for its current status.",
  });
}

function canonicalSha256(value: unknown): string {
  const digest = boundedTrimmedString(value, {
    minLength: 64,
    maxLength: 64,
    normalize: false,
    label: "sha256",
  });
  if (value !== digest || !SHA256_PATTERN.test(digest)) {
    throw new ValidationError("sha256 must be a lowercase SHA-256 digest", "sha256");
  }
  return digest;
}

function canonicalUuid(value: unknown, label: string): string {
  if (typeof value !== "string") throw new ValidationError(`${label} must be a UUID`, label);
  const parsed = uuid(value, label);
  if (value !== parsed) throw new ValidationError(`${label} must be canonical`, label);
  return parsed;
}

function resultUuid(value: unknown, label: string): string {
  try {
    return canonicalUuid(value, label);
  } catch {
    throw new VaultFinalizeResultError();
  }
}

function resultOriginalsBucket(value: unknown): typeof VAULT_ORIGINALS_BUCKET {
  try {
    if (typeof value !== "string") throw new TypeError();
    const bucket = vaultStorageBucket(value, "storage_bucket");
    if (value !== bucket || bucket !== VAULT_ORIGINALS_BUCKET) throw new TypeError();
    return VAULT_ORIGINALS_BUCKET;
  } catch {
    throw new VaultFinalizeResultError();
  }
}

function resultStoragePath(value: unknown, userId: string, documentId: string): string {
  try {
    return validateVaultStoragePath(value, userId, documentId);
  } catch {
    throw new VaultFinalizeResultError();
  }
}

function resultStatus(value: unknown): (typeof FINALIZED_VAULT_STATUSES)[number] {
  if (typeof value !== "string" || !FINALIZED_VAULT_STATUSES.includes(value as never)) {
    throw new VaultFinalizeConflictError();
  }
  return value as (typeof FINALIZED_VAULT_STATUSES)[number];
}

function isRecord(value: unknown): value is SqlRow {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isExactOrigin(origin: string): boolean {
  if (/^chrome-extension:\/\/[a-p]{32}$/.test(origin)) return true;
  try {
    const parsed = new URL(origin);
    return (parsed.protocol === "https:" || parsed.protocol === "http:") &&
      parsed.origin === origin && !parsed.username && !parsed.password;
  } catch {
    return false;
  }
}
