import type { SqlRow, SqlTransaction } from "../_shared/database.ts";
import type { CorsOptions } from "../_shared/types.ts";
import {
  boundedTrimmedString,
  enumValue,
  numberValue,
  safeVaultFilename,
  strictObject,
  type UnknownRecord,
  uuid,
  validateVaultStoragePath,
  VAULT_ORIGINALS_BUCKET,
  vaultStorageBucket,
  ValidationError,
} from "../_shared/validation.ts";

const VAULT_UPLOAD_INTENT_FIELDS = [
  "filename",
  "mime_type",
  "size_bytes",
  "sha256",
  "extraction_method",
] as const;

const IDEMPOTENCY_KEY_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]*$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;

/** This list deliberately mirrors M022's private function allowlist exactly. */
export const APPROVED_VAULT_MIME_TYPES = [
  "application/pdf",
  "application/msword",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  "application/vnd.ms-excel",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  "application/vnd.ms-powerpoint",
  "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  "application/vnd.oasis.opendocument.text",
  "application/vnd.oasis.opendocument.spreadsheet",
  "application/vnd.oasis.opendocument.presentation",
  "application/rtf",
  "application/epub+zip",
  "text/plain",
  "text/markdown",
  "text/csv",
  "text/rtf",
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/tiff",
] as const;

const EXTRACTION_METHODS = ["local", "ocr", "manual"] as const;
const VAULT_DOCUMENT_STATUSES = ["pending", "processing", "ready", "failed", "deleted"] as const;
const MAX_VAULT_UPLOAD_BYTES = 50 * 1024 * 1024;

export interface VaultUploadIntentInput {
  readonly filename: string;
  readonly mime_type: (typeof APPROVED_VAULT_MIME_TYPES)[number];
  readonly size_bytes: number;
  readonly sha256: string;
  readonly extraction_method: (typeof EXTRACTION_METHODS)[number];
}

export interface VaultUploadIntentResult {
  readonly document_id: string;
  readonly storage_bucket: typeof VAULT_ORIGINALS_BUCKET;
  readonly storage_path: string;
  readonly status: (typeof VAULT_DOCUMENT_STATUSES)[number];
  readonly duplicate: boolean;
  readonly next_step: string;
}

export class VaultUploadIntentResultError extends Error {
  constructor() {
    super("The database returned an invalid Vault upload intent result.");
    this.name = "VaultUploadIntentResultError";
  }
}

/** Parse exact extension origins without a wildcard or an implicit web origin. */
export function vaultUploadIntentCorsOptions(value: string | undefined): CorsOptions {
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

/**
 * The body is deliberately exact. `Idempotency-Key` is header-only, and a
 * caller cannot choose an owner, Storage bucket, or Storage path.
 */
export function parseVaultUploadIntentInput(value: unknown): VaultUploadIntentInput {
  const input = strictObject<UnknownRecord>(value, VAULT_UPLOAD_INTENT_FIELDS, {
    label: "vault-upload-intent body",
    requiredKeys: VAULT_UPLOAD_INTENT_FIELDS,
  });

  return Object.freeze({
    filename: canonicalFilename(input.filename),
    mime_type: enumValue(input.mime_type, APPROVED_VAULT_MIME_TYPES, "mime_type"),
    size_bytes: numberValue(input.size_bytes, {
      min: 1,
      max: MAX_VAULT_UPLOAD_BYTES,
      integer: true,
      label: "size_bytes",
    }),
    sha256: canonicalSha256(input.sha256),
    extraction_method: enumValue(input.extraction_method, EXTRACTION_METHODS, "extraction_method"),
  });
}

/** The idempotency contract matches the M022 8..200-character database rule. */
export function requireVaultUploadIntentIdempotencyKey(headers: Headers): string {
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

/** Execute M022's API-runtime-only upload-intent function in one transaction. */
export async function createVaultUploadIntentInTransaction(
  transaction: SqlTransaction,
  authenticatedUserId: string,
  input: VaultUploadIntentInput,
  idempotencyKey: string,
): Promise<VaultUploadIntentResult> {
  const userId = canonicalUuid(authenticatedUserId, "authenticated_user_id");
  const rows = await transaction<SqlRow>`
    select document_id, storage_bucket, storage_path, status, duplicate
      from private.create_vault_upload_intent(
        ${userId}::uuid,
        ${input.filename}::text,
        ${input.mime_type}::text,
        ${input.size_bytes}::bigint,
        ${input.sha256}::text,
        ${input.extraction_method}::text,
        ${idempotencyKey}::text
      )
  `;
  return projectVaultUploadIntentResult(rows, userId);
}

function projectVaultUploadIntentResult(
  rows: readonly SqlRow[],
  authenticatedUserId: string,
): VaultUploadIntentResult {
  if (rows.length !== 1 || !isRecord(rows[0])) throw new VaultUploadIntentResultError();
  const row = rows[0];
  const documentId = resultUuid(row.document_id, "document_id");
  const storageBucket = resultOriginalsBucket(row.storage_bucket);
  const storagePath = resultStoragePath(row.storage_path, authenticatedUserId, documentId);
  const status = resultStatus(row.status);
  if (typeof row.duplicate !== "boolean") throw new VaultUploadIntentResultError();

  return Object.freeze({
    document_id: documentId,
    storage_bucket: storageBucket,
    storage_path: storagePath,
    status,
    duplicate: row.duplicate,
    next_step: uploadIntentNextStep(status),
  });
}

function canonicalFilename(value: unknown): string {
  if (typeof value !== "string") {
    throw new ValidationError("filename must be a safe basename", "filename");
  }
  const filename = safeVaultFilename(value, "filename");
  if (value !== filename) {
    throw new ValidationError("filename must be canonical", "filename");
  }
  return filename;
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
    throw new VaultUploadIntentResultError();
  }
}

function resultOriginalsBucket(value: unknown): typeof VAULT_ORIGINALS_BUCKET {
  try {
    if (typeof value !== "string") throw new TypeError();
    const bucket = vaultStorageBucket(value, "storage_bucket");
    if (value !== bucket || bucket !== VAULT_ORIGINALS_BUCKET) throw new TypeError();
    return VAULT_ORIGINALS_BUCKET;
  } catch {
    throw new VaultUploadIntentResultError();
  }
}

function resultStoragePath(value: unknown, userId: string, documentId: string): string {
  try {
    return validateVaultStoragePath(value, userId, documentId);
  } catch {
    throw new VaultUploadIntentResultError();
  }
}

function resultStatus(value: unknown): (typeof VAULT_DOCUMENT_STATUSES)[number] {
  if (typeof value !== "string" || !VAULT_DOCUMENT_STATUSES.includes(value as never)) {
    throw new VaultUploadIntentResultError();
  }
  return value as (typeof VAULT_DOCUMENT_STATUSES)[number];
}

function uploadIntentNextStep(status: (typeof VAULT_DOCUMENT_STATUSES)[number]): string {
  if (status === "pending") {
    return "Upload the file to the returned vault-originals path, then call vault-finalize-upload.";
  }
  if (status === "processing") {
    return "The matching Vault document is already processing; do not upload a replacement.";
  }
  if (status === "ready") {
    return "The matching Vault document is already ready; no upload is needed.";
  }
  if (status === "failed") {
    return "The matching Vault document needs attention before another upload can be finalized.";
  }
  return "This upload intent is no longer active; create a new upload intent before uploading again.";
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
