import {
  errorResponse,
  getCorrelationId,
  HttpError,
  preflightResponse,
  requireMethod,
  readJsonBody,
  successResponse,
} from "../_shared/http.ts";
import { structuredLog } from "../_shared/logging.ts";
import type { CorsOptions } from "../_shared/types.ts";
import { ValidationError } from "../_shared/validation.ts";
import {
  contextSyncCorsOptions,
  CONTEXT_SYNC_MAX_BODY_BYTES,
  ContextSyncPersistenceError,
  type ContextSyncClient,
  parseContextSyncInput,
  syncContext,
} from "./logic.ts";

const FUNCTION_NAME = "context-sync";

export interface ContextSyncDependencies {
  readonly authenticate: (request: Request) => Promise<{ readonly userId: string; readonly client: ContextSyncClient }>;
  readonly environment: (name: string) => string | undefined;
  readonly log?: (level: "info" | "error", metadata: unknown) => unknown;
}

/** User-only handler: the caller's RLS-scoped client is the entire data capability. */
export function createContextSyncHandler(
  dependencies: ContextSyncDependencies,
): (request: Request) => Promise<Response> {
  const log = dependencies.log ?? structuredLog;
  return async function fetch(request: Request): Promise<Response> {
    const correlationId = getCorrelationId(request);
    let cors: CorsOptions;
    try {
      cors = contextSyncCorsOptions(dependencies.environment("SWARA_EXTENSION_ORIGINS"));
    } catch {
      log("error", { function: FUNCTION_NAME, event: "configuration_error", correlation: correlationId });
      return errorResponse(new HttpError(500, "internal_error", "Context sync is not configured."), { request, correlationId });
    }
    if (request.method === "OPTIONS") return preflightResponse(request, cors, correlationId);

    const startedAt = performance.now();
    try {
      requireMethod(request, "POST");
      const authenticated = await dependencies.authenticate(request);
      const input = parseContextSyncInput(await readJsonBody<unknown>(request, { maxBytes: CONTEXT_SYNC_MAX_BODY_BYTES }));
      const data = await syncContext(authenticated.client, authenticated.userId, input);
      const response = successResponse(data, { request, cors, correlationId });
      log("info", { function: FUNCTION_NAME, event: "completed", correlation: correlationId, status: String(response.status), duration: elapsed(startedAt) });
      return response;
    } catch (error) {
      const safe = toHttpError(error);
      log("error", { function: FUNCTION_NAME, event: "failed", correlation: correlationId, status: String(safe.status), duration: elapsed(startedAt) });
      return errorResponse(safe, { request, cors, correlationId });
    }
  };
}

function toHttpError(error: unknown): HttpError {
  if (error instanceof HttpError) return error;
  if (error instanceof ValidationError) return new HttpError(400, "bad_request", "The context sync request is invalid.");
  if (error instanceof ContextSyncPersistenceError) {
    if (error.kind === "conflict") return new HttpError(409, "conflict", "Context sync conflicts with current state.");
    if (error.kind === "not_found") return new HttpError(404, "not_found", "Context item is not available.");
    if (error.kind === "invalid") return new HttpError(400, "bad_request", "The context sync request is invalid.");
  }
  return new HttpError(500, "internal_error", "Context sync could not be completed.");
}

function elapsed(startedAt: number): number {
  return Math.max(0, Math.round(performance.now() - startedAt));
}
