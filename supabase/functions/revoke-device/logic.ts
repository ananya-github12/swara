import { RuntimeDatabaseError, type SqlRow, type SqlTransaction } from "../_shared/database.ts";
import type { CorsOptions } from "../_shared/types.ts";
import {
  strictObject,
  type UnknownRecord,
  uuid,
  ValidationError,
} from "../_shared/validation.ts";

const REVOKE_DEVICE_FIELDS = ["device_id"] as const;
const IDEMPOTENCY_KEY_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]*$/;
const CONTROL_CHARACTER_PATTERN = /[\u0000-\u001f\u007f]/;

export interface RevokeDeviceInput {
  readonly device_id: string;
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

/** Parse exact extension origins without a wildcard or implicit public origin. */
export function revokeDeviceCorsOptions(value: string | undefined): CorsOptions {
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
export function parseRevokeDeviceInput(value: unknown): RevokeDeviceInput {
  const input = strictObject<UnknownRecord>(value, REVOKE_DEVICE_FIELDS, {
    label: "revoke-device body",
    requiredKeys: ["device_id"],
  });
  if (typeof input.device_id !== "string") {
    throw new ValidationError("device_id must be a UUID", "device_id");
  }

  const deviceId = uuid(input.device_id, "device_id");
  if (input.device_id !== deviceId) {
    throw new ValidationError("device_id must be canonical", "device_id");
  }
  return Object.freeze({ device_id: deviceId });
}

/** The Idempotency-Key header is the only accepted idempotency source. */
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

/** Execute M022's owner-checked runtime-only function in one transaction. */
export async function revokeDeviceInTransaction(
  transaction: SqlTransaction,
  authenticatedUserId: string,
  input: RevokeDeviceInput,
  idempotencyKey: string,
): Promise<DeviceMutationResult> {
  const userId = uuid(authenticatedUserId, "authenticated_user_id");
  let rows: readonly SqlRow[];
  try {
    rows = await transaction<SqlRow>`
      select device_id, revoked_at, duplicate
        from private.revoke_device(
          ${userId}::uuid,
          ${input.device_id}::uuid,
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
    candidate.message === "Device revocation idempotency key is bound to different input";
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
