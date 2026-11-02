import { errorResponse, getCorrelationId, HttpError, preflightResponse, requireMethod, readJsonBody, successResponse } from "../_shared/http.ts";
import { establishBillingLink } from "../_shared/billing-projection.ts";
import type { SqlTransaction } from "../_shared/database.ts";
import { structuredLog } from "../_shared/logging.ts";
import type { CorsOptions } from "../_shared/types.ts";
import { ValidationError } from "../_shared/validation.ts";
import { BillingGatewayError } from "../create-billing-checkout/logic.ts";
import { billingPortalCorsOptions, createAlterityBillingLink, type FetchLike, parseBillingPortalInput, requireBillingPortalIdempotencyKey } from "./logic.ts";

const FUNCTION_NAME = "create-billing-portal-link";
export interface BillingPortalDependencies {
  readonly authenticate: (request: Request) => Promise<{ readonly userId: string }>;
  readonly createDatabase: () => Promise<BillingLinkDatabase>;
  readonly environment: (name: string) => string | undefined;
  readonly fetch?: FetchLike;
  readonly log?: (level: "info" | "error", metadata: unknown) => unknown;
}
export interface BillingLinkDatabase {
  transaction<T>(callback: (transaction: SqlTransaction) => Promise<T>): Promise<T>;
  close(): Promise<void>;
}
export function createBillingPortalHandler(dependencies: BillingPortalDependencies): (request: Request) => Promise<Response> {
  const log = dependencies.log ?? structuredLog;
  const fetcher = dependencies.fetch ?? fetch;
  return async (request) => {
    const correlationId = getCorrelationId(request);
    let cors: CorsOptions;
    try { cors = billingPortalCorsOptions(dependencies.environment("SWARA_EXTENSION_ORIGINS")); } catch {
      log("error", { function: FUNCTION_NAME, event: "configuration_error", correlation: correlationId });
      return errorResponse(new HttpError(500, "internal_error", "Billing portal is not configured."), { request, correlationId });
    }
    if (request.method === "OPTIONS") return preflightResponse(request, cors, correlationId);
    const startedAt = performance.now();
    let database: BillingLinkDatabase | undefined;
    try {
      requireMethod(request, "POST");
      const principal = await dependencies.authenticate(request);
      parseBillingPortalInput(await readJsonBody<unknown>(request, { maxBytes: 4_096 }));
      const idempotencyKey = requireBillingPortalIdempotencyKey(request.headers);
      const data = await createAlterityBillingLink(fetcher, dependencies.environment("ALTERITY_CONTROL_PLANE_URL"), request.headers.get("authorization"), "create_billing_portal_link", idempotencyKey, correlationId);
      if (data.customerReference !== undefined) {
        database = await dependencies.createDatabase();
        await database.transaction(async (transaction) => await establishBillingLink(transaction, principal.userId, data.customerReference!));
      }
      const response = successResponse({ url: data.url }, { request, cors, correlationId });
      log("info", { function: FUNCTION_NAME, event: "completed", correlation: correlationId, status: String(response.status), duration: elapsedSince(startedAt) });
      return response;
    } catch (error) {
      const safeError = toHttpError(error);
      log("error", { function: FUNCTION_NAME, event: "failed", correlation: correlationId, status: String(safeError.status), duration: elapsedSince(startedAt) });
      return errorResponse(safeError, { request, cors, correlationId });
    } finally {
      if (database) await database.close().catch(() => undefined);
    }
  };
}
function toHttpError(error: unknown): HttpError {
  if (error instanceof HttpError) return error;
  if (error instanceof ValidationError) return new HttpError(400, "bad_request", "The billing portal request is invalid.");
  if (error instanceof BillingGatewayError) return new HttpError(500, "internal_error", "Billing portal is temporarily unavailable.");
  return new HttpError(500, "internal_error", "Billing portal is temporarily unavailable.");
}
function elapsedSince(startedAt: number): number { return Math.max(0, Math.round(performance.now() - startedAt)); }
