/** Signature verification for the Swara <-> Alterity billing webhook contract. */

import { HttpError } from "./http.ts";

const EVENT_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$/;
const HEX_SHA256_PATTERN = /^[0-9a-f]{64}$/;
const DEFAULT_TOLERANCE_SECONDS = 300;
const MAX_WEBHOOK_BYTES = 262_144;

export interface AlterityWebhookProof {
  readonly bodySha256: string;
  readonly eventId: string;
  readonly signatureVersion: "v1";
  readonly timestamp: number;
}

export interface AlterityVerificationOptions {
  readonly now?: () => number;
  readonly toleranceSeconds?: number;
  readonly maxBodyBytes?: number;
}

/**
 * Verify `v1=hex(hmac_sha256(secret, timestamp.event_id.raw_body))`.
 *
 * The body is consumed exactly as received. Callers should pass a request
 * clone and parse the original only after this function succeeds.
 */
export async function verifyAlterityWebhook(
  request: Request,
  secret: string,
  options: AlterityVerificationOptions = {},
): Promise<AlterityWebhookProof> {
  const normalizedSecret = validateSecret(secret);
  const eventId = requireSingleHeader(request.headers, "x-alterity-event-id");
  if (!EVENT_ID_PATTERN.test(eventId)) throw unauthorized();

  const timestampText = requireSingleHeader(request.headers, "x-alterity-timestamp");
  if (!/^\d{10}$/.test(timestampText)) throw unauthorized();
  const timestamp = Number(timestampText);
  const now = Math.floor((options.now ?? Date.now)() / 1000);
  const tolerance = normalizeTolerance(options.toleranceSeconds ?? DEFAULT_TOLERANCE_SECONDS);
  if (!Number.isSafeInteger(timestamp) || Math.abs(now - timestamp) > tolerance) throw unauthorized();

  const signatureHeader = requireSingleHeader(request.headers, "x-alterity-signature");
  if (!signatureHeader.startsWith("v1=")) throw unauthorized();
  const signatureHex = signatureHeader.slice(3);
  if (!HEX_SHA256_PATTERN.test(signatureHex)) throw unauthorized();

  const body = await readRawBody(request, normalizeBodyLimit(options.maxBodyBytes ?? MAX_WEBHOOK_BYTES));
  const prefix = new TextEncoder().encode(`${timestampText}.${eventId}.`);
  const signedPayload = new Uint8Array(prefix.byteLength + body.byteLength);
  signedPayload.set(prefix);
  signedPayload.set(body, prefix.byteLength);

  let verified = false;
  try {
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(normalizedSecret),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["verify"],
    );
    verified = await crypto.subtle.verify(
      "HMAC",
      key,
      decodeHex(signatureHex),
      signedPayload,
    );
  } catch {
    throw unauthorized();
  }
  if (!verified) throw unauthorized();

  const bodyDigest = await crypto.subtle.digest("SHA-256", body);
  return {
    bodySha256: encodeHex(new Uint8Array(bodyDigest)),
    eventId,
    signatureVersion: "v1",
    timestamp,
  };
}

export function verifyAlterityWebhookFromEnvironment(
  request: Request,
  options: AlterityVerificationOptions = {},
): Promise<AlterityWebhookProof> {
  const secret = Deno.env.get("ALTERITY_WEBHOOK_SECRET");
  if (!secret) {
    throw new HttpError(500, "internal_error", "Billing webhook is not configured.");
  }
  return verifyAlterityWebhook(request, secret, options);
}

function validateSecret(secret: string): string {
  if (typeof secret !== "string" || secret.length < 32 || secret.length > 4096) {
    throw new HttpError(500, "internal_error", "Billing webhook is not configured.");
  }
  return secret;
}

function requireSingleHeader(headers: Headers, name: string): string {
  const value = headers.get(name)?.trim();
  // Commas indicate a coalesced duplicate header. Contract values never
  // contain commas, so reject ambiguity rather than guessing which was signed.
  if (!value || value.includes(",")) throw unauthorized();
  return value;
}

async function readRawBody(request: Request, maxBytes: number): Promise<Uint8Array> {
  const declared = request.headers.get("content-length");
  if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > maxBytes)) {
    throw unauthorized();
  }
  if (!request.body) throw unauthorized();

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel();
        throw unauthorized();
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

function normalizeTolerance(value: number): number {
  if (!Number.isInteger(value) || value < 1 || value > 900) {
    throw new TypeError("Webhook tolerance must be an integer from 1 to 900 seconds.");
  }
  return value;
}

function normalizeBodyLimit(value: number): number {
  if (!Number.isInteger(value) || value < 1 || value > MAX_WEBHOOK_BYTES) {
    throw new TypeError(`Webhook body limit must be an integer from 1 to ${MAX_WEBHOOK_BYTES} bytes.`);
  }
  return value;
}

function decodeHex(value: string): Uint8Array {
  const bytes = new Uint8Array(value.length / 2);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = Number.parseInt(value.slice(index * 2, index * 2 + 2), 16);
  }
  return bytes;
}

function encodeHex(value: Uint8Array): string {
  return Array.from(value, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function unauthorized(): HttpError {
  return new HttpError(401, "unauthorized", "Webhook signature is invalid.");
}
