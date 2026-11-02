import { authenticateUserRequest } from "../_shared/auth.ts";
import { RuntimeDatabase } from "../_shared/database.ts";
import { errorResponse, getCorrelationId, HttpError, preflightResponse, requireMethod, readJsonBody, successResponse } from "../_shared/http.ts";
import { strictObject, uuid, type UnknownRecord, ValidationError } from "../_shared/validation.ts";
import { extensionCorsOptions } from "../bootstrap/logic.ts";

export async function fetch(request: Request): Promise<Response> {
  const correlationId = getCorrelationId(request);
  let cors;
  try { cors = extensionCorsOptions(Deno.env.get("SWARA_EXTENSION_ORIGINS")); } catch {
    return errorResponse(new HttpError(500, "internal_error", "Vault deletion is not configured."), { request, correlationId });
  }
  if (request.method === "OPTIONS") return preflightResponse(request, cors, correlationId);
  try {
    requireMethod(request, "POST");
    const { userId } = await authenticateUserRequest(request);
    const body = strictObject<UnknownRecord>(await readJsonBody<unknown>(request, { maxBytes: 4096 }), ["document_id"], { requiredKeys: ["document_id"] });
    const documentId = uuid(body.document_id, "document_id");
    const idempotencyKey = request.headers.get("idempotency-key");
    if (!idempotencyKey || !/^[A-Za-z0-9][A-Za-z0-9._:-]{7,199}$/.test(idempotencyKey) || idempotencyKey.trim() !== idempotencyKey) {
      throw new ValidationError("idempotency-key is invalid", "idempotency-key");
    }
    const database = await RuntimeDatabase.fromEnvironment("api");
    try {
      const data = await database.transaction(async (transaction) => {
        const rows = await transaction`
          select document_id, deleted_at, duplicate
            from private.soft_delete_vault_document(${userId}::uuid, ${documentId}::uuid, ${idempotencyKey}::text)
        `;
        if (rows.length !== 1 || typeof rows[0].document_id !== "string" || rows[0].deleted_at == null || typeof rows[0].duplicate !== "boolean") throw new Error("invalid deletion result");
        return { document_id: rows[0].document_id, deleted_at: String(rows[0].deleted_at), duplicate: rows[0].duplicate };
      });
      return successResponse(data, { request, cors, correlationId });
    } finally {
      await database.close();
    }
  } catch (error) {
    const safe = error instanceof HttpError ? error : error instanceof ValidationError ? new HttpError(400, "bad_request", "The Vault deletion request is invalid.") : new HttpError(500, "internal_error", "Vault deletion could not be completed.");
    return errorResponse(safe, { request, cors, correlationId });
  }
}

export default { fetch };
