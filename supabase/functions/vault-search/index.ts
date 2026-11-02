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
import { structuredLog } from "../_shared/logging.ts";
import { ValidationError } from "../_shared/validation.ts";
import {
  parseVaultSearchInput,
  searchVault,
  vaultSearchCorsOptions,
  VaultSearchPersistenceError,
} from "./logic.ts";

const FUNCTION_NAME = "vault-search";

export default { fetch };

export async function fetch(request: Request): Promise<Response> {
  const correlationId = getCorrelationId(request);
  let cors;
  try {
    cors = vaultSearchCorsOptions(Deno.env.get("SWARA_EXTENSION_ORIGINS"));
  } catch {
    return errorResponse(new HttpError(500, "internal_error", "Vault search is not configured."), { request, correlationId });
  }
  if (request.method === "OPTIONS") return preflightResponse(request, cors, correlationId);
  const startedAt = performance.now();
  try {
    requireMethod(request, "POST");
    const authenticated = await authenticateUserRequest(request);
    const input = parseVaultSearchInput(await readJsonBody<unknown>(request, { maxBytes: 8_192 }));
    const data = await searchVault(authenticated.client, authenticated.userId, input);
    const response = successResponse(data, { request, cors, correlationId });
    structuredLog("info", { function: FUNCTION_NAME, event: "completed", correlation: correlationId, status: String(response.status), duration: elapsed(startedAt) });
    return response;
  } catch (error) {
    const safeError = toHttpError(error);
    structuredLog("error", { function: FUNCTION_NAME, event: "failed", correlation: correlationId, status: String(safeError.status), duration: elapsed(startedAt) });
    return errorResponse(safeError, { request, cors, correlationId });
  }
}

function toHttpError(error: unknown): HttpError {
  if (error instanceof HttpError) return error;
  if (error instanceof ValidationError) return new HttpError(400, "bad_request", "The Vault search request is invalid.");
  if (error instanceof VaultSearchPersistenceError) return new HttpError(500, "internal_error", "Vault search could not be completed.");
  return new HttpError(500, "internal_error", "Vault search could not be completed.");
}

function elapsed(startedAt: number): number {
  return Math.max(0, Math.round(performance.now() - startedAt));
}
