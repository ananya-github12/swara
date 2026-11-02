import { strictObject, type UnknownRecord } from "../_shared/validation.ts";
import { billingCorsOptions, createAlterityBillingLink, type BillingLinkResult, type FetchLike, requireBillingIdempotencyKey } from "../create-billing-checkout/logic.ts";

export { billingCorsOptions as billingPortalCorsOptions, createAlterityBillingLink, requireBillingIdempotencyKey as requireBillingPortalIdempotencyKey };
export type { BillingLinkResult, FetchLike };

/** The verified control-plane principal determines the customer portal. */
export function parseBillingPortalInput(value: unknown): Record<never, never> {
  strictObject<UnknownRecord>(value, [], { label: "billing portal body" });
  return Object.freeze({}) as Record<never, never>;
}
