import { extensionCorsOptions } from "../bootstrap/logic.ts";
import type { CorsOptions } from "../_shared/types.ts";
import {
  boundedTrimmedString,
  enumValue,
  strictObject,
  type UnknownRecord,
  uuid,
  ValidationError,
} from "../_shared/validation.ts";

const BODY_FIELDS = ["operation", "item"] as const;
const ITEM_FIELDS = ["id", "type", "category", "key", "value", "scope", "documentId", "updatedAt"] as const;
const FIRST_ITEM_TYPES = ["fact", "preference", "instruction", "document"] as const;
const SCOPES = ["persistent"] as const;
const SENSITIVITY = "standard" as const;
const SOURCE_TYPE = "cloud_sync" as const;
const CORRECTION_SOURCE_TYPE = "cloud_sync_correction" as const;
const CONTEXT_COLUMNS = [
  "id",
  "user_id",
  "type",
  "key",
  "value",
  "category",
  "sensitivity",
  "source_document_id",
  "source_type",
  "scope",
  "status",
  "version",
  "supersedes_id",
  "browser_session_id",
  "task_id",
  "created_at",
  "updated_at",
] as const;

export const CONTEXT_SYNC_MAX_BODY_BYTES = 72_000;

export interface ContextSyncInput {
  readonly operation: "upsert";
  readonly item: {
    readonly id: string | null;
    readonly type: (typeof FIRST_ITEM_TYPES)[number];
    readonly category: string | null;
    readonly key: string;
    readonly value: string;
    readonly scope: "persistent";
    readonly documentId: string | null;
    readonly updatedAt: string | null;
  };
}

export interface ContextSyncRow extends Record<string, unknown> {
  readonly id?: unknown;
  readonly user_id?: unknown;
  readonly type?: unknown;
  readonly key?: unknown;
  readonly value?: unknown;
  readonly category?: unknown;
  readonly sensitivity?: unknown;
  readonly source_document_id?: unknown;
  readonly source_type?: unknown;
  readonly scope?: unknown;
  readonly status?: unknown;
  readonly version?: unknown;
  readonly supersedes_id?: unknown;
  readonly browser_session_id?: unknown;
  readonly task_id?: unknown;
  readonly created_at?: unknown;
  readonly updated_at?: unknown;
}

interface SelectQuery extends PromiseLike<{ data: unknown; error: unknown }> {
  select(columns: string): SelectQuery;
  eq(column: string, value: string): SelectQuery;
  limit(limit: number): SelectQuery;
}

interface InsertQuery extends PromiseLike<{ data: unknown; error: unknown }> {
  select(columns: string): InsertQuery;
  single(): InsertQuery;
}

export interface ContextSyncTable {
  select(columns: string): SelectQuery;
  insert(values: Record<string, unknown>): InsertQuery;
}

export interface ContextSyncClient {
  from(table: "swara_context_items"): ContextSyncTable;
}

export interface ContextSyncResult {
  readonly operation: "created" | "corrected" | "unchanged";
  readonly item: ContextSyncPublicItem;
}

export interface ContextSyncPublicItem {
  readonly id: string;
  readonly type: string;
  readonly category: string;
  readonly key: string;
  readonly value: string;
  readonly scope: "persistent";
  readonly documentId: string | null;
  readonly updatedAt: string;
}

export class ContextSyncPersistenceError extends Error {
  readonly kind: "conflict" | "not_found" | "invalid" | "internal";

  constructor(kind: ContextSyncPersistenceError["kind"] = "internal") {
    super("Context sync persistence failed.");
    this.name = "ContextSyncPersistenceError";
    this.kind = kind;
  }
}

export function contextSyncCorsOptions(value: string | undefined): CorsOptions {
  return extensionCorsOptions(value);
}

/**
 * Parse the existing extension contract. Ownership, status, version, source,
 * and temporary-scope binding never cross this boundary from the browser.
 */
export function parseContextSyncInput(raw: unknown): ContextSyncInput {
  const body = strictObject<UnknownRecord>(raw, BODY_FIELDS, {
    label: "context sync body",
    requiredKeys: BODY_FIELDS,
  });
  if (body.operation !== "upsert") {
    throw new ValidationError("operation must be upsert", "operation");
  }

  const item = strictObject<UnknownRecord>(body.item, ITEM_FIELDS, {
    label: "context sync item",
    requiredKeys: ["type", "key", "value", "scope"],
  });
  const id = optionalUuid(item, "id");
  const documentId = optionalUuid(item, "documentId");
  const type = enumValue(item.type, FIRST_ITEM_TYPES, "type");
  const scope = enumValue(item.scope, SCOPES, "scope");
  const category = optionalMetadata(item, "category", 128);
  const updatedAt = optionalTimestamp(item, "updatedAt");

  return Object.freeze({
    operation: "upsert",
    item: Object.freeze({
      id,
      type,
      category,
      key: metadata(item.key, "key", 512),
      value: contextValue(item.value),
      scope,
      documentId,
      updatedAt,
    }),
  });
}

/**
 * Perform an append-only upsert through the verified caller's RLS client.
 * A key lookup deliberately turns a repeated save into either an unchanged
 * result or a correction row; there is never a SQL UPDATE or SQL UPSERT.
 */
export async function syncContext(
  client: ContextSyncClient,
  authenticatedUserId: string,
  input: ContextSyncInput,
): Promise<ContextSyncResult> {
  const userId = uuid(authenticatedUserId, "authenticated_user_id");
  const table = client.from("swara_context_items");
  const prior = input.item.id === null
    ? await findActiveByKey(table, userId, input.item.key)
    : await findActiveById(table, userId, input.item.id);

  if (!prior) {
    if (input.item.id !== null) throw new ContextSyncPersistenceError("not_found");
    const created = await insertContextRow(table, firstVersionPayload(userId, input));
    return Object.freeze({ operation: "created", item: projectPublicItem(created, userId) });
  }

  if (prior.value === input.item.value) {
    return Object.freeze({ operation: "unchanged", item: projectPublicItem(prior, userId) });
  }

  const corrected = await insertContextRow(table, correctionPayload(userId, prior, input.item.value));
  return Object.freeze({ operation: "corrected", item: projectPublicItem(corrected, userId) });
}

function firstVersionPayload(userId: string, input: ContextSyncInput): Record<string, unknown> {
  return {
    user_id: userId,
    type: input.item.type,
    key: input.item.key,
    value: input.item.value,
    category: input.item.category ?? "general",
    sensitivity: SENSITIVITY,
    source_document_id: input.item.documentId,
    source_type: SOURCE_TYPE,
    scope: input.item.scope,
    status: "active",
    version: 1,
    supersedes_id: null,
    browser_session_id: null,
    task_id: null,
  };
}

function correctionPayload(userId: string, prior: ContextSyncRow, value: string): Record<string, unknown> {
  const projected = projectStoredRow(prior, userId);
  if (projected.scope !== "persistent") throw new ContextSyncPersistenceError("not_found");
  return {
    user_id: userId,
    type: "correction",
    key: projected.key,
    value,
    category: projected.category,
    sensitivity: projected.sensitivity,
    source_document_id: projected.sourceDocumentId,
    source_type: CORRECTION_SOURCE_TYPE,
    scope: projected.scope,
    status: "active",
    version: projected.version + 1,
    supersedes_id: projected.id,
    browser_session_id: projected.browserSessionId,
    task_id: projected.taskId,
  };
}

async function findActiveById(table: ContextSyncTable, userId: string, id: string): Promise<ContextSyncRow | null> {
  return await findOne(table.select(CONTEXT_COLUMNS.join(",")).eq("user_id", userId).eq("id", id).eq("status", "active").limit(1));
}

async function findActiveByKey(table: ContextSyncTable, userId: string, key: string): Promise<ContextSyncRow | null> {
  return await findOne(table.select(CONTEXT_COLUMNS.join(",")).eq("user_id", userId).eq("key", key).eq("scope", "persistent").eq("status", "active").limit(1));
}

async function findOne(query: PromiseLike<{ data: unknown; error: unknown }>): Promise<ContextSyncRow | null> {
  let response: { data: unknown; error: unknown };
  try {
    response = await query;
  } catch (error) {
    throw classifyPersistenceError(error);
  }
  if (response.error !== null) throw classifyPersistenceError(response.error);
  if (!Array.isArray(response.data)) throw new ContextSyncPersistenceError();
  if (response.data.length === 0) return null;
  if (response.data.length !== 1 || !isRecord(response.data[0])) throw new ContextSyncPersistenceError();
  return response.data[0];
}

async function insertContextRow(table: ContextSyncTable, payload: Record<string, unknown>): Promise<ContextSyncRow> {
  let response: { data: unknown; error: unknown };
  try {
    response = await table.insert(payload).select(CONTEXT_COLUMNS.join(",")).single();
  } catch (error) {
    throw classifyPersistenceError(error);
  }
  if (response.error !== null) throw classifyPersistenceError(response.error);
  if (!isRecord(response.data)) throw new ContextSyncPersistenceError();
  return response.data;
}

function projectPublicItem(row: ContextSyncRow, userId: string): ContextSyncPublicItem {
  const value = projectStoredRow(row, userId);
  return Object.freeze({
    id: value.id,
    type: value.type,
    category: value.category,
    key: value.key,
    value: value.value,
    scope: value.scope,
    documentId: value.sourceDocumentId,
    updatedAt: value.updatedAt,
  });
}

function projectStoredRow(row: ContextSyncRow, userId: string) {
  try {
    return projectStoredRowUnsafe(row, userId);
  } catch (error) {
    if (error instanceof ContextSyncPersistenceError) throw error;
    // A malformed PostgREST row is a server fault, never a client validation
    // error—even when a field parser was reused to validate it.
    throw new ContextSyncPersistenceError();
  }
}

function projectStoredRowUnsafe(row: ContextSyncRow, userId: string) {
  if (row.user_id !== userId || row.status !== "active") throw new ContextSyncPersistenceError();
  const scope = enumValue(row.scope, SCOPES, "scope");
  const type = boundedTrimmedString(row.type, { minLength: 1, maxLength: 32, normalize: false, label: "type" });
  const key = metadata(row.key, "key", 512);
  const value = contextValue(row.value);
  const category = metadata(row.category, "category", 128);
  const sensitivity = enumValue(row.sensitivity, ["standard", "sensitive", "restricted"] as const, "sensitivity");
  const version = row.version;
  if (typeof version !== "number" || !Number.isSafeInteger(version) || version < 1) throw new ContextSyncPersistenceError();
  const id = uuid(row.id, "id");
  const sourceDocumentId = nullableUuid(row.source_document_id, "source_document_id");
  const browserSessionId = nullableUuid(row.browser_session_id, "browser_session_id");
  const taskId = nullableUuid(row.task_id, "task_id");
  if (browserSessionId !== null || taskId !== null) throw new ContextSyncPersistenceError("not_found");
  const updatedAt = timestamp(row.updated_at, "updated_at");
  return { id, type, key, value, category, sensitivity, scope, version, sourceDocumentId, browserSessionId, taskId, updatedAt };
}

function metadata(value: unknown, label: string, maxLength: number): string {
  if (typeof value !== "string" || value.trim() !== value) {
    throw new ValidationError(`${label} must not contain surrounding whitespace`, label);
  }
  const result = boundedTrimmedString(value, { minLength: 1, maxLength, normalize: true, label });
  if (/[\u0000-\u001f\u007f]/u.test(result)) throw new ValidationError(`${label} contains control characters`, label);
  return result;
}

function contextValue(value: unknown): string {
  if (typeof value !== "string" || value.length < 1 || value.length > 65_535) {
    throw new ValidationError("value has an invalid length", "value");
  }
  if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(value)) {
    throw new ValidationError("value contains control characters", "value");
  }
  return value.normalize("NFC");
}

function optionalMetadata(input: UnknownRecord, field: string, maxLength: number): string | null {
  if (!Object.hasOwn(input, field) || input[field] === null) return null;
  return metadata(input[field], field, maxLength);
}

function optionalUuid(input: UnknownRecord, field: string): string | null {
  if (!Object.hasOwn(input, field) || input[field] === null) return null;
  return uuid(input[field], field);
}

function nullableUuid(value: unknown, field: string): string | null {
  if (value === null) return null;
  return uuid(value, field);
}

function optionalTimestamp(input: UnknownRecord, field: string): string | null {
  if (!Object.hasOwn(input, field) || input[field] === null) return null;
  return timestamp(input[field], field);
}

function timestamp(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length > 128 || /[\u0000-\u001f\u007f]/u.test(value)) {
    throw new ValidationError(`${field} is invalid`, field);
  }
  const parsed = new Date(value);
  if (!Number.isFinite(parsed.getTime())) throw new ValidationError(`${field} is invalid`, field);
  return parsed.toISOString();
}

function classifyPersistenceError(error: unknown): ContextSyncPersistenceError {
  const code = isRecord(error) && typeof error.code === "string" ? error.code : undefined;
  if (code === "23505" || code === "40001") return new ContextSyncPersistenceError("conflict");
  if (code === "42501") return new ContextSyncPersistenceError("not_found");
  if (code === "22023" || code === "22P02" || code === "23503" || code === "23514") {
    return new ContextSyncPersistenceError("invalid");
  }
  return new ContextSyncPersistenceError();
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
