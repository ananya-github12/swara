import { authenticateUserRequest } from "../_shared/auth.ts";
import {
  errorResponse,
  getCorrelationId,
  HttpError,
  preflightResponse,
  requireMethod,
  readJsonBody,
  successResponse,
} from "../_shared/http.ts";
import { RuntimeDatabase } from "../_shared/database.ts";
import type { CorsOptions } from "../_shared/types.ts";
import {
  importWorkflow,
  logWorkflowImportEvent,
  parseWorkflowImportInput,
  toWorkflowImportHttpError,
  workflowImportCorsOptions,
  WORKFLOW_IMPORT_MAX_BODY_BYTES,
} from "./logic.ts";

const FUNCTION_NAME = "workflow-import";

export default { fetch };

export async function fetch(request: Request): Promise<Response> {
  const correlationId = getCorrelationId(request);
  let cors: CorsOptions;
  try {
    cors = workflowImportCorsOptions(Deno.env.get("SWARA_EXTENSION_ORIGINS"));
  } catch {
    logWorkflowImportEvent("error", "configuration_error", correlationId, 500);
    return errorResponse(new HttpError(500, "internal_error", "Workflow import is not configured."), {
      request,
      correlationId,
    });
  }

  if (request.method === "OPTIONS") {
    return preflightResponse(request, cors, correlationId);
  }

  const startedAt = performance.now();
  let database: RuntimeDatabase | undefined;
  try {
    requireMethod(request, "POST");
    const authenticated = await authenticateUserRequest(request);
    const rawBody = await readJsonBody<unknown>(request, { maxBytes: WORKFLOW_IMPORT_MAX_BODY_BYTES });
    const input = parseWorkflowImportInput(rawBody);

    database = await RuntimeDatabase.fromEnvironment("api");
    const data = await importWorkflow(database, authenticated.userId, input, correlationId);
    const response = successResponse(data, { request, cors, correlationId });
    logWorkflowImportEvent(
      "info",
      "completed",
      correlationId,
      response.status,
      Math.max(0, Math.round(performance.now() - startedAt)),
    );
    return response;
  } catch (error) {
    const safeError = toWorkflowImportHttpError(error);
    logWorkflowImportEvent(
      "error",
      "failed",
      correlationId,
      safeError.status,
      Math.max(0, Math.round(performance.now() - startedAt)),
    );
    return errorResponse(safeError, { request, cors, correlationId });
  } finally {
    if (database) {
      try {
        await database.close();
      } catch {
        logWorkflowImportEvent("error", "database_close_failed", correlationId, 500);
      }
    }
  }
}

export { FUNCTION_NAME };
