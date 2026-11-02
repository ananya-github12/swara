import type { SqlTransaction } from "../_shared/database.ts";
import { errorResponse, getCorrelationId, HttpError, preflightResponse, requireMethod, readJsonBody, successResponse } from "../_shared/http.ts";
import { structuredLog } from "../_shared/logging.ts";
import type { CorsOptions } from "../_shared/types.ts";
import { ValidationError } from "../_shared/validation.ts";
import { AccountDeletionResultError, accountDeletionCorsOptions, parseAccountDeletionInput, requestAccountDeletionInTransaction, requireAccountDeletionIdempotencyKey } from "./logic.ts";

const FUNCTION_NAME = "request-account-deletion";
export interface AccountDeletionDatabase {
  transaction<T>(callback: (transaction: SqlTransaction) => Promise<T>): Promise<T>;
  close(): Promise<void>;
}
export interface AccountDeletionDependencies {
  readonly authenticate: (request: Request) => Promise<{ readonly userId: string }>;
  readonly createDatabase: () => Promise<AccountDeletionDatabase>;
  readonly environment: (name: string) => string | undefined;
  readonly log?: (level: "info" | "error", metadata: unknown) => unknown;
}

export function createAccountDeletionHandler(dependencies: AccountDeletionDependencies): (request: Request) => Promise<Response> {
  const log = dependencies.log ?? structuredLog;
  return async (request) => {
    const correlationId = getCorrelationId(request);
    let cors: CorsOptions;
    try {
      cors = accountDeletionCorsOptions(dependencies.environment("SWARA_EXTENSION_ORIGINS"));
    } catch {
      log("error", { function: FUNCTION_NAME, event: "configuration_error", correlation: correlationId });
      return errorResponse(new HttpError(500, "internal_error", "Account deletion is not configured."), { request, correlationId });
    }
    if (request.method === "OPTIONS") return preflightResponse(request, cors, correlationId);

    const startedAt = performance.now();
    let database: AccountDeletionDatabase | undefined;
    try {
      requireMethod(request, "POST");
      const { userId } = await dependencies.authenticate(request);
      const input = parseAccountDeletionInput(await readJsonBody<unknown>(request, { maxBytes: 4_096 }));
      const idempotencyKey = requireAccountDeletionIdempotencyKey(request.headers);
      database = await dependencies.createDatabase();
      const data = await database.transaction((transaction) => requestAccountDeletionInTransaction(transaction, userId, input, idempotencyKey));
      const response = successResponse(data, { request, cors, correlationId });
      log("info", { function: FUNCTION_NAME, event: "completed", correlation: correlationId, status: String(response.status), duration: elapsedSince(startedAt) });
      return response;
    } catch (error) {
      const safeError = toHttpError(error);
      log("error", { function: FUNCTION_NAME, event: "failed", correlation: correlationId, status: String(safeError.status), duration: elapsedSince(startedAt) });
      return errorResponse(safeError, { request, cors, correlationId });
    } finally {
      if (database) try {
        await database.close();
      } catch {
        log("error", { function: FUNCTION_NAME, event: "database_close_failed", correlation: correlationId, status: "500", duration: elapsedSince(startedAt) });
      }
    }
  };
}

function toHttpError(error: unknown): HttpError {
  if (error instanceof HttpError) return error;
  if (error instanceof ValidationError) return new HttpError(400, "bad_request", "The account deletion request is invalid.");
  if (error instanceof AccountDeletionResultError) return new HttpError(500, "internal_error", "Account deletion could not be requested.");
  return new HttpError(500, "internal_error", "Account deletion could not be requested.");
}
function elapsedSince(startedAt: number): number { return Math.max(0, Math.round(performance.now() - startedAt)); }
