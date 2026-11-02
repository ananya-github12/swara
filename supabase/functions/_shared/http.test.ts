import assert from "node:assert/strict";
import test from "node:test";

import {
  errorResponse,
  getCorrelationId,
  HttpError,
  preflightResponse,
  readJsonBody,
} from "./http.ts";

const EXTENSION_ID = "abcdefghijklmnopabcdefghijklmnop";
const EXTENSION_ORIGIN = `chrome-extension://${EXTENSION_ID}`;

test("correlation IDs reject unsafe header values", () => {
  const correlationId = "33333333-3333-4333-8333-333333333333";
  const accepted = getCorrelationId(new Request("https://swara.test", {
    headers: { "x-correlation-id": correlationId },
  }));
  assert.equal(accepted, correlationId);

  const replaced = getCorrelationId(new Request("https://swara.test", {
    headers: { "x-correlation-id": "request 01" },
  }));
  assert.notEqual(replaced, correlationId);
  assert.match(replaced, /^[0-9a-f-]{36}$/);
});

test("JSON parsing enforces media type and streamed body limits", async () => {
  await assert.rejects(
    readJsonBody(new Request("https://swara.test", { method: "POST", body: "{}" })),
    (error: unknown) => error instanceof HttpError && error.status === 415,
  );

  await assert.rejects(
    readJsonBody(
      new Request("https://swara.test", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ value: "too large" }),
      }),
      { maxBytes: 4 },
    ),
    (error: unknown) => error instanceof HttpError && error.status === 413,
  );
});

test("preflight permits one exact Chrome extension origin", () => {
  const request = new Request("https://swara.test", {
    method: "OPTIONS",
    headers: {
      origin: EXTENSION_ORIGIN,
      "access-control-request-method": "POST",
      "access-control-request-headers": "authorization, apikey, content-type",
    },
  });
  const response = preflightResponse(request, {
    allowedOrigins: [EXTENSION_ORIGIN],
    allowedMethods: ["POST", "OPTIONS"],
  });

  assert.equal(response.status, 204);
  assert.equal(response.headers.get("access-control-allow-origin"), EXTENSION_ORIGIN);
  assert.notEqual(response.headers.get("access-control-allow-origin"), "*");
});

test("wildcard origins are rejected and internal errors are redacted", async () => {
  const request = new Request("https://swara.test", {
    method: "OPTIONS",
    headers: {
      origin: EXTENSION_ORIGIN,
      "access-control-request-method": "POST",
    },
  });
  assert.throws(
    () => preflightResponse(request, { allowedOrigins: ["*"] }),
    /wildcard origins are not supported/,
  );

  const response = errorResponse(new Error("secret token and database URL"));
  const body = await response.text();
  assert.equal(response.status, 500);
  assert.doesNotMatch(body, /secret token|database URL/);
  assert.match(body, /internal_error/);
});
