import assert from "node:assert/strict";
import test from "node:test";

import type { SqlRow, SqlTransaction } from "../_shared/database.ts";
import {
  LEGACY_DOCUMENTS_BUCKET,
  VAULT_ORIGINALS_BUCKET,
} from "../_shared/validation.ts";
import {
  createVaultFinalizeUploadHandler,
  type VaultFinalizeUploadDatabase,
} from "./handler.ts";

const EXTENSION_ORIGIN = "chrome-extension://abcdefghijklmnopabcdefghijklmnop";
const USER_ID = "11111111-1111-4111-8111-111111111111";
const DOCUMENT_ID = "22222222-2222-4222-8222-222222222222";
const SHA256 = "b".repeat(64);
const FILENAME = "bank-statement.pdf";
const PATH = `${USER_ID}/${DOCUMENT_ID}/${FILENAME}`;

interface QueryInvocation {
  readonly query: string;
  readonly values: readonly unknown[];
}

class FakeDatabase implements VaultFinalizeUploadDatabase {
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
  const handler = createVaultFinalizeUploadHandler({
    authenticate: async () => {
      authenticationCalls += 1;
      return { userId: USER_ID };
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

function post(body: unknown, idempotencyKey = "vault-finalize-0001"): Request {
  return new Request("https://swara.test/functions/v1/vault-finalize-upload", {
    method: "POST",
    headers: {
      origin: EXTENSION_ORIGIN,
      "content-type": "application/json",
      "idempotency-key": idempotencyKey,
    },
    body: JSON.stringify(body),
  });
}

function validBody(): Record<string, unknown> {
  return { document_id: DOCUMENT_ID, sha256: SHA256 };
}

test("vault-finalize-upload calls only the private pending-object boundary and returns a safe projection", async () => {
  const harness = createHarness({
    rows: [{
      document_id: DOCUMENT_ID,
      storage_bucket: VAULT_ORIGINALS_BUCKET,
      storage_path: PATH,
      status: "processing",
      duplicate: false,
      metadata: "must-not-leave",
    }],
  });

  const response = await harness.handler(post(validBody()));
  const envelope = await response.json() as { ok: boolean; data: Record<string, unknown>; correlation_id: string };

  assert.equal(response.status, 200);
  assert.equal(envelope.ok, true);
  assert.deepEqual(envelope.data, {
    document_id: DOCUMENT_ID,
    storage_bucket: VAULT_ORIGINALS_BUCKET,
    storage_path: PATH,
    status: "processing",
    duplicate: false,
    next_step: "Vault processing has started; read the document metadata for its current status.",
  });
  assert.deepEqual(Object.keys(envelope.data).sort(), [
    "document_id",
    "duplicate",
    "next_step",
    "status",
    "storage_bucket",
    "storage_path",
  ]);
  assert.match(envelope.correlation_id, /^[0-9a-f-]{36}$/);
  assert.equal(harness.databaseFactoryCalls, 1);
  assert.equal(harness.database.transactionCalls, 1);
  assert.equal(harness.database.closeCalls, 1);
  assert.equal(harness.database.invocations.length, 1);
  assert.match(harness.database.invocations[0].query, /private\.finalize_vault_upload/);
  assert.doesNotMatch(harness.database.invocations[0].query, /storage\.objects|update\s+public\.vault_documents/i);
  assert.doesNotMatch(harness.database.invocations[0].query, new RegExp(LEGACY_DOCUMENTS_BUCKET));
  assert.deepEqual(harness.database.invocations[0].values, [
    USER_ID,
    DOCUMENT_ID,
    SHA256,
    "vault-finalize-0001",
  ]);
  assert.notEqual(envelope.data.storage_bucket, LEGACY_DOCUMENTS_BUCKET);
  assert.equal(JSON.stringify(harness.logs).includes(FILENAME), false);
  assert.equal(JSON.stringify(harness.logs).includes("must-not-leave"), false);
});

test("vault-finalize-upload rejects invalid IDs, SHA-256 values, unknown fields, and idempotency before opening a database", async () => {
  const invalidBodies = [
    { document_id: "not-a-uuid", sha256: SHA256 },
    { document_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa".toUpperCase(), sha256: SHA256 },
    { document_id: DOCUMENT_ID, sha256: SHA256.toUpperCase() },
    { document_id: DOCUMENT_ID, sha256: "b".repeat(63) },
    { document_id: DOCUMENT_ID, sha256: SHA256, user_id: USER_ID },
    { document_id: DOCUMENT_ID, sha256: SHA256, storage_bucket: VAULT_ORIGINALS_BUCKET },
    { document_id: DOCUMENT_ID, sha256: SHA256, storage_path: PATH },
  ];

  for (const body of invalidBodies) {
    const harness = createHarness();
    const response = await harness.handler(post(body));
    assert.equal(response.status, 400, JSON.stringify(body));
    assert.equal(harness.databaseFactoryCalls, 0, JSON.stringify(body));
  }

  for (const idempotencyKey of ["short", "bad key", "bad$key", "slash/key"]) {
    const harness = createHarness();
    const response = await harness.handler(post(validBody(), idempotencyKey));
    assert.equal(response.status, 400, idempotencyKey);
    assert.equal(harness.databaseFactoryCalls, 0, idempotencyKey);
  }
});

test("vault-finalize-upload enforces exact extension CORS and POST-only handling", async () => {
  const harness = createHarness();
  const preflight = await harness.handler(new Request("https://swara.test/functions/v1/vault-finalize-upload", {
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

  const wrongOrigin = await harness.handler(new Request("https://swara.test/functions/v1/vault-finalize-upload", {
    method: "OPTIONS",
    headers: {
      origin: "https://unexpected.example",
      "access-control-request-method": "POST",
      "access-control-request-headers": "content-type",
    },
  }));
  assert.equal(wrongOrigin.status, 403);

  const wrongMethod = await harness.handler(new Request("https://swara.test/functions/v1/vault-finalize-upload", {
    method: "PATCH",
    headers: { origin: EXTENSION_ORIGIN },
  }));
  assert.equal(wrongMethod.status, 405);
  assert.equal(harness.authenticationCalls, 0);
});

test("vault-finalize-upload safely rejects missing-object state and cross-owner database errors without advancing metadata itself", async () => {
  const missingObject = createHarness({ rows: [] });
  const missingObjectResponse = await missingObject.handler(post(validBody()));
  assert.equal(missingObjectResponse.status, 409);
  assert.doesNotMatch(await missingObjectResponse.text(), /storage|object|pending/i);
  assert.equal(missingObject.database.closeCalls, 1);
  assert.equal(missingObject.database.invocations.length, 1);
  assert.doesNotMatch(missingObject.database.invocations[0].query, /update\s+public\.vault_documents/i);

  const crossOwner = createHarness({
    failure: new Error(`permission denied for another user; ${FILENAME}; postgresql://secret@db.test`),
  });
  const crossOwnerResponse = await crossOwner.handler(post(validBody(), "vault-finalize-0002"));
  const crossOwnerBody = await crossOwnerResponse.text();
  assert.equal(crossOwnerResponse.status, 409);
  assert.doesNotMatch(crossOwnerBody, /permission denied|another user|bank-statement|secret@db/);
  assert.equal(JSON.stringify(crossOwner.logs).includes(FILENAME), false);
  assert.equal(crossOwner.database.closeCalls, 1);
});

test("vault-finalize-upload rejects a non-originals result without disclosing legacy state", async () => {
  const harness = createHarness({
    rows: [{
      document_id: DOCUMENT_ID,
      storage_bucket: LEGACY_DOCUMENTS_BUCKET,
      storage_path: PATH,
      status: "processing",
      duplicate: false,
    }],
  });
  const response = await harness.handler(post(validBody(), "vault-finalize-0003"));
  assert.equal(response.status, 409);
  assert.doesNotMatch(await response.text(), new RegExp(LEGACY_DOCUMENTS_BUCKET));
});
