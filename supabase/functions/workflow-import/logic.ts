/** Dependency-free workflow-import validation and database boundary logic. */

import type { CorsOptions } from "../_shared/types.ts";
import {
  RuntimeDatabaseError,
  type SqlRow,
  type SqlTransaction,
} from "../_shared/database.ts";
import { HttpError } from "../_shared/http.ts";
import { structuredLog, type LogLevel, type LogSink } from "../_shared/logging.ts";
import {
  strictObject,
  type UnknownRecord,
  uuid,
  ValidationError,
  numberValue,
} from "../_shared/validation.ts";
import { extensionCorsOptions } from "../bootstrap/logic.ts";

export const WORKFLOW_IMPORT_MAX_BODY_BYTES = 300 * 1024;
export const WORKFLOW_IMPORT_MAX_DEFINITION_BYTES = 262_144;
export const WORKFLOW_IMPORT_MAX_STEPS = 50;
export const WORKFLOW_IMPORT_MAX_SCHEMA_VERSION = 1_000_000;

const WORKFLOW_IMPORT_BODY_FIELDS = [
  "workflow_id",
  "name",
  "schema_version",
  "definition",
  "expected_current_version_id",
  "idempotency_key",
] as const;

const REQUIRED_WORKFLOW_IMPORT_BODY_FIELDS = [
  "name",
  "schema_version",
  "definition",
  "idempotency_key",
] as const;

const CONTROL_CHARACTER_PATTERN = /[\u0000-\u001f\u007f]/u;
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
const SHA256_PATTERN = /^[0-9a-f]{64}$/u;
const IDEMPOTENCY_KEY_CHARACTER_PATTERN = /^[A-Za-z0-9._:-]$/u;

export interface WorkflowDefinition extends UnknownRecord {
  readonly steps: readonly UnknownRecord[];
}

export interface WorkflowImportInput {
  readonly workflowId: string | null;
  readonly name: string;
  readonly schemaVersion: number;
  readonly definition: WorkflowDefinition;
  readonly expectedCurrentVersionId: string | null;
  readonly idempotencyKey: string;
}

export interface WorkflowImportResult {
  readonly workflow_id: string;
  readonly version_id: string;
  readonly content_hash: string;
  readonly step_count: number;
  readonly duplicate: boolean;
}

interface WorkflowImportDatabaseRow extends SqlRow {
  readonly workflow_id?: unknown;
  readonly version_id?: unknown;
  readonly content_hash?: unknown;
  readonly step_count?: unknown;
  readonly duplicate?: unknown;
}

export interface WorkflowImportRuntimeDatabase {
  transaction<T>(callback: (transaction: SqlTransaction) => Promise<T>): Promise<T>;
}

export type WorkflowImportDatabaseFailureKind =
  | "validation"
  | "conflict"
  | "not_found"
  | "internal";

/**
 * A deliberately message-free database classification. It extends the shared
 * redacted error so RuntimeDatabase will preserve the classification while
 * never retaining a driver message, detail, hint, query, or input value.
 */
export class WorkflowImportDatabaseError extends RuntimeDatabaseError {
  readonly kind: WorkflowImportDatabaseFailureKind;

  constructor(kind: WorkflowImportDatabaseFailureKind) {
    super("Workflow import database operation failed.");
    this.name = "WorkflowImportDatabaseError";
    this.kind = kind;
  }
}

export class WorkflowImportConflictError extends Error {
  constructor() {
    super("Workflow version conflict.");
    this.name = "WorkflowImportConflictError";
  }
}

export function workflowImportCorsOptions(value: string | undefined): CorsOptions {
  return extensionCorsOptions(value);
}

/** Parse the exact public body contract; user_id, hashes, and counts are not accepted. */
export function parseWorkflowImportInput(rawBody: unknown): WorkflowImportInput {
  const body = strictObject<UnknownRecord>(rawBody, WORKFLOW_IMPORT_BODY_FIELDS, {
    requiredKeys: REQUIRED_WORKFLOW_IMPORT_BODY_FIELDS,
    label: "workflow import body",
  });

  const workflowId = optionalUuid(body, "workflow_id");
  const expectedCurrentVersionId = optionalUuid(body, "expected_current_version_id");

  if (workflowId === null && expectedCurrentVersionId !== null) {
    throw new ValidationError(
      "expected_current_version_id is only valid for an existing workflow",
      "expected_current_version_id",
    );
  }
  if (workflowId !== null && expectedCurrentVersionId === null) {
    // M023 makes the optimistic-concurrency precondition mandatory for every
    // update. Failing here avoids an unbounded read/modify/write ambiguity.
    throw new WorkflowImportConflictError();
  }

  const name = workflowName(body.name);
  const schemaVersion = numberValue(body.schema_version, {
    integer: true,
    min: 1,
    max: WORKFLOW_IMPORT_MAX_SCHEMA_VERSION,
    label: "schema_version",
  });
  const definition = workflowDefinition(body.definition);
  const idempotencyKey = workflowIdempotencyKey(body.idempotency_key);

  return Object.freeze({
    workflowId,
    name,
    schemaVersion,
    definition,
    expectedCurrentVersionId,
    idempotencyKey,
  });
}

/** Execute the one parameterized transaction query against the API runtime role. */
export async function importWorkflow(
  database: WorkflowImportRuntimeDatabase,
  userId: string,
  input: WorkflowImportInput,
  correlationId: string,
): Promise<WorkflowImportResult> {
  const verifiedUserId = uuid(userId, "user_id");
  const verifiedCorrelationId = uuid(correlationId, "correlation_id");

  try {
    return await database.transaction((transaction) =>
      executeWorkflowImportQuery(transaction, verifiedUserId, input, verifiedCorrelationId));
  } catch (error) {
    if (error instanceof WorkflowImportDatabaseError || error instanceof RuntimeDatabaseError) {
      throw error;
    }
    throw classifyDatabaseError(error);
  }
}

/**
 * Keep this query as a tagged template: postgres.js parameterizes every input,
 * including the JSON definition, and the casts select the private function's
 * exact signature without interpolating SQL or identifiers.
 */
export async function executeWorkflowImportQuery(
  transaction: SqlTransaction,
  userId: string,
  input: WorkflowImportInput,
  correlationId: string,
): Promise<WorkflowImportResult> {
  try {
    const rows = await transaction<WorkflowImportDatabaseRow>`
      select workflow_id, version_id, content_hash, step_count, duplicate
      from private.import_workflow_atomic(
        ${userId}::uuid,
        ${input.workflowId}::uuid,
        ${input.name}::text,
        ${input.schemaVersion}::integer,
        ${JSON.stringify(input.definition)}::jsonb,
        ${input.expectedCurrentVersionId}::uuid,
        ${input.idempotencyKey}::text,
        ${correlationId}::uuid
      )
    `;

    if (rows.length !== 1) throw new WorkflowImportDatabaseError("internal");
    return projectWorkflowImportResult(rows[0]);
  } catch (error) {
    if (error instanceof WorkflowImportDatabaseError) throw error;
    throw classifyDatabaseError(error);
  }
}

/** Translate only SQLSTATE classes; never inspect or retain provider text. */
export function classifyDatabaseError(error: unknown): WorkflowImportDatabaseError {
  if (error instanceof WorkflowImportDatabaseError) return error;

  const sqlState = sqlStateCode(error);
  switch (sqlState) {
    case "22023":
    case "22P02":
    case "23514":
      return new WorkflowImportDatabaseError("validation");
    case "40001":
      return new WorkflowImportDatabaseError("conflict");
    case "42501":
      return new WorkflowImportDatabaseError("not_found");
    default:
      return new WorkflowImportDatabaseError("internal");
  }
}

export function toWorkflowImportHttpError(error: unknown): HttpError {
  if (error instanceof HttpError) return error;
  if (error instanceof WorkflowImportConflictError) {
    return new HttpError(409, "conflict", "Workflow version conflict.");
  }
  if (error instanceof ValidationError) {
    return new HttpError(400, "bad_request", "The workflow import request is invalid.");
  }
  if (error instanceof WorkflowImportDatabaseError) {
    switch (error.kind) {
      case "validation":
        return new HttpError(400, "bad_request", "The workflow import request is invalid.");
      case "conflict":
        return new HttpError(409, "conflict", "Workflow version conflict.");
      case "not_found":
        return new HttpError(404, "not_found", "Workflow is not available.");
      case "internal":
        return new HttpError(500, "internal_error", "Workflow import could not be completed.");
    }
  }
  return new HttpError(500, "internal_error", "Workflow import could not be completed.");
}

/** Emit only the shared metadata allowlist; request bodies never enter logs. */
export function logWorkflowImportEvent(
  level: Extract<LogLevel, "info" | "error">,
  event: string,
  correlationId: string,
  status: number,
  duration?: number,
  sink?: LogSink,
): void {
  const metadata: Record<string, unknown> = {
    function: "workflow-import",
    event,
    correlation: correlationId,
    status: String(status),
  };
  if (duration !== undefined) metadata.duration = duration;
  structuredLog(level, metadata, sink);
}

function optionalUuid(body: UnknownRecord, field: string): string | null {
  if (!Object.hasOwn(body, field) || body[field] === null) return null;
  return uuid(body[field], field);
}

function workflowName(value: unknown): string {
  if (typeof value !== "string") {
    throw new ValidationError("name must be a string", "name");
  }
  if (value.length < 1 || value.length > 120 || value.trim() !== value || CONTROL_CHARACTER_PATTERN.test(value)) {
    throw new ValidationError("name has an invalid value", "name");
  }
  return value;
}

function workflowDefinition(value: unknown): WorkflowDefinition {
  if (!isPlainObject(value) || Object.keys(value).length === 0) {
    throw new ValidationError("definition must be a non-empty object", "definition");
  }
  if (!Object.hasOwn(value, "steps") || !Array.isArray(value.steps)) {
    throw new ValidationError("definition must contain a steps array", "definition");
  }
  if (value.steps.length > WORKFLOW_IMPORT_MAX_STEPS) {
    throw new ValidationError("definition has too many steps", "definition");
  }
  if (value.steps.some((step) => !isPlainObject(step))) {
    throw new ValidationError("definition steps must be objects", "definition");
  }

  let serialized: string | undefined;
  try {
    serialized = JSON.stringify(value);
  } catch {
    throw new ValidationError("definition is not valid JSON", "definition");
  }
  if (serialized === undefined) {
    throw new ValidationError("definition is not valid JSON", "definition");
  }
  if (new TextEncoder().encode(serialized).byteLength > WORKFLOW_IMPORT_MAX_DEFINITION_BYTES) {
    throw new ValidationError("definition is too large", "definition");
  }

  return value as WorkflowDefinition;
}

function workflowIdempotencyKey(value: unknown): string {
  if (typeof value !== "string" || value.length < 8 || value.length > 200) {
    throw new ValidationError("idempotency_key has an invalid length", "idempotency_key");
  }
  if (!/^[A-Za-z0-9]/u.test(value)) {
    throw new ValidationError("idempotency_key has an invalid value", "idempotency_key");
  }
  for (const character of value) {
    if (!IDEMPOTENCY_KEY_CHARACTER_PATTERN.test(character)) {
      throw new ValidationError("idempotency_key contains unsafe characters", "idempotency_key");
    }
  }
  return value;
}

function projectWorkflowImportResult(row: WorkflowImportDatabaseRow | undefined): WorkflowImportResult {
  if (!row || typeof row !== "object") throw new WorkflowImportDatabaseError("internal");
  const workflowId = databaseUuid(row.workflow_id);
  const versionId = databaseUuid(row.version_id);
  const contentHash = databaseSha256(row.content_hash);
  const stepCount = row.step_count;
  if (typeof stepCount !== "number" || !Number.isSafeInteger(stepCount) || stepCount < 0 || stepCount > WORKFLOW_IMPORT_MAX_STEPS) {
    throw new WorkflowImportDatabaseError("internal");
  }
  if (typeof row.duplicate !== "boolean") throw new WorkflowImportDatabaseError("internal");

  return Object.freeze({
    workflow_id: workflowId,
    version_id: versionId,
    content_hash: contentHash,
    step_count: stepCount,
    duplicate: row.duplicate,
  });
}

function databaseUuid(value: unknown): string {
  if (typeof value !== "string" || !UUID_PATTERN.test(value)) {
    throw new WorkflowImportDatabaseError("internal");
  }
  return value.toLowerCase();
}

function databaseSha256(value: unknown): string {
  if (typeof value !== "string" || !SHA256_PATTERN.test(value)) {
    throw new WorkflowImportDatabaseError("internal");
  }
  return value.toLowerCase();
}

function sqlStateCode(error: unknown): string | undefined {
  if (error === null || typeof error !== "object") return undefined;
  const code = (error as { readonly code?: unknown }).code;
  return typeof code === "string" && /^[0-9A-Z]{5}$/u.test(code) ? code.toUpperCase() : undefined;
}

function isPlainObject(value: unknown): value is UnknownRecord {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}
