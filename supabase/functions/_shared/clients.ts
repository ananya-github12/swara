/**
 * Narrow Supabase client capabilities for Edge Functions.
 *
 * `@supabase/server` owns environment resolution, credential verification, and
 * client construction.  Do not add API-key or bearer-token handling here: doing
 * so would duplicate (and risk diverging from) the platform's verification.
 */
import { createSupabaseContext } from "npm:@supabase/server";
import type {
  JWTClaims,
  SupabaseContext,
  UserClaims,
} from "npm:@supabase/server";

import { HttpError } from "./http.ts";

export type RlsScopedSupabaseClient = SupabaseContext["supabase"];
export type AdminSupabaseClient = SupabaseContext["supabaseAdmin"];

/** The only SDK values a user-authentication helper may receive. */
export interface UserClientContext {
  readonly client: RlsScopedSupabaseClient;
  readonly userClaims: UserClaims;
  readonly jwtClaims: JWTClaims;
}

/**
 * A webhook verifier must return an explicit success value. Returning `false`,
 * `null`, or `undefined` is treated as a failed signature check.
 */
export type WebhookSignatureVerifier<Proof> = (
  request: Request,
) => Proof | false | null | undefined | Promise<Proof | false | null | undefined>;

export interface VerifiedWebhookContext<Proof> {
  readonly adminClient: AdminSupabaseClient;
  readonly verification: Proof;
}

const USER_AUTH = { auth: "user", cors: "disabled" } as const;
const INTERNAL_AUTH = { auth: "secret:swara-services", cors: "disabled" } as const;
const WEBHOOK_AUTH = { auth: "none", cors: "disabled" } as const;

/**
 * Creates a caller-scoped client after the SDK has verified a user JWT.
 * The privileged client deliberately never crosses this function boundary.
 */
export async function createUserClientContext(request: Request): Promise<UserClientContext> {
  const context = await requireSupabaseContext(request, USER_AUTH);
  if (context.authMode !== "user" || !context.userClaims || !context.jwtClaims) {
    throw unauthorized();
  }

  return {
    client: context.supabase,
    userClaims: context.userClaims,
    jwtClaims: context.jwtClaims,
  };
}

/**
 * Creates the privileged client for Swara's specifically named service key.
 * This is for service-to-service calls only; browser and user paths must use
 * `createUserClientContext` instead.
 */
export async function createInternalAdminClient(request: Request): Promise<AdminSupabaseClient> {
  const context = await requireSupabaseContext(request, INTERNAL_AUTH);
  if (context.authMode !== "secret" || context.authKeyName !== "swara-services") {
    throw unauthorized();
  }
  return context.supabaseAdmin;
}

/**
 * Makes `auth: 'none'` available only behind an explicit signature verifier.
 * The verifier receives a clone so it can consume the raw body without
 * preventing the handler from reading the original request afterwards.
 */
export async function createVerifiedWebhookContext<Proof>(
  request: Request,
  verifySignature: WebhookSignatureVerifier<Proof>,
): Promise<VerifiedWebhookContext<Proof>> {
  let verification: Proof | false | null | undefined;
  try {
    verification = await verifySignature(request.clone());
  } catch {
    throw unauthorized();
  }

  if (verification === false || verification === null || verification === undefined) {
    throw unauthorized();
  }

  const context = await requireSupabaseContext(request, WEBHOOK_AUTH);
  if (context.authMode !== "none") {
    throw unauthorized();
  }
  return { adminClient: context.supabaseAdmin, verification };
}

async function requireSupabaseContext(
  request: Request,
  options: typeof USER_AUTH | typeof INTERNAL_AUTH | typeof WEBHOOK_AUTH,
): Promise<SupabaseContext> {
  try {
    const { data, error } = await createSupabaseContext(request, options);
    if (error || !data) throw sdkErrorToHttpError(error);
    return data;
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw sdkErrorToHttpError(error);
  }
}

/** Never expose provider error messages, codes, credentials, or key names. */
function sdkErrorToHttpError(error: unknown): HttpError {
  const status = typeof (error as { status?: unknown } | null)?.status === "number"
    ? (error as { status: number }).status
    : undefined;

  if (status !== undefined && status >= 500) {
    return new HttpError(500, "internal_error", "Authentication could not be completed.");
  }
  return unauthorized();
}

function unauthorized(): HttpError {
  return new HttpError(401, "unauthorized", "Authentication is required.");
}
