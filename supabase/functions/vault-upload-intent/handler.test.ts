import assert from "node:assert/strict";
import test from "node:test";

import type { SqlRow, SqlTransaction } from "../_shared/database.ts";
import {
  LEGACY_DOCUMENTS_BUCKET,
  VAULT_ORIGINALS_BUCKET,
} from "../_shared/validation.ts";
import {
  createVaultUploadIntentHandler,
  type VaultUploadIntentDatabase,
} from "./handler.ts";

const EXTENSION_ORIGIN = "chrome-extension://abcdefghijklmnopabcdefghijklmnop";
const USER_ID = "11111111-1111-4111-8111-111111111111";
const DOCUMENT_ID = "22222222-2222-4222-8222-222222222222";
const SHA256 = "a".repeat(64);
const FILENAME = "insurance-summary.pdf";
const PATH = `${USER_ID}/${DOCUMENT_ID}/${FILENAME}`;

interface QueryInvocation {
  readonly query: string;
  readonly values: readonly unknown[];
}

class FakeDatabase implements VaultUploadIntentDatabase {
  readonly invocations: QueryInvocation[] = [];
  readonly rows: readonly SqlRow[];
  readonly failure: unknown;
  readonly closeFailure: unknown;
  transactionCalls = 0;
  closeCalls = 0;

  constructor(
    rows: readonly SqlRow[] = [],
    failure: unknown = undefined,
    closeFailure: unknown = undefined,
  ) {
    this.rows = rows;
    this.failure = failure;
    this.closeFailure = closeFailure;
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
    if (this.closeFailure !== undefined) throw this.closeFailure;
  }
}

interface HarnessOptions {
  readonly rows?: readonly SqlRow[];
  readonly failure?: unknown;
  readonly closeFailure?: unknown;
  readonly extensionOrigins?: string | undefined;
}

function createHarness(options: HarnessOptions = {}) {
  const database = new FakeDatabase(options.rows, options.failure, options.closeFailure);
  const logs: Array<{ level: string; metadata: unknown }> = [];
  let authenticationCalls = 0;
  let databaseFactoryCalls = 0;
  const handler = createVaultUploadIntentHandler({
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

function post(body: unknown, idempotencyKey = "vault-intent-0001"): Request {
  return new Request("https://swara.test/functions/v1/vault-upload-intent", {
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
  return {
    filename: FILENAME,
    mime_type: "application/pdf",
    size_bytes: 45_600,
    sha256: SHA256,
    extraction_method: "local",
  };
}

test("vault-upload-intent sends only verified owner and validated metadata to the private function", async () => {
  const harness = createHarness({
    rows: [{
      document_id: DOCUMENT_ID,
      storage_bucket: VAULT_ORIGINALS_BUCKET,
      storage_path: PATH,
      status: "pending",
      duplicate: false,
      mime_type: "must-not-leave",
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
    status: "pending",
    duplicate: false,
    next_step: "Upload the file to the returned vault-originals path, then call vault-finalize-upload.",
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
  assert.match(harness.database.invocations[0].query, /private\.create_vault_upload_intent/);
  assert.doesNotMatch(harness.database.invocations[0].query, new RegExp(LEGACY_DOCUMENTS_BUCKET));
  assert.deepEqual(harness.database.invocations[0].values, [
    USER_ID,
    FILENAME,
    "application/pdf",
    45_600,
    SHA256,
    "local",
    "vault-intent-0001",
  ]);
  assert.equal(envelope.data.storage_bucket, VAULT_ORIGINALS_BUCKET);
  assert.notEqual(envelope.data.storage_bucket, LEGACY_DOCUMENTS_BUCKET);
  assert.equal(JSON.stringify(harness.logs).includes(FILENAME), false);
  assert.equal(JSON.stringify(harness.logs).includes("must-not-leave"), false);
});

test("vault-upload-intent rejects invalid MIME, size, SHA-256, filename, unknown fields, and idempotency before opening a database", async () => {
  const invalidBodies = [
    { ...validBody(), mime_type: "application/zip" },
    { ...validBody(), size_bytes: 0 },
    { ...validBody(), size_bytes: 50 * 1024 * 1024 + 1 },
    { ...validBody(), size_bytes: 1.5 },
    { ...validBody(), sha256: SHA256.toUpperCase() },
    { ...validBody(), filename: "../escape.pdf" },
    { ...validBody(), filename: ` ${FILENAME}` },
    { ...validBody(), user_id: USER_ID },
    { ...validBody(), storage_bucket: VAULT_ORIGINALS_BUCKET },
    { ...validBody(), storage_path: PATH },
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

test("vault-upload-intent enforces exact extension CORS and POST-only handling", async () => {
  const harness = createHarness();
  const preflight = await harness.handler(new Request("https://swara.test/functions/v1/vault-upload-intent", {
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

  const wrongOrigin = await harness.handler(new Request("https://swara.test/functions/v1/vault-upload-intent", {
    method: "OPTIONS",
    headers: {
      origin: "https://unexpected.example",
      "access-control-request-method": "POST",
      "access-control-request-headers": "content-type",
    },
  }));
  assert.equal(wrongOrigin.status, 403);

  const wrongMethod = await harness.handler(new Request("https://swara.test/functions/v1/vault-upload-intent", {
    method: "GET",
    headers: { origin: EXTENSION_ORIGIN },
  }));
  assert.equal(wrongMethod.status, 405);
  assert.equal(harness.authenticationCalls, 0);
});

test("vault-upload-intent redacts cross-owner database failures and an invalid legacy result", async () => {
  const crossOwner = createHarness({
    failure: new Error(`permission denied for another user; ${FILENAME}; postgresql://secret@db.test`),
  });
  const failureResponse = await crossOwner.handler(post(validBody()));
  const failureBody = await failureResponse.text();
  assert.equal(failureResponse.status, 500);
  assert.doesNotMatch(failureBody, /permission denied|another user|insurance-summary|secret@db/);
  assert.equal(JSON.stringify(crossOwner.logs).includes(FILENAME), false);
  assert.equal(crossOwner.database.closeCalls, 1);

  const legacy = createHarness({
    rows: [{
      document_id: DOCUMENT_ID,
      storage_bucket: LEGACY_DOCUMENTS_BUCKET,
      storage_path: PATH,
      status: "pending",
      duplicate: false,
    }],
  });
  const legacyResponse = await legacy.handler(post(validBody(), "vault-intent-0002"));
  assert.equal(legacyResponse.status, 500);
  assert.doesNotMatch(await legacyResponse.text(), new RegExp(LEGACY_DOCUMENTS_BUCKET));
});

test("vault-upload-intent contains database close failures without exposing them", async () => {
  const closeFailure = "postgresql://secret@db.test: failed after document upload";
  const harness = createHarness({
    rows: [{
      document_id: DOCUMENT_ID,
      storage_bucket: VAULT_ORIGINALS_BUCKET,
      storage_path: PATH,
      status: "pending",
      duplicate: false,
    }],
    closeFailure: new Error(closeFailure),
  });
  const response = await harness.handler(post(validBody(), "vault-intent-0003"));
  assert.equal(response.status, 200);
  assert.equal(harness.database.closeCalls, 1);
  assert.equal(JSON.stringify(harness.logs).includes(closeFailure), false);
});
