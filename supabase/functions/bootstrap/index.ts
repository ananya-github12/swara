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
import type { CorsOptions } from "../_shared/types.ts";
import { structuredLog } from "../_shared/logging.ts";
import { isValidationError, bootstrapUser, extensionCorsOptions } from "./logic.ts";

const FUNCTION_NAME = "bootstrap";

export default { fetch };

export async function fetch(request: Request): Promise<Response> {
  const correlationId = getCorrelationId(request);
  let cors: CorsOptions;
  try {
    cors = extensionCorsOptions(Deno.env.get("SWARA_EXTENSION_ORIGINS"));
  } catch {
    structuredLog("error", { function: FUNCTION_NAME, event: "configuration_error", correlation: correlationId });
    return errorResponse(new HttpError(500, "internal_error", "Bootstrap is not configured."), {
      request,
      correlationId,
    });
  }

  if (request.method === "OPTIONS") {
    return preflightResponse(request, cors, correlationId);
  }

  const startedAt = performance.now();
  try {
    requireMethod(request, "POST");
    const authenticated = await authenticateUserRequest(request);
    const body = await readJsonBody<unknown>(request);
    const data = await bootstrapUser(authenticated.client, authenticated.userId, body);
    const response = successResponse(data, { request, cors, correlationId });
    structuredLog("info", {
      function: FUNCTION_NAME,
      event: "completed",
      correlation: correlationId,
      status: response.status,
      duration: Math.max(0, Math.round(performance.now() - startedAt)),
    });
    return response;
  } catch (error) {
    const safeError = toHttpError(error);
    structuredLog("error", {
      function: FUNCTION_NAME,
      event: "failed",
      correlation: correlationId,
      status: safeError.status,
      duration: Math.max(0, Math.round(performance.now() - startedAt)),
    });
    return errorResponse(safeError, { request, cors, correlationId });
  }
}

function toHttpError(error: unknown): HttpError {
  if (error instanceof HttpError) return error;
  if (isValidationError(error)) {
    return new HttpError(400, "bad_request", "The bootstrap request is invalid.");
  }
  return new HttpError(500, "internal_error", "Bootstrap could not be completed.");
}
