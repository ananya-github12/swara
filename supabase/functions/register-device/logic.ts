import { RuntimeDatabaseError, type SqlRow, type SqlTransaction } from "../_shared/database.ts";
import type { CorsOptions } from "../_shared/types.ts";
import {
  boundedTrimmedString,
  sha256Hex,
  strictObject,
  type UnknownRecord,
  uuid,
  ValidationError,
} from "../_shared/validation.ts";

const REGISTER_DEVICE_FIELDS = [
  "installation_id",
  "browser",
  "extension_version",
  "device_public_key",
] as const;
const IDEMPOTENCY_KEY_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]*$/;
const CONTROL_CHARACTER_PATTERN = /[\u0000-\u001f\u007f]/;
const MAX_INSTALLATION_ID_CODE_UNITS = 512;
const MAX_INSTALLATION_ID_BYTES = 1024;

export interface RegisterDeviceInput {
  /** Kept in memory only long enough to derive its SHA-256 digest. */
  readonly installation_id: string;
  readonly browser: string;
  readonly extension_version: string;
  readonly device_public_key?: string;
}

export interface DeviceMutationResult {
  readonly device_id: string;
  readonly revoked_at: string | null;
  readonly duplicate: boolean;
}

export class DeviceMutationResultError extends Error {
  constructor() {
    super("The database returned an invalid device mutation result.");
    this.name = "DeviceMutationResultError";
  }
}

/** A caller can map this already-sanitized application error to HTTP 409. */
export class DeviceMutationConflictError extends RuntimeDatabaseError {
  constructor() {
    super("The device request conflicts with existing state.");
    this.name = "DeviceMutationConflictError";
  }
}

/**
 * Parse exact extension origins without allowing a wildcard or an implicit
 * public browser origin. Idempotency-Key is deliberately header-only.
 */
export function registerDeviceCorsOptions(value: string | undefined): CorsOptions {
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

/** Reject unknown JSON fields, including user_id and session_id. */
export function parseRegisterDeviceInput(value: unknown): RegisterDeviceInput {
  const input = strictObject<UnknownRecord>(value, REGISTER_DEVICE_FIELDS, {
    label: "register-device body",
    requiredKeys: ["installation_id", "browser", "extension_version"],
  });

  const devicePublicKey = Object.hasOwn(input, "device_public_key") && input.device_public_key !== null
    ? validateDeviceMetadata(input.device_public_key, "device_public_key", 16_384)
    : undefined;

  return Object.freeze({
    installation_id: opaqueInstallationId(input.installation_id),
    browser: validateDeviceMetadata(input.browser, "browser", 128),
    extension_version: validateDeviceMetadata(input.extension_version, "extension_version", 128),
    ...(devicePublicKey ? { device_public_key: devicePublicKey } : {}),
  });
}

/**
 * The Idempotency-Key header is the only accepted idempotency source. It is
 * passed without trimming so the Edge boundary matches M022 exactly.
 */
export function requireDeviceIdempotencyKey(headers: Headers): string {
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

/** Derive the only installation identifier that may cross the database boundary. */
export async function hashInstallationId(installationId: string): Promise<string> {
  return await sha256Hex(installationId);
}

/** Execute M022's runtime-only function in the caller-owned transaction. */
export async function registerDeviceInTransaction(
  transaction: SqlTransaction,
  authenticatedUserId: string,
  input: RegisterDeviceInput,
  idempotencyKey: string,
): Promise<DeviceMutationResult> {
  const userId = uuid(authenticatedUserId, "authenticated_user_id");
  const installationHash = await hashInstallationId(input.installation_id);
  let rows: readonly SqlRow[];
  try {
    rows = await transaction<SqlRow>`
      select device_id, revoked_at, duplicate
        from private.register_device(
          ${userId}::uuid,
          ${installationHash}::text,
          ${input.browser}::text,
          ${input.extension_version}::text,
          ${input.device_public_key ?? null}::text,
          ${idempotencyKey}::text
        )
    `;
  } catch (error) {
    if (isIdempotencyReuseConflict(error)) throw new DeviceMutationConflictError();
    throw error;
  }
  return projectDeviceMutationResult(rows);
}

/** Only explicitly sanitized conflict signals can become a public HTTP 409. */
export function isSafeDatabaseConflict(error: unknown): boolean {
  return error instanceof DeviceMutationConflictError;
}

function opaqueInstallationId(value: unknown): string {
  if (typeof value !== "string") {
    throw new ValidationError("installation_id must be a string", "installation_id");
  }
  if (value.length < 1 || value.length > MAX_INSTALLATION_ID_CODE_UNITS) {
    throw new ValidationError("installation_id has an invalid length", "installation_id");
  }
  if (new TextEncoder().encode(value).byteLength > MAX_INSTALLATION_ID_BYTES) {
    throw new ValidationError("installation_id is too large", "installation_id");
  }
  return value;
}

function validateDeviceMetadata(value: unknown, label: string, maxLength: number): string {
  const result = boundedTrimmedString(value, {
    minLength: 1,
    maxLength,
    normalize: false,
    label,
  });
  if (CONTROL_CHARACTER_PATTERN.test(result)) {
    throw new ValidationError(`${label} contains control characters`, label);
  }
  return result;
}

function projectDeviceMutationResult(rows: readonly SqlRow[]): DeviceMutationResult {
  if (rows.length !== 1 || !isRecord(rows[0])) throw new DeviceMutationResultError();
  const row = rows[0];
  if (typeof row.duplicate !== "boolean") throw new DeviceMutationResultError();

  let deviceId: string;
  try {
    deviceId = uuid(row.device_id, "device_id");
  } catch {
    throw new DeviceMutationResultError();
  }

  return Object.freeze({
    device_id: deviceId,
    revoked_at: projectTimestamp(row.revoked_at),
    duplicate: row.duplicate,
  });
}

function projectTimestamp(value: unknown): string | null {
  if (value === null) return null;
  let timestamp: Date;
  if (value instanceof Date) {
    timestamp = value;
  } else if (typeof value === "string" && value.length <= 128 && !CONTROL_CHARACTER_PATTERN.test(value)) {
    timestamp = new Date(value);
  } else {
    throw new DeviceMutationResultError();
  }
  if (!Number.isFinite(timestamp.getTime())) throw new DeviceMutationResultError();
  return timestamp.toISOString();
}

function isIdempotencyReuseConflict(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;
  const candidate = error as { code?: unknown; message?: unknown };
  return candidate.code === "22023" &&
    candidate.message === "Device registration idempotency key is bound to different input";
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
