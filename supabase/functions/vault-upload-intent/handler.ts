import type { SqlTransaction } from "../_shared/database.ts";
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
  createVaultUploadIntentInTransaction,
  parseVaultUploadIntentInput,
  requireVaultUploadIntentIdempotencyKey,
  vaultUploadIntentCorsOptions,
  VaultUploadIntentResultError,
} from "./logic.ts";

const FUNCTION_NAME = "vault-upload-intent";

export interface VerifiedUser {
  readonly userId: string;
}

export interface VaultUploadIntentDatabase {
  transaction<T>(callback: (transaction: SqlTransaction) => Promise<T>): Promise<T>;
  close(): Promise<void>;
}

export interface VaultUploadIntentDependencies {
  readonly authenticate: (request: Request) => Promise<VerifiedUser>;
  readonly createDatabase: () => Promise<VaultUploadIntentDatabase>;
  readonly environment: (name: string) => string | undefined;
  readonly log?: (level: "info" | "error", metadata: unknown) => unknown;
}

/** Build a testable user-only handler with no admin or Storage capability. */
export function createVaultUploadIntentHandler(
  dependencies: VaultUploadIntentDependencies,
): (request: Request) => Promise<Response> {
  const log = dependencies.log ?? structuredLog;

  return async function fetch(request: Request): Promise<Response> {
    const correlationId = getCorrelationId(request);
    let cors: CorsOptions;
    try {
      cors = vaultUploadIntentCorsOptions(dependencies.environment("SWARA_EXTENSION_ORIGINS"));
    } catch {
      log("error", { function: FUNCTION_NAME, event: "configuration_error", correlation: correlationId });
      return errorResponse(new HttpError(500, "internal_error", "Vault upload is not configured."), {
        request,
        correlationId,
      });
    }

    if (request.method === "OPTIONS") {
      return preflightResponse(request, cors, correlationId);
    }

    const startedAt = performance.now();
    let database: VaultUploadIntentDatabase | undefined;
    try {
      requireMethod(request, "POST");
      const { userId } = await dependencies.authenticate(request);
      const body = await readJsonBody<unknown>(request, { maxBytes: 32_768 });
      const input = parseVaultUploadIntentInput(body);
      const idempotencyKey = requireVaultUploadIntentIdempotencyKey(request.headers);

      database = await dependencies.createDatabase();
      const data = await database.transaction(async (transaction) =>
        await createVaultUploadIntentInTransaction(transaction, userId, input, idempotencyKey)
      );
      const response = successResponse(data, { request, cors, correlationId });
      log("info", {
        function: FUNCTION_NAME,
        event: "completed",
        correlation: correlationId,
        status: String(response.status),
        duration: elapsedSince(startedAt),
      });
      return response;
    } catch (error) {
      const safeError = toHttpError(error);
      log("error", {
        function: FUNCTION_NAME,
        event: "failed",
        correlation: correlationId,
        status: String(safeError.status),
        duration: elapsedSince(startedAt),
      });
      return errorResponse(safeError, { request, cors, correlationId });
    } finally {
      if (database) {
        try {
          await database.close();
        } catch {
          // Do not let a cleanup failure reveal a DSN, a query, or document metadata.
          log("error", {
            function: FUNCTION_NAME,
            event: "database_close_failed",
            correlation: correlationId,
            status: "500",
            duration: elapsedSince(startedAt),
          });
        }
      }
    }
  };
}

function toHttpError(error: unknown): HttpError {
  if (error instanceof HttpError) return error;
  if (error instanceof ValidationError) {
    return new HttpError(400, "bad_request", "The Vault upload request is invalid.");
  }
  if (error instanceof VaultUploadIntentResultError) {
    return new HttpError(500, "internal_error", "Vault upload could not be completed.");
  }
  return new HttpError(500, "internal_error", "Vault upload could not be completed.");
}

function elapsedSince(startedAt: number): number {
  return Math.max(0, Math.round(performance.now() - startedAt));
}
