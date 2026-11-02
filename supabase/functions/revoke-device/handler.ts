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
  isSafeDatabaseConflict,
  parseRevokeDeviceInput,
  requireDeviceIdempotencyKey,
  revokeDeviceCorsOptions,
  revokeDeviceInTransaction,
} from "./logic.ts";

const FUNCTION_NAME = "revoke-device";

export interface VerifiedUser {
  readonly userId: string;
}

export interface RevokeDeviceDatabase {
  transaction<T>(callback: (transaction: SqlTransaction) => Promise<T>): Promise<T>;
  close(): Promise<void>;
}

export interface RevokeDeviceDependencies {
  readonly authenticate: (request: Request) => Promise<VerifiedUser>;
  readonly createDatabase: () => Promise<RevokeDeviceDatabase>;
  readonly environment: (name: string) => string | undefined;
  readonly log?: (level: "info" | "error", metadata: unknown) => unknown;
}

/** Build a testable user-only request handler without exposing an admin client. */
export function createRevokeDeviceHandler(
  dependencies: RevokeDeviceDependencies,
): (request: Request) => Promise<Response> {
  const log = dependencies.log ?? structuredLog;

  return async function fetch(request: Request): Promise<Response> {
    const correlationId = getCorrelationId(request);
    let cors: CorsOptions;
    try {
      cors = revokeDeviceCorsOptions(dependencies.environment("SWARA_EXTENSION_ORIGINS"));
    } catch {
      log("error", { function: FUNCTION_NAME, event: "configuration_error", correlation: correlationId });
      return errorResponse(new HttpError(500, "internal_error", "Device revocation is not configured."), {
        request,
        correlationId,
      });
    }

    if (request.method === "OPTIONS") {
      return preflightResponse(request, cors, correlationId);
    }

    const startedAt = performance.now();
    let database: RevokeDeviceDatabase | undefined;
    try {
      requireMethod(request, "POST");
      // Target device ownership is enforced by private.revoke_device with this
      // verified user ID. A JWT device_id is never trusted as the target.
      const { userId } = await dependencies.authenticate(request);
      const body = await readJsonBody<unknown>(request, { maxBytes: 8_192 });
      const input = parseRevokeDeviceInput(body);
      const idempotencyKey = requireDeviceIdempotencyKey(request.headers);

      database = await dependencies.createDatabase();
      const data = await database.transaction(async (transaction) =>
        await revokeDeviceInTransaction(transaction, userId, input, idempotencyKey)
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
          // Never serialize a close failure: it may contain a database URL or
          // a parameter value. RuntimeDatabase also redacts it at its boundary.
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
    return new HttpError(400, "bad_request", "The device revocation request is invalid.");
  }
  if (isSafeDatabaseConflict(error)) {
    return new HttpError(409, "conflict", "The device revocation request conflicts with existing state.");
  }
  return new HttpError(500, "internal_error", "Device revocation could not be completed.");
}

function elapsedSince(startedAt: number): number {
  return Math.max(0, Math.round(performance.now() - startedAt));
}
