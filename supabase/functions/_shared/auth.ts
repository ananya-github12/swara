/**
 * Authentication contracts for Swara Edge Functions.
 *
 * These helpers intentionally use the verified context created by
 * `npm:@supabase/server`; they never parse a bearer token or construct a
 * Supabase client from environment variables themselves.
 */
import type { JWTClaims, UserClaims } from "npm:@supabase/server";

import {
  type AdminSupabaseClient,
  type RlsScopedSupabaseClient,
  createInternalAdminClient,
  createUserClientContext,
  createVerifiedWebhookContext,
  type WebhookSignatureVerifier,
} from "./clients.ts";
import { HttpError } from "./http.ts";

export type SwaraUuid = string & { readonly __swaraUuid: unique symbol };

export interface AuthenticatedUserRequest {
  /** RLS-scoped to `userId`; no privileged client is exposed on this path. */
  readonly client: RlsScopedSupabaseClient;
  readonly userId: SwaraUuid;
  readonly sessionId: SwaraUuid;
  /** Present only when the verified JWT carries a root-level device_id claim. */
  readonly deviceId?: SwaraUuid;
}

export interface AuthenticatedWebhookRequest<Proof> {
  /** Available only after the caller-provided signature verifier succeeds. */
  readonly adminClient: AdminSupabaseClient;
  readonly verification: Proof;
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/**
 * Verifies a signed-in user and returns the smallest capability required by a
 * user function: their RLS-scoped client plus validated identity claims.
 */
export async function authenticateUserRequest(request: Request): Promise<AuthenticatedUserRequest> {
  const context = await createUserClientContext(request);
  const { userId, sessionId, deviceId } = validateUserClaims(context.userClaims, context.jwtClaims);

  return {
    client: context.client,
    userId,
    sessionId,
    ...(deviceId ? { deviceId } : {}),
  };
}

/**
 * Verifies only the named `swara-services` secret key and returns the sole
 * privileged capability. This helper must never be used by a browser path.
 */
export async function authenticateInternalRequest(request: Request): Promise<AdminSupabaseClient> {
  return await createInternalAdminClient(request);
}

/**
 * Webhook endpoints opt into `auth: 'none'` only by supplying a signature
 * verifier. The verifier runs before the admin client is made available.
 */
export async function authenticateVerifiedWebhookRequest<Proof>(
  request: Request,
  verifySignature: WebhookSignatureVerifier<Proof>,
): Promise<AuthenticatedWebhookRequest<Proof>> {
  const context = await createVerifiedWebhookContext(request, verifySignature);
  return {
    adminClient: context.adminClient,
    verification: context.verification,
  };
}

function validateUserClaims(
  userClaims: UserClaims,
  jwtClaims: JWTClaims,
): { userId: SwaraUuid; sessionId: SwaraUuid; deviceId?: SwaraUuid } {
  if (userClaims.role !== "authenticated" || jwtClaims.role !== "authenticated") {
    throw unauthorized();
  }

  const userId = requireUuid(userClaims.id);
  const tokenSubject = requireUuid(jwtClaims.sub);
  if (userId !== tokenSubject) throw unauthorized();

  const sessionId = requireUuid(jwtClaims["session_id"]);
  const deviceId = optionalUuid(jwtClaims, "device_id");
  return { userId, sessionId, ...(deviceId ? { deviceId } : {}) };
}

function optionalUuid(claims: JWTClaims, claimName: string): SwaraUuid | undefined {
  if (!Object.hasOwn(claims, claimName)) return undefined;
  return requireUuid(claims[claimName]);
}

function requireUuid(value: unknown): SwaraUuid {
  if (typeof value !== "string" || !UUID_PATTERN.test(value)) throw unauthorized();
  return value.toLowerCase() as SwaraUuid;
}

function unauthorized(): HttpError {
  return new HttpError(401, "unauthorized", "Authentication is required.");
}
