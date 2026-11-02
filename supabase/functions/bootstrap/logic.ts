import type { CorsOptions } from "../_shared/types.ts";
import {
  boundedTrimmedString,
  strictObject,
  type UnknownRecord,
  uuid,
  ValidationError,
} from "../_shared/validation.ts";

export const PROFILE_COLUMNS = [
  "user_id",
  "display_name",
  "locale",
  "timezone",
  "onboarding_state",
  "avatar_path",
  "created_at",
  "updated_at",
  "deleted_at",
] as const;

export const SETTINGS_COLUMNS = [
  "user_id",
  "preferred_language",
  "voice_config",
  "privacy_mode",
  "history_retention_days",
  "save_transcripts",
  "cloud_workflow_sync",
  "personalization_enabled",
  "created_at",
  "updated_at",
] as const;

const PROFILE_INPUT_FIELDS = ["display_name", "locale", "timezone"] as const;
const SETTINGS_INPUT_FIELDS = ["preferred_language"] as const;
const BOOTSTRAP_INPUT_FIELDS = [...PROFILE_INPUT_FIELDS, ...SETTINGS_INPUT_FIELDS] as const;

export interface BootstrapInput {
  readonly display_name?: string;
  readonly locale?: string;
  readonly timezone?: string;
  readonly preferred_language?: string;
}

export interface BootstrapRow {
  readonly [key: string]: unknown;
}

export interface BootstrapResult {
  readonly profile: BootstrapRow;
  readonly settings: BootstrapRow;
}

export interface BootstrapClient {
  from(table: string): unknown;
}

interface BootstrapResponse<T> {
  readonly data: T;
  readonly error: unknown;
}

interface BootstrapOperation<T> extends PromiseLike<BootstrapResponse<T>> {}

interface BootstrapFilter extends BootstrapOperation<BootstrapRow | null> {
  eq(column: string, value: string): BootstrapFilter;
  maybeSingle(): BootstrapOperation<BootstrapRow | null>;
}

interface BootstrapTable {
  select(columns: string): BootstrapFilter;
  upsert(
    values: UnknownRecord,
    options: { readonly onConflict: string; readonly ignoreDuplicates: boolean },
  ): BootstrapOperation<unknown>;
}

export class BootstrapAccessError extends Error {
  readonly code = "bootstrap_access_error" as const;

  constructor() {
    super("Bootstrap data did not belong to the authenticated user.");
    this.name = "BootstrapAccessError";
  }
}

export class BootstrapPersistenceError extends Error {
  readonly code = "bootstrap_persistence_error" as const;

  constructor() {
    super("Bootstrap persistence failed.");
    this.name = "BootstrapPersistenceError";
  }
}

/**
 * Parse the extension origin configuration without permitting implicit public
 * access. Origins are exact strings; wildcard and empty values are invalid.
 */
export function extensionCorsOptions(value: string | undefined): CorsOptions {
  if (typeof value !== "string" || value.trim() === "") {
    throw new TypeError("SWARA_EXTENSION_ORIGINS is required");
  }

  const origins = value.split(",").map((origin) => origin.trim());
  if (origins.length === 0 || origins.some((origin) => origin === "" || origin === "*")) {
    throw new TypeError("SWARA_EXTENSION_ORIGINS must contain exact origins");
  }
  if (new Set(origins).size !== origins.length) {
    throw new TypeError("SWARA_EXTENSION_ORIGINS must not contain duplicates");
  }

  for (const origin of origins) {
    if (!isExactOrigin(origin)) throw new TypeError("SWARA_EXTENSION_ORIGINS contains an invalid origin");
  }

  return Object.freeze({
    allowedOrigins: Object.freeze(origins),
    allowedMethods: Object.freeze(["POST", "OPTIONS"] as const),
    allowedHeaders: Object.freeze(["authorization", "apikey", "content-type", "idempotency-key", "x-client-info", "x-correlation-id"]),
    exposedHeaders: Object.freeze(["x-correlation-id"]),
    allowCredentials: true,
    maxAgeSeconds: 600,
  });
}

/**
 * Create missing identity rows through the caller's RLS-scoped client.
 * Existing rows are returned untouched, so bootstrap is safe to retry.
 */
export async function bootstrapUser(
  client: BootstrapClient,
  userId: string,
  rawInput: unknown,
): Promise<BootstrapResult> {
  const ownerId = uuid(userId, "user_id");
  const input = parseBootstrapInput(rawInput);
  const profileInput: UnknownRecord = { user_id: ownerId };
  const settingsInput: UnknownRecord = { user_id: ownerId };

  if (input.display_name !== undefined) profileInput.display_name = input.display_name;
  if (input.locale !== undefined) profileInput.locale = input.locale;
  if (input.timezone !== undefined) profileInput.timezone = input.timezone;
  if (input.preferred_language !== undefined) {
    settingsInput.preferred_language = input.preferred_language;
  }

  const profile = await ensureRow(
    client,
    "profiles",
    PROFILE_COLUMNS,
    profileInput,
    ownerId,
  );
  const settings = await ensureRow(
    client,
    "user_settings",
    SETTINGS_COLUMNS,
    settingsInput,
    ownerId,
  );

  return { profile, settings };
}

function parseBootstrapInput(rawInput: unknown): BootstrapInput {
  const input = strictObject<UnknownRecord>(rawInput, BOOTSTRAP_INPUT_FIELDS, {
    label: "bootstrap body",
  });
  const result: Record<string, string> = {};

  if (Object.hasOwn(input, "display_name")) {
    result.display_name = boundedTrimmedString(input.display_name, {
      minLength: 1,
      maxLength: 160,
      label: "display_name",
    });
  }
  if (Object.hasOwn(input, "locale")) {
    result.locale = boundedTrimmedString(input.locale, {
      minLength: 2,
      maxLength: 35,
      label: "locale",
    });
  }
  if (Object.hasOwn(input, "timezone")) {
    result.timezone = boundedTrimmedString(input.timezone, {
      minLength: 1,
      maxLength: 255,
      label: "timezone",
    });
  }
  if (Object.hasOwn(input, "preferred_language")) {
    result.preferred_language = boundedTrimmedString(input.preferred_language, {
      minLength: 2,
      maxLength: 35,
      label: "preferred_language",
    });
  }

  return result;
}

async function ensureRow(
  client: BootstrapClient,
  tableName: string,
  columns: readonly string[],
  insertValues: UnknownRecord,
  userId: string,
): Promise<BootstrapRow> {
  const table = asTable(client.from(tableName));
  let row = await selectOwnedRow(table, columns, userId);

  if (row === null) {
    const result = await execute(
      table.upsert(insertValues, { onConflict: "user_id", ignoreDuplicates: true }),
    );
    if (result.error !== null) throw new BootstrapPersistenceError();
    row = await selectOwnedRow(table, columns, userId);
  }

  if (row === null) throw new BootstrapPersistenceError();
  if (tableName === "profiles" && row.deleted_at !== null && row.deleted_at !== undefined) {
    throw new BootstrapAccessError();
  }
  return projectOwnedRow(row, columns, userId);
}

async function selectOwnedRow(
  table: BootstrapTable,
  columns: readonly string[],
  userId: string,
): Promise<BootstrapRow | null> {
  const result = await execute(
    table.select(columns.join(",")).eq("user_id", userId).maybeSingle(),
  );
  if (result.error !== null) throw new BootstrapPersistenceError();
  if (result.data === null) return null;
  if (!isRecord(result.data) || result.data.user_id !== userId) throw new BootstrapAccessError();
  return result.data;
}

function projectOwnedRow(
  row: BootstrapRow,
  columns: readonly string[],
  userId: string,
): BootstrapRow {
  if (row.user_id !== userId) throw new BootstrapAccessError();
  const projected: Record<string, unknown> = {};
  for (const column of columns) {
    if (Object.hasOwn(row, column)) projected[column] = row[column];
  }
  return Object.freeze(projected);
}

function asTable(value: unknown): BootstrapTable {
  if (!value || typeof value !== "object") throw new BootstrapPersistenceError();
  return value as BootstrapTable;
}

async function execute<T>(operation: BootstrapOperation<T>): Promise<BootstrapResponse<T>> {
  try {
    const result = await operation;
    if (!result || typeof result !== "object" || !Object.hasOwn(result, "error")) {
      throw new Error("invalid provider response");
    }
    return result;
  } catch {
    throw new BootstrapPersistenceError();
  }
}

function isRecord(value: unknown): value is BootstrapRow {
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

export function isValidationError(error: unknown): error is ValidationError {
  return error instanceof ValidationError;
}
