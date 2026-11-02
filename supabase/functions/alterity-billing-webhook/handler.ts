import type { RuntimeDatabase, SqlTransaction } from "../_shared/database.ts";
import { verifyAlterityWebhook, type AlterityWebhookProof, type AlterityVerificationOptions } from "../_shared/alterity.ts";
import { errorResponse, getCorrelationId, HttpError, requireMethod, readJsonBody, successResponse } from "../_shared/http.ts";
import { structuredLog } from "../_shared/logging.ts";
import { ValidationError } from "../_shared/validation.ts";
import {
  claimAlterityWebhook,
  finalizeAlterityWebhook,
  parseAlterityBillingEvent,
  projectAlterityBillingEvent,
  toAlterityWebhookHttpError,
  type AlterityBillingWebhookProof,
} from "./logic.ts";

const FUNCTION_NAME = "alterity-billing-webhook";

export interface AlterityWebhookDatabase {
  transaction<T>(callback: (transaction: SqlTransaction) => Promise<T>): Promise<T>;
  close(): Promise<void>;
}

export interface AlterityWebhookDependencies {
  readonly verify: (request: Request) => Promise<AlterityBillingWebhookProof>;
  readonly createDatabase: () => Promise<AlterityWebhookDatabase>;
  readonly log?: (level: "info" | "error", metadata: unknown) => unknown;
}

export function createAlterityBillingWebhookHandler(dependencies: AlterityWebhookDependencies): (request: Request) => Promise<Response> {
  const log = dependencies.log ?? structuredLog;
  return async (request) => {
    const correlationId = getCorrelationId(request);
    const startedAt = performance.now();
    let database: AlterityWebhookDatabase | undefined;
    try {
      requireMethod(request, "POST");
      // The verifier consumes a clone and must complete before JSON parsing or
      // any database capability is acquired.
      const proof = await dependencies.verify(request.clone());
      const event = parseAlterityBillingEvent(await readJsonBody<unknown>(request, { maxBytes: 262_144 }));
      database = await dependencies.createDatabase();
      const outcome = await database.transaction(async (transaction) => {
        const claim = await claimAlterityWebhook(transaction, proof, event);
        if (claim === "first_delivery") {
          await projectAlterityBillingEvent(transaction, event);
          await finalizeAlterityWebhook(transaction, proof);
        }
        return claim;
      });

      if (outcome === "hash_conflict") {
        throw new HttpError(409, "conflict", "The billing webhook conflicts with an earlier delivery.");
      }
      const status = outcome === "in_progress" ? 202 : 200;
      const response = successResponse({ accepted: true, outcome }, { request, correlationId, status });
      log("info", { function: FUNCTION_NAME, event: "completed", correlation: correlationId, status: String(response.status), duration: elapsed(startedAt) });
      return response;
    } catch (error) {
      const safeError = error instanceof ValidationError ? toAlterityWebhookHttpError(error) : toAlterityWebhookHttpError(error);
      log("error", { function: FUNCTION_NAME, event: "failed", correlation: correlationId, status: String(safeError.status), duration: elapsed(startedAt) });
      return errorResponse(safeError, { request, correlationId });
    } finally {
      if (database) {
        try {
          await database.close();
        } catch {
          log("error", { function: FUNCTION_NAME, event: "database_close_failed", correlation: correlationId, status: "500" });
        }
      }
    }
  };
}

function elapsed(startedAt: number): number {
  return Math.max(0, Math.round(performance.now() - startedAt));
}

export type { AlterityWebhookProof, AlterityVerificationOptions };
