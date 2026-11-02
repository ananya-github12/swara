/** Dependency-free validation and hashing helpers for Swara Edge Functions. */

export const VAULT_ORIGINALS_BUCKET = "vault-originals" as const;
export const VAULT_DERIVED_BUCKET = "vault-derived" as const;
export const LEGACY_DOCUMENTS_BUCKET = "documents" as const;

export type UnknownRecord = Record<string, unknown>;
export type VaultStorageBucket =
  | typeof VAULT_ORIGINALS_BUCKET
  | typeof VAULT_DERIVED_BUCKET;

export class ValidationError extends Error {
  readonly code = "validation_error" as const;
  readonly field?: string;

  constructor(message = "Invalid input", field?: string) {
    super(message);
    this.name = "ValidationError";
    this.field = field;
  }
}

function invalid(message: string, field?: string): never {
  throw new ValidationError(message, field);
}

function isPlainObject(value: unknown): value is UnknownRecord {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

export interface StrictObjectOptions {
  readonly requiredKeys?: readonly string[];
  readonly label?: string;
}

/** Validate a JSON object and reject every key outside the explicit allowlist. */
export function strictObject<T extends UnknownRecord = UnknownRecord>(
  value: unknown,
  allowedKeys: readonly string[],
  options: StrictObjectOptions = {},
): T {
  const label = options.label ?? "object";
  if (!isPlainObject(value)) invalid(`${label} must be an object`, label);

  const allowed = new Set(allowedKeys);
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) invalid(`${label} contains an unknown field`, key);
  }
  for (const key of options.requiredKeys ?? []) {
    if (!Object.prototype.hasOwnProperty.call(value, key)) {
      invalid(`${label} is missing a required field`, key);
    }
  }
  return value as T;
}

export const validateObject = strictObject;

export interface BoundedStringOptions {
  readonly minLength?: number;
  readonly maxLength?: number;
  readonly normalize?: boolean;
  readonly allowEmpty?: boolean;
  readonly label?: string;
}

/** Trim a string, optionally normalize it, and enforce a bounded length. */
export function boundedTrimmedString(
  value: unknown,
  options: BoundedStringOptions = {},
): string {
  const label = options.label ?? "string";
  const maxLength = options.maxLength ?? 1024;
  const minLength = options.minLength ?? (options.allowEmpty ? 0 : 1);
  if (!Number.isSafeInteger(minLength) || minLength < 0) {
    invalid("Invalid minimum string length", label);
  }
  if (!Number.isSafeInteger(maxLength) || maxLength < minLength) {
    invalid("Invalid maximum string length", label);
  }
  if (typeof value !== "string") invalid(`${label} must be a string`, label);
  let result = value.trim();
  if (options.normalize !== false) result = result.normalize("NFC");
  if (result.length < minLength || result.length > maxLength) {
    invalid(`${label} has an invalid length`, label);
  }
  return result;
}

export const boundedString = boundedTrimmedString;

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function uuid(value: unknown, label = "uuid"): string {
  const result = boundedTrimmedString(value, {
    minLength: 36,
    maxLength: 36,
    normalize: false,
    label,
  });
  if (!UUID_PATTERN.test(result)) invalid(`${label} must be a UUID`, label);
  return result.toLowerCase();
}

export const uuidString = uuid;

export function booleanValue(value: unknown, label = "boolean"): boolean {
  if (typeof value !== "boolean") invalid(`${label} must be a boolean`, label);
  return value;
}

export const boolean = booleanValue;

export interface NumberOptions {
  readonly min?: number;
  readonly max?: number;
  readonly integer?: boolean;
  readonly label?: string;
}

export function numberValue(value: unknown, options: NumberOptions = {}): number {
  const label = options.label ?? "number";
  if (typeof value !== "number" || !Number.isFinite(value)) {
    invalid(`${label} must be a finite number`, label);
  }
  if (options.integer && !Number.isSafeInteger(value)) {
    invalid(`${label} must be an integer`, label);
  }
  if (options.min !== undefined && value < options.min) {
    invalid(`${label} is below the minimum`, label);
  }
  if (options.max !== undefined && value > options.max) {
    invalid(`${label} is above the maximum`, label);
  }
  return value;
}

export const finiteNumber = numberValue;

export function enumValue<T extends string>(
  value: unknown,
  values: readonly T[],
  label = "value",
): T {
  if (typeof value !== "string" || !values.includes(value as T)) {
    invalid(`${label} is not an allowed value`, label);
  }
  return value as T;
}

const IDEMPOTENCY_KEY_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;

export function idempotencyKey(value: unknown, label = "idempotency_key"): string {
  const result = boundedTrimmedString(value, {
    minLength: 1,
    maxLength: 128,
    normalize: false,
    label,
  });
  if (value !== result) {
    invalid(`${label} must not contain surrounding whitespace`, label);
  }
  if (!IDEMPOTENCY_KEY_PATTERN.test(result)) {
    invalid(`${label} contains unsafe characters`, label);
  }
  return result;
}

export const validateIdempotencyKey = idempotencyKey;

/** Return a lowercase SHA-256 digest for text or bytes. */
export async function sha256Hex(input: string | Uint8Array): Promise<string> {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  const digest = await crypto.subtle.digest("SHA-256", bytes as unknown as BufferSource);
  return Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

const FORBIDDEN_FILENAME_CHARS = /[\u0000-\u001f\u007f/\\\u2215\u2044\u29f8:?*<>|]/u;
const ENCODED_SEPARATOR = /%(?:2f|5c)/i;

/** Validate a basename suitable for a private Supabase Storage object. */
export function safeVaultFilename(value: unknown, label = "filename"): string {
  const filename = boundedTrimmedString(value, {
    minLength: 1,
    maxLength: 255,
    normalize: true,
    label,
  });
  if (
    filename === "." ||
    filename === ".." ||
    filename.startsWith(".") ||
    filename.endsWith(".") ||
    filename.endsWith(" ") ||
    FORBIDDEN_FILENAME_CHARS.test(filename) ||
    ENCODED_SEPARATOR.test(filename)
  ) {
    invalid(`${label} is not a safe filename`, label);
  }
  return filename;
}

export const validateVaultFilename = safeVaultFilename;

export function vaultStorageBucket(
  value: unknown,
  label = "storage_bucket",
): VaultStorageBucket {
  const bucket = boundedTrimmedString(value, {
    minLength: 1,
    maxLength: 64,
    normalize: false,
    label,
  });
  if (bucket === LEGACY_DOCUMENTS_BUCKET) {
    invalid("The legacy documents bucket is not part of Swara Vault", label);
  }
  if (bucket !== VAULT_ORIGINALS_BUCKET && bucket !== VAULT_DERIVED_BUCKET) {
    invalid(`${label} is not an allowed Vault bucket`, label);
  }
  return bucket;
}

/**
 * Build exactly `{user_uuid}/{resource_uuid}/{filename}`. The four-argument
 * form also validates the bucket so callers cannot accidentally use the
 * untouched legacy `documents` bucket.
 */
export function safeVaultStoragePath(
  userUuid: unknown,
  resourceUuid: unknown,
  filename: unknown,
): string;
export function safeVaultStoragePath(
  bucket: unknown,
  userUuid: unknown,
  resourceUuid: unknown,
  filename: unknown,
): string;
export function safeVaultStoragePath(...args: unknown[]): string {
  let userUuid: unknown;
  let resourceUuid: unknown;
  let filename: unknown;
  if (args.length === 3) {
    [userUuid, resourceUuid, filename] = args;
  } else if (args.length === 4) {
    vaultStorageBucket(args[0]);
    [, userUuid, resourceUuid, filename] = args;
  } else {
    invalid("A Vault storage path requires three or four arguments", "storage_path");
  }
  return `${uuid(userUuid, "user_uuid")}/${uuid(resourceUuid, "resource_uuid")}/${safeVaultFilename(filename)}`;
}

export interface VaultStorageLocation {
  readonly bucket: VaultStorageBucket;
  readonly path: string;
}

export function safeVaultStorageLocation(
  bucket: unknown,
  userUuid: unknown,
  resourceUuid: unknown,
  filename: unknown,
): VaultStorageLocation {
  const safeBucket = vaultStorageBucket(bucket);
  return Object.freeze({
    bucket: safeBucket,
    path: safeVaultStoragePath(safeBucket, userUuid, resourceUuid, filename),
  });
}

export function validateVaultStoragePath(
  value: unknown,
  expectedUserUuid?: unknown,
  expectedResourceUuid?: unknown,
): string {
  const path = boundedTrimmedString(value, {
    minLength: 1,
    maxLength: 2048,
    normalize: false,
    label: "storage_path",
  });
  const parts = path.split("/");
  if (parts.length !== 3) invalid("storage_path must have exactly three segments", "storage_path");
  const expected = safeVaultStoragePath(
    expectedUserUuid ?? parts[0],
    expectedResourceUuid ?? parts[1],
    parts[2],
  );
  if (path !== expected) invalid("storage_path is not a safe Vault path", "storage_path");
  return path;
}
