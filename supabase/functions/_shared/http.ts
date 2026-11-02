import {
  type ApiErrorCode,
  type ApiErrorEnvelope,
  type ApiSuccessEnvelope,
  type BodyParseOptions,
  type CorrelationId,
  type CorsOptions,
  DEFAULT_MAX_JSON_BODY_BYTES,
  type HttpMethod,
  type JsonResponseOptions,
} from "./types.ts";

const CORRELATION_ID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ERROR_CODE_PATTERN = /^[a-z][a-z0-9_]{1,63}$/;
const CONTROL_CHARACTER_PATTERN = /[\u0000-\u001f\u007f]/;
const JSON_MEDIA_TYPE = "application/json";
const DEFAULT_ALLOWED_METHODS: readonly HttpMethod[] = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"];
const DEFAULT_ALLOWED_HEADERS = ["authorization", "apikey", "content-type", "x-correlation-id"];
const DEFAULT_EXPOSED_HEADERS = ["x-correlation-id"];

export class HttpError extends Error {
  readonly status: number;
  readonly code: ApiErrorCode;
  readonly publicMessage: string;

  constructor(status: number, code: ApiErrorCode, publicMessage: string) {
    super(publicMessage);
    this.name = "HttpError";
    this.status = normalizeStatus(status);
    this.code = isSafeErrorCode(code) ? code : "bad_request";
    this.publicMessage = sanitizePublicMessage(publicMessage);
  }
}

export function createCorrelationId(): CorrelationId {
  return crypto.randomUUID() as CorrelationId;
}

export function isValidCorrelationId(value: string): boolean {
  return CORRELATION_ID_PATTERN.test(value);
}

export function getCorrelationId(request: Request): CorrelationId {
  const incoming = request.headers.get("x-correlation-id");
  return incoming && isValidCorrelationId(incoming) ? (incoming as CorrelationId) : createCorrelationId();
}

export function requireMethod(request: Request, expected: HttpMethod | readonly HttpMethod[]): void {
  const methods = Array.isArray(expected) ? expected : [expected];
  if (!methods.includes(request.method as HttpMethod)) {
    throw new HttpError(405, "method_not_allowed", "Method not allowed.");
  }
}

export function requireJsonContentType(request: Request): void {
  const contentType = request.headers.get("content-type");
  const mediaType = contentType?.split(";", 1)[0]?.trim().toLowerCase();
  if (mediaType !== JSON_MEDIA_TYPE) {
    throw new HttpError(415, "unsupported_media_type", "Content-Type must be application/json.");
  }
}

export async function readJsonBody<T>(request: Request, options: BodyParseOptions = {}): Promise<T> {
  requireJsonContentType(request);
  const maxBytes = normalizeMaxBytes(options.maxBytes ?? DEFAULT_MAX_JSON_BODY_BYTES);
  const declaredLength = parseContentLength(request.headers.get("content-length"));

  if (declaredLength !== null && declaredLength > maxBytes) {
    throw new HttpError(413, "payload_too_large", "Request body is too large.");
  }
  if (!request.body) {
    throw new HttpError(400, "bad_request", "Request body is required.");
  }

  const bytes = await readBodyWithinLimit(request.body, maxBytes);
  if (bytes.byteLength === 0) {
    throw new HttpError(400, "bad_request", "Request body is required.");
  }

  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new HttpError(400, "bad_request", "Request body must be valid UTF-8 JSON.");
  }

  try {
    return JSON.parse(text) as T;
  } catch {
    throw new HttpError(400, "bad_request", "Request body must be valid JSON.");
  }
}

export function jsonResponse(payload: unknown, options: JsonResponseOptions = {}): Response {
  const correlationId = normalizeCorrelationId(options.correlationId);
  const headers = new Headers(options.headers);
  headers.set("content-type", "application/json; charset=utf-8");
  headers.set("cache-control", "no-store");
  headers.set("x-content-type-options", "nosniff");
  headers.set("x-correlation-id", correlationId);
  applyCorsHeaders(headers, options.request, options.cors);

  return new Response(JSON.stringify(payload), {
    headers,
    status: normalizeStatus(options.status ?? 200),
    statusText: options.statusText,
  });
}

export function successResponse<T>(data: T, options: JsonResponseOptions = {}): Response {
  const correlationId = normalizeCorrelationId(options.correlationId ?? (options.request && getCorrelationId(options.request)));
  const envelope: ApiSuccessEnvelope<T> = { ok: true, data, correlation_id: correlationId };
  return jsonResponse(envelope, { ...options, correlationId });
}

export function errorResponse(error: unknown, options: JsonResponseOptions = {}): Response {
  const correlationId = normalizeCorrelationId(options.correlationId ?? (options.request && getCorrelationId(options.request)));
  const safeError = toSafeError(error);
  const envelope: ApiErrorEnvelope = {
    ok: false,
    error: safeError,
    correlation_id: correlationId,
  };
  return jsonResponse(envelope, {
    ...options,
    correlationId,
    status: safeError.code === "internal_error" ? 500 : safeStatus(error),
  });
}

export function preflightResponse(request: Request, cors: CorsOptions, correlationId?: CorrelationId | string): Response {
  requireMethod(request, "OPTIONS");
  const id = normalizeCorrelationId(correlationId ?? getCorrelationId(request));
  const origin = request.headers.get("origin");
  const requestedMethod = request.headers.get("access-control-request-method")?.trim().toUpperCase();
  const requestedHeaders = parseHeaderList(request.headers.get("access-control-request-headers"));

  if (!origin || !isOriginAllowed(origin, cors.allowedOrigins) ||
    !requestedMethod || !isAllowedMethod(requestedMethod, cors.allowedMethods ?? DEFAULT_ALLOWED_METHODS) ||
    !requestedHeaders.every((header) => isAllowedHeader(header, cors.allowedHeaders ?? DEFAULT_ALLOWED_HEADERS))) {
    return errorResponse(new HttpError(403, "forbidden", "Origin or preflight request is not allowed."), {
      request,
      cors,
      correlationId: id,
      status: 403,
    });
  }

  const headers = new Headers();
  headers.set("cache-control", "no-store");
  headers.set("x-content-type-options", "nosniff");
  headers.set("x-correlation-id", id);
  applyCorsHeaders(headers, request, cors);
  return new Response(null, { headers, status: 204 });
}

export function withCors(response: Response, request: Request, cors: CorsOptions): Response {
  const headers = new Headers(response.headers);
  applyCorsHeaders(headers, request, cors);
  return new Response(response.body, {
    headers,
    status: response.status,
    statusText: response.statusText,
  });
}

function toSafeError(error: unknown): { code: ApiErrorCode; message: string } {
  if (!(error instanceof HttpError)) {
    return { code: "internal_error", message: "An unexpected error occurred." };
  }
  if (error.status >= 500) {
    return { code: "internal_error", message: "An unexpected error occurred." };
  }
  return { code: error.code, message: error.publicMessage };
}

function safeStatus(error: unknown): number {
  return error instanceof HttpError && error.status < 500 ? error.status : 500;
}

function applyCorsHeaders(headers: Headers, request: Request | undefined, cors: CorsOptions | undefined): void {
  if (!cors) return;
  validateCorsOptions(cors);
  if (!request) return;
  const origin = request.headers.get("origin");
  if (!origin) return;
  headers.append("vary", "Origin");
  if (!isOriginAllowed(origin, cors.allowedOrigins)) return;

  headers.set("access-control-allow-origin", origin);
  headers.set("access-control-allow-methods", (cors.allowedMethods ?? DEFAULT_ALLOWED_METHODS).join(", "));
  headers.set("access-control-allow-headers", (cors.allowedHeaders ?? DEFAULT_ALLOWED_HEADERS).join(", "));
  headers.set("access-control-expose-headers", (cors.exposedHeaders ?? DEFAULT_EXPOSED_HEADERS).join(", "));
  if (cors.allowCredentials ?? true) headers.set("access-control-allow-credentials", "true");
  if (cors.maxAgeSeconds !== undefined) {
    const maxAge = Math.max(0, Math.floor(cors.maxAgeSeconds));
    if (Number.isFinite(maxAge)) headers.set("access-control-max-age", String(maxAge));
  }
}

function isOriginAllowed(origin: string, allowedOrigins: readonly string[]): boolean {
  if (!isValidOrigin(origin)) return false;
  return allowedOrigins.some((candidate) => {
    if (candidate.trim() === "*") return false;
    return isValidOrigin(candidate) && candidate === origin;
  });
}

function validateCorsOptions(cors: CorsOptions): void {
  if (cors.allowedOrigins.some((candidate) => candidate.trim() === "*")) {
    throw new TypeError("CORS wildcard origins are not supported for authenticated Edge Functions.");
  }
  if (cors.allowedOrigins.some((candidate) => !isValidOrigin(candidate))) {
    throw new TypeError("CORS origins must be exact http(s) origins.");
  }
  for (const method of cors.allowedMethods ?? DEFAULT_ALLOWED_METHODS) {
    if (!isAllowedMethod(method, DEFAULT_ALLOWED_METHODS)) {
      throw new TypeError("CORS methods must be valid HTTP methods.");
    }
  }
  for (const header of [...(cors.allowedHeaders ?? DEFAULT_ALLOWED_HEADERS), ...(cors.exposedHeaders ?? DEFAULT_EXPOSED_HEADERS)]) {
    if (!/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(header) || header === "*") {
      throw new TypeError("CORS headers must be explicit header names.");
    }
  }
  if (cors.maxAgeSeconds !== undefined && (!Number.isFinite(cors.maxAgeSeconds) || cors.maxAgeSeconds < 0)) {
    throw new TypeError("CORS maxAgeSeconds must be a non-negative number.");
  }
}

function isValidOrigin(origin: string): boolean {
  // Chromium extension IDs are exactly 32 lowercase letters in the a-p
  // alphabet. Custom-scheme URLs have an opaque `URL.origin`, so validate the
  // complete serialized origin directly before handling ordinary web origins.
  if (/^chrome-extension:\/\/[a-p]{32}$/.test(origin)) return true;
  try {
    const parsed = new URL(origin);
    return (parsed.protocol === "https:" || parsed.protocol === "http:") &&
      parsed.origin === origin && !parsed.username && !parsed.password;
  } catch {
    return false;
  }
}

function isAllowedMethod(method: string, allowedMethods: readonly HttpMethod[]): boolean {
  return allowedMethods.includes(method as HttpMethod);
}

function isAllowedHeader(header: string, allowedHeaders: readonly string[]): boolean {
  return allowedHeaders.some((allowed) => allowed.toLowerCase() === header.toLowerCase());
}

function parseHeaderList(value: string | null): string[] {
  if (!value) return [];
  return value.split(",").map((header) => header.trim().toLowerCase()).filter(Boolean);
}

async function readBodyWithinLimit(body: ReadableStream<Uint8Array>, maxBytes: number): Promise<Uint8Array> {
  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!value) continue;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel();
        throw new HttpError(413, "payload_too_large", "Request body is too large.");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const result = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return result;
}

function parseContentLength(value: string | null): number | null {
  if (value === null) return null;
  if (!/^\d+$/.test(value.trim())) throw new HttpError(400, "bad_request", "Invalid Content-Length header.");
  const length = Number(value);
  if (!Number.isSafeInteger(length)) throw new HttpError(400, "bad_request", "Invalid Content-Length header.");
  return length;
}

function normalizeMaxBytes(value: number): number {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new TypeError("maxBytes must be a positive safe integer.");
  }
  return value;
}

function normalizeCorrelationId(value: CorrelationId | string | undefined): CorrelationId {
  return value && isValidCorrelationId(value) ? (value as CorrelationId) : createCorrelationId();
}

function normalizeStatus(status: number): number {
  if (!Number.isInteger(status) || status < 200 || status > 599 || status === 101) return 500;
  return status;
}

function isSafeErrorCode(value: string): value is ApiErrorCode {
  return ERROR_CODE_PATTERN.test(value);
}

function sanitizePublicMessage(value: string): string {
  if (!value || value.length > 200 || CONTROL_CHARACTER_PATTERN.test(value)) {
    return "Request could not be processed.";
  }
  return value;
}
