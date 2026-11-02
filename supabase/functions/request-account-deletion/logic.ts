import type { SqlRow, SqlTransaction } from "../_shared/database.ts";
import { strictObject, type UnknownRecord, uuid, ValidationError } from "../_shared/validation.ts";
import { canonicalUuid, lifecycleCorsOptions, requireLifecycleIdempotencyKey } from "../request-account-export/logic.ts";

const FIELDS = ["export_request_id"] as const;

export interface AccountDeletionInput {
  readonly export_request_id: string | null;
}
export interface AccountDeletionResult {
  readonly request_id: string;
}
export class AccountDeletionResultError extends Error {
  constructor() {
    super("The database returned an invalid account deletion result.");
    this.name = "AccountDeletionResultError";
  }
}

export const accountDeletionCorsOptions = lifecycleCorsOptions;
export const requireAccountDeletionIdempotencyKey = requireLifecycleIdempotencyKey;

/** A deletion can optionally wait for an export request owned by this verified user. */
export function parseAccountDeletionInput(value: unknown): AccountDeletionInput {
  const input = strictObject<UnknownRecord>(value, FIELDS, { label: "account deletion body" });
  if (!Object.hasOwn(input, "export_request_id") || input.export_request_id === null) {
    return Object.freeze({ export_request_id: null });
  }
  if (typeof input.export_request_id !== "string") {
    throw new ValidationError("export_request_id must be a UUID", "export_request_id");
  }
  return Object.freeze({ export_request_id: canonicalUuid(input.export_request_id, "export_request_id") });
}

export async function requestAccountDeletionInTransaction(
  transaction: SqlTransaction,
  authenticatedUserId: string,
  input: AccountDeletionInput,
  idempotencyKey: string,
): Promise<AccountDeletionResult> {
  const userId = canonicalUuid(authenticatedUserId, "authenticated_user_id");
  const rows = await transaction<SqlRow>`
    select private.request_account_deletion(
      ${userId}::uuid,
      ${idempotencyKey}::text,
      ${input.export_request_id}::uuid
    ) as request_id
  `;
  if (rows.length !== 1 || !isRecord(rows[0])) throw new AccountDeletionResultError();
  try {
    return Object.freeze({ request_id: canonicalUuid(rows[0].request_id, "request_id") });
  } catch {
    throw new AccountDeletionResultError();
  }
}

function isRecord(value: unknown): value is SqlRow {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
