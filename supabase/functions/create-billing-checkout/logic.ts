import type { CorsOptions } from "../_shared/types.ts";
import { boundedTrimmedString, strictObject, type UnknownRecord, ValidationError } from "../_shared/validation.ts";

const IDEMPOTENCY_KEY_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]*$/;
const LINK_FIELDS: readonly string[] = [];

export interface BillingLinkResult {
  readonly url: string;
  /** Kept server-side so the relay can establish an opaque billing link. */
  readonly customerReference?: string;
}
export class BillingGatewayError extends Error {
  constructor() {
    super("The billing control plane did not return a valid link.");
    this.name = "BillingGatewayError";
  }
}
export type FetchLike = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

/** Alterity determines the price and customer from the authenticated principal. */
export function parseBillingCheckoutInput(value: unknown): Record<never, never> {
  strictObject<UnknownRecord>(value, LINK_FIELDS, { label: "billing checkout body" });
  return Object.freeze({}) as Record<never, never>;
}

export function requireBillingIdempotencyKey(headers: Headers): string {
  const value = headers.get("idempotency-key");
  if (value === null || value.length < 8 || value.length > 160 || value.trim() !== value || !IDEMPOTENCY_KEY_PATTERN.test(value)) {
    throw new ValidationError("idempotency-key header is invalid", "idempotency-key");
  }
  return value;
}

export function billingCorsOptions(value: string | undefined): CorsOptions {
  if (typeof value !== "string" || value.trim() === "") throw new TypeError("SWARA_EXTENSION_ORIGINS is required");
  const origins = value.split(",").map((origin) => origin.trim());
  if (origins.length === 0 || origins.some((origin) => origin === "" || origin === "*") || new Set(origins).size !== origins.length || origins.some((origin) => !isExactOrigin(origin))) {
    throw new TypeError("SWARA_EXTENSION_ORIGINS contains invalid origins");
  }
  return Object.freeze({
    allowedOrigins: Object.freeze(origins),
    allowedMethods: Object.freeze(["POST", "OPTIONS"] as const),
    allowedHeaders: Object.freeze(["authorization", "apikey", "content-type", "idempotency-key", "x-client-info", "x-correlation-id"]),
    exposedHeaders: Object.freeze(["x-correlation-id"]), allowCredentials: true, maxAgeSeconds: 600,
  });
}

/** Relay a verified JWT unchanged; the control plane resolves the owner itself. */
export async function createAlterityBillingLink(
  fetcher: FetchLike,
  endpointValue: string | undefined,
  authorization: string | null,
  action: "create_billing_checkout" | "create_billing_portal_link",
  idempotencyKey: string,
  correlationId: string,
): Promise<BillingLinkResult> {
  const endpoint = controlPlaneEndpoint(endpointValue);
  if (!authorization || !authorization.startsWith("Bearer ") || authorization.includes(",")) throw new BillingGatewayError();
  let response: Response;
  try {
    response = await fetcher(endpoint, {
      method: "POST",
      headers: {
        authorization,
        "content-type": "application/json",
        "idempotency-key": idempotencyKey,
        "x-alterity-product": "swara",
        "x-correlation-id": correlationId,
      },
      body: JSON.stringify({ action, product: "swara" }),
    });
  } catch {
    throw new BillingGatewayError();
  }
  if (!response.ok) throw new BillingGatewayError();
  let body: unknown;
  try { body = await response.json(); } catch { throw new BillingGatewayError(); }
  return projectBillingLink(body);
}

function controlPlaneEndpoint(value: string | undefined): string {
  if (typeof value !== "string" || value.trim() === "") throw new BillingGatewayError();
  try {
    const endpoint = new URL(value.trim());
    if (endpoint.protocol !== "https:" || endpoint.username || endpoint.password || endpoint.hash) throw new TypeError();
    return endpoint.toString();
  } catch {
    throw new BillingGatewayError();
  }
}

function projectBillingLink(value: unknown): BillingLinkResult {
  const record = strictObject<UnknownRecord>(value, [
    "url", "checkout_url", "checkoutUrl", "portal_url", "portalUrl",
    "customer_reference", "customerReference",
  ], { label: "billing control-plane response" });
  const url = singleAliasedString(record, ["url", "checkout_url", "checkoutUrl", "portal_url", "portalUrl"], "url", 2_048);
  if (typeof url !== "string" || url.length > 2_048 || url.trim() !== url) throw new BillingGatewayError();
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== "https:" || parsed.username || parsed.password) throw new TypeError();
  } catch {
    throw new BillingGatewayError();
  }
  const customerReference = optionalOpaqueReference(record);
  return Object.freeze(customerReference === undefined ? { url } : { url, customerReference });
}

function optionalOpaqueReference(record: UnknownRecord): string | undefined {
  const value = singleAliasedString(record, ["customer_reference", "customerReference"], "customer_reference", 512, true);
  if (value === undefined) return undefined;
  if (/[\u0000-\u001f\u007f]/u.test(value)) throw new BillingGatewayError();
  return value;
}

function singleAliasedString(
  record: UnknownRecord,
  keys: readonly string[],
  label: string,
  maxLength: number,
  optional = false,
): string | undefined {
  const values = keys.filter((key) => record[key] !== undefined).map((key) => record[key]);
  if (values.length === 0 && optional) return undefined;
  if (values.length === 0) throw new BillingGatewayError();
  const parsed = values.map((value) => boundedTrimmedString(value, { minLength: 1, maxLength, normalize: false, label }));
  if (parsed.some((value, index) => value !== values[index]) || new Set(parsed).size !== 1) throw new BillingGatewayError();
  return parsed[0];
}

function isExactOrigin(origin: string): boolean {
  if (/^chrome-extension:\/\/[a-p]{32}$/.test(origin)) return true;
  try {
    const parsed = new URL(origin);
    return (parsed.protocol === "https:" || parsed.protocol === "http:") && parsed.origin === origin && !parsed.username && !parsed.password;
  } catch { return false; }
}
