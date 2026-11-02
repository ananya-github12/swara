import assert from "node:assert/strict";
import test from "node:test";

import { HttpError } from "./http.ts";
import { verifyAlterityWebhook } from "./alterity.ts";

const SECRET = "swara-test-secret-that-is-at-least-32-bytes-long";
const NOW_SECONDS = 1_787_536_800;
const EVENT_ID = "evt_swara_01a0317b-0000-7000-8000-000000000001";

async function signedRequest(
  body: string,
  overrides: { eventId?: string; timestamp?: number; signature?: string } = {},
): Promise<Request> {
  const eventId = overrides.eventId ?? EVENT_ID;
  const timestamp = overrides.timestamp ?? NOW_SECONDS;
  const payload = new TextEncoder().encode(`${timestamp}.${eventId}.${body}`);
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, payload));
  const signature = overrides.signature ?? Array.from(
    digest,
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");
  return new Request("https://swara.test/functions/v1/alterity-billing-webhook", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-alterity-event-id": eventId,
      "x-alterity-signature": `v1=${signature}`,
      "x-alterity-timestamp": String(timestamp),
    },
    body,
  });
}

test("verifies the untouched body and returns replay-ledger metadata", async () => {
  const body = '{"type":"entitlement.updated","data":{"plan":"pro"}}';
  const proof = await verifyAlterityWebhook(await signedRequest(body), SECRET, {
    now: () => NOW_SECONDS * 1000,
  });

  assert.equal(proof.eventId, EVENT_ID);
  assert.equal(proof.timestamp, NOW_SECONDS);
  assert.equal(proof.signatureVersion, "v1");
  assert.match(proof.bodySha256, /^[0-9a-f]{64}$/);
});

test("rejects a body changed after signing", async () => {
  const signed = await signedRequest('{"plan":"pro"}');
  const changed = new Request(signed.url, {
    method: "POST",
    headers: signed.headers,
    body: '{"plan":"free"}',
  });
  await assert.rejects(
    verifyAlterityWebhook(changed, SECRET, { now: () => NOW_SECONDS * 1000 }),
    (error: unknown) => error instanceof HttpError && error.status === 401,
  );
});

test("rejects expired, future, malformed, and duplicate signature headers", async () => {
  const expired = await signedRequest("{}", { timestamp: NOW_SECONDS - 301 });
  await assert.rejects(
    verifyAlterityWebhook(expired, SECRET, { now: () => NOW_SECONDS * 1000 }),
    /Webhook signature is invalid/,
  );

  const future = await signedRequest("{}", { timestamp: NOW_SECONDS + 301 });
  await assert.rejects(
    verifyAlterityWebhook(future, SECRET, { now: () => NOW_SECONDS * 1000 }),
    /Webhook signature is invalid/,
  );

  const malformed = await signedRequest("{}", { signature: "f".repeat(63) });
  await assert.rejects(
    verifyAlterityWebhook(malformed, SECRET, { now: () => NOW_SECONDS * 1000 }),
    /Webhook signature is invalid/,
  );

  const duplicate = await signedRequest("{}");
  duplicate.headers.set("x-alterity-signature", `${duplicate.headers.get("x-alterity-signature")}, v1=${"0".repeat(64)}`);
  await assert.rejects(
    verifyAlterityWebhook(duplicate, SECRET, { now: () => NOW_SECONDS * 1000 }),
    /Webhook signature is invalid/,
  );
});

test("enforces secret strength and a streamed body limit without leaking input", async () => {
  const request = await signedRequest("x".repeat(16));
  await assert.rejects(
    verifyAlterityWebhook(request, SECRET, { now: () => NOW_SECONDS * 1000, maxBodyBytes: 8 }),
    /Webhook signature is invalid/,
  );

  await assert.rejects(
    verifyAlterityWebhook(await signedRequest("{}"), "short", { now: () => NOW_SECONDS * 1000 }),
    (error: unknown) => error instanceof HttpError && error.status === 500 && !String(error).includes("short"),
  );
});
