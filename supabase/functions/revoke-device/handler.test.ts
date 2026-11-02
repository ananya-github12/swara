import assert from "node:assert/strict";
import test from "node:test";

import type { SqlRow, SqlTransaction } from "../_shared/database.ts";
import { createRevokeDeviceHandler, type RevokeDeviceDatabase } from "./handler.ts";

const EXTENSION_ORIGIN = "chrome-extension://abcdefghijklmnopabcdefghijklmnop";
const USER_ID = "11111111-1111-4111-8111-111111111111";
const DEVICE_ID = "22222222-2222-4222-8222-222222222222";
const JWT_DEVICE_ID = "33333333-3333-4333-8333-333333333333";

interface QueryInvocation {
  readonly query: string;
  readonly values: readonly unknown[];
}

class FakeDatabase implements RevokeDeviceDatabase {
  readonly invocations: QueryInvocation[] = [];
  readonly rows: readonly SqlRow[];
  readonly failure: unknown;
  transactionCalls = 0;
  closeCalls = 0;

  constructor(rows: readonly SqlRow[] = [], failure: unknown = undefined) {
    this.rows = rows;
    this.failure = failure;
  }

  async transaction<T>(callback: (transaction: SqlTransaction) => Promise<T>): Promise<T> {
    this.transactionCalls += 1;
    const query = ((strings: TemplateStringsArray, ...values: readonly unknown[]) => {
      this.invocations.push({ query: strings.join("?"), values: [...values] });
      if (this.failure !== undefined) throw this.failure;
      return Promise.resolve(this.rows);
    }) as unknown as SqlTransaction;
    return await callback(query);
  }

  async close(): Promise<void> {
    this.closeCalls += 1;
  }
}

interface HarnessOptions {
  readonly rows?: readonly SqlRow[];
  readonly failure?: unknown;
  readonly extensionOrigins?: string | undefined;
}

function createHarness(options: HarnessOptions = {}) {
  const database = new FakeDatabase(options.rows, options.failure);
  const logs: Array<{ level: string; metadata: unknown }> = [];
  let authenticationCalls = 0;
  let databaseFactoryCalls = 0;
  const handler = createRevokeDeviceHandler({
    authenticate: async () => {
      authenticationCalls += 1;
      return { userId: USER_ID, deviceId: JWT_DEVICE_ID };
    },
    createDatabase: async () => {
      databaseFactoryCalls += 1;
      return database;
    },
    environment: (name) => name === "SWARA_EXTENSION_ORIGINS"
      ? (options.extensionOrigins ?? EXTENSION_ORIGIN)
      : undefined,
    log: (level, metadata) => logs.push({ level, metadata }),
  });
  return {
    handler,
    database,
    logs,
    get authenticationCalls() {
      return authenticationCalls;
    },
    get databaseFactoryCalls() {
      return databaseFactoryCalls;
    },
  };
}

function post(body: unknown, idempotencyKey = "revoke-device-001"): Request {
  return new Request("https://swara.test/functions/v1/revoke-device", {
    method: "POST",
    headers: {
      origin: EXTENSION_ORIGIN,
      "content-type": "application/json",
      "idempotency-key": idempotencyKey,
    },
    body: JSON.stringify(body),
  });
}

test("revoke-device uses the verified user ID and body target, never a JWT device claim", async () => {
  const harness = createHarness({
    rows: [{ device_id: DEVICE_ID, revoked_at: "2026-08-24T12:00:00.000Z", duplicate: false }],
  });

  const response = await harness.handler(post({ device_id: DEVICE_ID }));
  const envelope = await response.json() as { ok: boolean; data: Record<string, unknown> };

  assert.equal(response.status, 200);
  assert.equal(envelope.ok, true);
  assert.deepEqual(envelope.data, {
    device_id: DEVICE_ID,
    revoked_at: "2026-08-24T12:00:00.000Z",
    duplicate: false,
  });
  assert.deepEqual(Object.keys(envelope.data).sort(), ["device_id", "duplicate", "revoked_at"]);
  assert.equal(harness.databaseFactoryCalls, 1);
  assert.equal(harness.database.transactionCalls, 1);
  assert.equal(harness.database.closeCalls, 1);
  assert.equal(harness.database.invocations.length, 1);
  assert.match(harness.database.invocations[0].query, /private\.revoke_device/);
  assert.deepEqual(harness.database.invocations[0].values, [USER_ID, DEVICE_ID, "revoke-device-001"]);
  assert.equal(harness.database.invocations[0].values.includes(JWT_DEVICE_ID), false);
});

test("revoke-device rejects unknown or noncanonical body values and bad idempotency keys", async () => {
  const unknown = createHarness();
  const unknownResponse = await unknown.handler(post({ device_id: DEVICE_ID, session_id: JWT_DEVICE_ID }));
  assert.equal(unknownResponse.status, 400);
  assert.equal(unknown.databaseFactoryCalls, 0);

  const noncanonicalDeviceId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa".toUpperCase();
  const uppercase = createHarness();
  const uppercaseResponse = await uppercase.handler(post({ device_id: noncanonicalDeviceId }));
  assert.equal(uppercaseResponse.status, 400);
  assert.equal(uppercase.databaseFactoryCalls, 0);

  for (const idempotencyKey of ["short", "bad key", "bad$key", "slash/key"]) {
    const harness = createHarness();
    const response = await harness.handler(post({ device_id: DEVICE_ID }, idempotencyKey));
    assert.equal(response.status, 400, idempotencyKey);
    assert.equal(harness.databaseFactoryCalls, 0, idempotencyKey);
  }
});

test("revoke-device enforces exact extension CORS and POST-only handling", async () => {
  const harness = createHarness();
  const preflight = await harness.handler(new Request("https://swara.test/functions/v1/revoke-device", {
    method: "OPTIONS",
    headers: {
      origin: EXTENSION_ORIGIN,
      "access-control-request-method": "POST",
      "access-control-request-headers": "authorization, apikey, content-type, idempotency-key",
    },
  }));
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get("access-control-allow-origin"), EXTENSION_ORIGIN);
  assert.equal(preflight.headers.get("access-control-allow-headers")?.includes("idempotency-key"), true);

  const wrongMethod = await harness.handler(new Request("https://swara.test/functions/v1/revoke-device", {
    method: "DELETE",
    headers: { origin: EXTENSION_ORIGIN },
  }));
  assert.equal(wrongMethod.status, 405);
  assert.equal(harness.authenticationCalls, 0);
});

test("revoke-device redacts cross-owner database errors and maps only safe conflicts to 409", async () => {
  const crossOwner = createHarness({
    failure: new Error("permission denied for another user; postgresql://secret@db.test"),
  });
  const failureResponse = await crossOwner.handler(post({ device_id: DEVICE_ID }));
  const failureBody = await failureResponse.text();
  assert.equal(failureResponse.status, 500);
  assert.doesNotMatch(failureBody, /permission denied|another user|secret@db/);
  assert.equal(JSON.stringify(crossOwner.logs).includes("another user"), false);
  assert.equal(crossOwner.database.closeCalls, 1);

  const conflict = createHarness({
    failure: Object.assign(
      new Error("Device revocation idempotency key is bound to different input"),
      { code: "22023" },
    ),
  });
  const conflictResponse = await conflict.handler(post({ device_id: DEVICE_ID }));
  assert.equal(conflictResponse.status, 409);
  assert.doesNotMatch(await conflictResponse.text(), /bound to different input/);
});
