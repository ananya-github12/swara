/** Shared, dependency-free contracts for Swara Edge Functions. */

export const DEFAULT_MAX_JSON_BODY_BYTES = 1_048_576;
export type CorrelationId = string & { readonly __correlationId: unique symbol };

export type HttpMethod =
  | "DELETE"
  | "GET"
  | "HEAD"
  | "OPTIONS"
  | "PATCH"
  | "POST"
  | "PUT";

export type ApiErrorCode =
  | "bad_request"
  | "conflict"
  | "forbidden"
  | "internal_error"
  | "method_not_allowed"
  | "not_found"
  | "payload_too_large"
  | "unauthorized"
  | "unsupported_media_type"
  | (string & {});

export interface ApiSuccessEnvelope<T> {
  readonly ok: true;
  readonly data: T;
  readonly correlation_id: CorrelationId;
}

export interface ApiErrorBody {
  readonly code: ApiErrorCode;
  readonly message: string;
}

export interface ApiErrorEnvelope {
  readonly ok: false;
  readonly error: ApiErrorBody;
  readonly correlation_id: CorrelationId;
}

export type ApiEnvelope<T> = ApiSuccessEnvelope<T> | ApiErrorEnvelope;

export interface CorsOptions {
  /** Exact origins only. A wildcard is intentionally rejected. */
  readonly allowedOrigins: readonly string[];
  readonly allowedMethods?: readonly HttpMethod[];
  /** Exact, case-insensitive request header names. */
  readonly allowedHeaders?: readonly string[];
  readonly exposedHeaders?: readonly string[];
  readonly allowCredentials?: boolean;
  readonly maxAgeSeconds?: number;
}

export interface JsonResponseOptions {
  readonly request?: Request;
  readonly cors?: CorsOptions;
  readonly correlationId?: CorrelationId | string;
  readonly headers?: HeadersInit;
  readonly status?: number;
  readonly statusText?: string;
}

export interface BodyParseOptions {
  readonly maxBytes?: number;
}
