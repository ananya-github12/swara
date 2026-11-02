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
  finalizeVaultUploadInTransaction,
  isSafeVaultFinalizeConflict,
  parseVaultFinalizeUploadInput,
  requireVaultFinalizeUploadIdempotencyKey,
  vaultFinalizeUploadCorsOptions,
  VaultFinalizeConflictError,
  type VaultFinalizeUploadResult,
  VaultFinalizeResultError,
} from "./logic.ts";

const FUNCTION_NAME = "vault-finalize-upload";

export interface VerifiedUser {
  readonly userId: string;
}

export interface VaultFinalizeUploadDatabase {
  transaction<T>(callback: (transaction: SqlTransaction) => Promise<T>): Promise<T>;
  close(): Promise<void>;
}

export interface VaultFinalizeUploadDependencies {
  readonly authenticate: (request: Request) => Promise<VerifiedUser>;
  readonly createDatabase: () => Promise<VaultFinalizeUploadDatabase>;
  readonly environment: (name: string) => string | undefined;
  readonly log?: (level: "info" | "error", metadata: unknown) => unknown;
}

/** Build a testable user-only handler with no admin or Storage capability. */
export function createVaultFinalizeUploadHandler(
  dependencies: VaultFinalizeUploadDependencies,
): (request: Request) => Promise<Response> {
  const log = dependencies.log ?? structuredLog;

  return async function fetch(request: Request): Promise<Response> {
    const correlationId = getCorrelationId(request);
    let cors: CorsOptions;
    try {
      cors = vaultFinalizeUploadCorsOptions(dependencies.environment("SWARA_EXTENSION_ORIGINS"));
    } catch {
      log("error", { function: FUNCTION_NAME, event: "configuration_error", correlation: correlationId });
      return errorResponse(new HttpError(500, "internal_error", "Vault finalization is not configured."), {
        request,
        correlationId,
      });
    }

    if (request.method === "OPTIONS") {
      return preflightResponse(request, cors, correlationId);
    }

    const startedAt = performance.now();
    let database: VaultFinalizeUploadDatabase | undefined;
    try {
      requireMethod(request, "POST");
      const { userId } = await dependencies.authenticate(request);
      const body = await readJsonBody<unknown>(request, { maxBytes: 8_192 });
      const input = parseVaultFinalizeUploadInput(body);
      const idempotencyKey = requireVaultFinalizeUploadIdempotencyKey(request.headers);

      database = await dependencies.createDatabase();
      let data: VaultFinalizeUploadResult;
      try {
        data = await database.transaction(async (transaction) =>
          await finalizeVaultUploadInTransaction(transaction, userId, input, idempotencyKey)
        );
      } catch (error) {
        if (isSafeVaultFinalizeConflict(error)) throw error;
        // M023 owns the exact pending intent + Storage-object check. The API
        // role deliberately cannot inspect or repair that state itself, so a
        // function-side failure is safely presented as a retryable conflict.
        throw new VaultFinalizeConflictError();
      }

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
          // Do not serialize cleanup errors: they can contain a database URL,
          // SQL text, parameter values, or document-related metadata.
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
    return new HttpError(400, "bad_request", "The Vault finalization request is invalid.");
  }
  if (isSafeVaultFinalizeConflict(error)) {
    return new HttpError(409, "conflict", "The uploaded file is not ready to finalize.");
  }
  if (error instanceof VaultFinalizeResultError) {
    return new HttpError(500, "internal_error", "Vault finalization could not be completed.");
  }
  return new HttpError(500, "internal_error", "Vault finalization could not be completed.");
}

function elapsedSince(startedAt: number): number {
  return Math.max(0, Math.round(performance.now() - startedAt));
}
