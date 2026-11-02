import type { SqlTransaction } from "./database.ts";

export interface BillingEntitlementProjection {
  readonly userId: string;
  readonly customerReference: string;
  readonly linkStatus: "pending" | "active" | "suspended" | "revoked";
  readonly planCode: string;
  readonly subscriptionStatus:
    | "none"
    | "trialing"
    | "active"
    | "past_due"
    | "paused"
    | "unpaid"
    | "cancelled"
    | "expired"
    | "incomplete";
  readonly capabilities: Record<string, unknown>;
  readonly limits: Record<string, unknown>;
  readonly validUntil: string;
  readonly sourceVersion: string;
}

interface ProjectionRow {
  readonly link_written?: unknown;
  readonly snapshot_written?: unknown;
}

interface LinkRow {
  readonly link_created?: unknown;
}

/**
 * Pass only the validated, provider-neutral projection to Postgres. The raw
 * webhook/request body intentionally never crosses this boundary.
 */
export async function projectBillingEntitlement(
  transaction: SqlTransaction,
  projection: BillingEntitlementProjection,
): Promise<{ readonly linkWritten: boolean; readonly snapshotWritten: boolean }> {
  const rows = await transaction<ProjectionRow>`
    select link_written, snapshot_written
      from private.project_billing_entitlement(
        ${projection.userId}::uuid,
        ${projection.customerReference}::text,
        ${projection.linkStatus}::text,
        ${projection.planCode}::text,
        ${projection.subscriptionStatus}::text,
        ${JSON.stringify(projection.capabilities)}::jsonb,
        ${JSON.stringify(projection.limits)}::jsonb,
        ${projection.validUntil}::timestamptz,
        ${projection.sourceVersion}::text
      )
  `;
  if (rows.length !== 1 || typeof rows[0].link_written !== "boolean" || typeof rows[0].snapshot_written !== "boolean") {
    throw new Error("Billing entitlement projection failed.");
  }
  return Object.freeze({ linkWritten: rows[0].link_written, snapshotWritten: rows[0].snapshot_written });
}

/** Record only an opaque customer reference returned by a verified relay. */
export async function establishBillingLink(
  transaction: SqlTransaction,
  userId: string,
  customerReference: string,
): Promise<boolean> {
  const rows = await transaction<LinkRow>`
    select link_created
      from private.establish_billing_link(
        ${userId}::uuid,
        ${customerReference}::text
      )
  `;
  if (rows.length !== 1 || typeof rows[0].link_created !== "boolean") {
    throw new Error("Billing link establishment failed.");
  }
  return rows[0].link_created;
}
