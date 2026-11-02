import { extensionCorsOptions } from "../bootstrap/logic.ts";
import type { CorsOptions } from "../_shared/types.ts";
import { strictObject, boundedTrimmedString, numberValue, type UnknownRecord, ValidationError, uuid } from "../_shared/validation.ts";

const INPUT_FIELDS = ["query", "limit"] as const;
const CONTROL_CHARACTER_PATTERN = /[\u0000-\u001f\u007f]/u;

export interface VaultSearchInput {
  readonly query: string;
  readonly limit: number;
}

export interface VaultSearchClient {
  from(table: string): unknown;
}

interface Query<T> extends PromiseLike<{ data: T; error: unknown }> {
  eq(column: string, value: string): Query<T>;
  or(filters: string): Query<T>;
  order(column: string, options: { ascending: boolean }): Query<T>;
  limit(value: number): Query<T>;
}

export interface VaultSearchResult {
  readonly documents: readonly Record<string, unknown>[];
  readonly context_items: readonly Record<string, unknown>[];
  readonly truncated: boolean;
}

export class VaultSearchPersistenceError extends Error {
  constructor() {
    super("Vault search persistence failed.");
    this.name = "VaultSearchPersistenceError";
  }
}

export function vaultSearchCorsOptions(value: string | undefined): CorsOptions {
  return extensionCorsOptions(value);
}

export function parseVaultSearchInput(raw: unknown): VaultSearchInput {
  const body = strictObject<UnknownRecord>(raw, INPUT_FIELDS, {
    requiredKeys: ["query"],
    label: "Vault search body",
  });
  const query = boundedTrimmedString(body.query, {
    minLength: 1,
    maxLength: 256,
    normalize: true,
    label: "query",
  });
  if (CONTROL_CHARACTER_PATTERN.test(query)) throw new ValidationError("query contains control characters", "query");
  const limit = body.limit === undefined
    ? 20
    : numberValue(body.limit, { integer: true, min: 1, max: 50, label: "limit" });
  return Object.freeze({ query, limit });
}

/** Escape SQL LIKE metacharacters before intentionally surrounding the term with `%`. */
export function vaultSearchPattern(query: string): string {
  return `%${query.replace(/[\\%_]/g, (value) => `\\${value}`)}%`;
}

export async function searchVault(
  client: VaultSearchClient,
  authenticatedUserId: string,
  input: VaultSearchInput,
): Promise<VaultSearchResult> {
  const userId = uuid(authenticatedUserId, "user_id");
  const pattern = vaultSearchPattern(input.query);
  const documents = asQuery<Record<string, unknown>[]>(client.from("vault_documents"));
  const contexts = asQuery<Record<string, unknown>[]>(client.from("swara_context_items"));

  const [documentResult, contextResult] = await Promise.all([
    execute(documents.select("id,user_id,filename,mime_type,size_bytes,sha256,storage_bucket,storage_path,extraction_method,status,retention_expires_at,created_at,updated_at")
      .eq("user_id", userId)
      .or(`filename.ilike.${pattern},mime_type.ilike.${pattern}`)
      .order("created_at", { ascending: false })
      .limit(input.limit)),
    execute(contexts.select("id,user_id,type,key,category,sensitivity,source_document_id,source_type,scope,status,version,created_at,updated_at")
      .eq("user_id", userId)
      .or(`key.ilike.${pattern},category.ilike.${pattern},type.ilike.${pattern}`)
      .order("updated_at", { ascending: false })
      .limit(input.limit)),
  ]);

  if (documentResult.error !== null || contextResult.error !== null) throw new VaultSearchPersistenceError();
  const safeDocuments = projectRows(documentResult.data, userId);
  const safeContexts = projectRows(contextResult.data, userId);
  return Object.freeze({
    documents: safeDocuments,
    context_items: safeContexts,
    truncated: safeDocuments.length === input.limit || safeContexts.length === input.limit,
  });
}

function asQuery<T>(value: unknown): Query<T> {
  if (!value || typeof value !== "object") throw new VaultSearchPersistenceError();
  return value as Query<T>;
}

async function execute<T>(operation: PromiseLike<{ data: T; error: unknown }>): Promise<{ data: T; error: unknown }> {
  try {
    return await operation;
  } catch {
    throw new VaultSearchPersistenceError();
  }
}

function projectRows(value: unknown, userId: string): readonly Record<string, unknown>[] {
  if (!Array.isArray(value)) throw new VaultSearchPersistenceError();
  return Object.freeze(value.map((row) => {
    if (!row || typeof row !== "object" || Array.isArray(row)) throw new VaultSearchPersistenceError();
    const result = row as Record<string, unknown>;
    if (result.user_id !== userId) throw new VaultSearchPersistenceError();
    return Object.freeze({ ...result });
  }));
}
