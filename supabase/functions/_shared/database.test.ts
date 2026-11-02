import assert from "node:assert/strict";
import test from "node:test";

import {
  RuntimeDatabase,
  RuntimeDatabaseError,
  type SqlTransaction,
  validateRuntimeDatabaseUrl,
} from "./database.ts";

function fakeClient() {
  const transaction = (async () => []) as SqlTransaction;
  return {
    async begin<T>(callback: (value: SqlTransaction) => Promise<T>): Promise<T> {
      return await callback(transaction);
    },
    async end(): Promise<void> {},
  };
}

test("runtime URL requires a dedicated credentialed Postgres login", () => {
  assert.throws(
    () => validateRuntimeDatabaseUrl(undefined, "SWARA_API_DATABASE_URL"),
    /SWARA_API_DATABASE_URL is required/,
  );
  assert.throws(
    () => validateRuntimeDatabaseUrl("https://example.test/postgres", "DB"),
    /PostgreSQL protocol/,
  );
  assert.throws(
    () => validateRuntimeDatabaseUrl("postgresql://postgres:secret@example.test/postgres", "DB"),
    /dedicated Swara login role/,
  );
  assert.throws(
    () => validateRuntimeDatabaseUrl("postgresql://postgres.projectref:secret@example.test/postgres", "DB"),
    /dedicated Swara login role/,
  );
  assert.throws(
    () => validateRuntimeDatabaseUrl("postgresql://swara_api:secret@example.test/db?sslmode=disable", "DB"),
    /must not disable TLS/,
  );
  assert.equal(
    validateRuntimeDatabaseUrl(
      "postgresql://swara_api_login:secret@example.test/postgres?sslmode=require",
      "DB",
    ),
    "postgresql://swara_api_login:secret@example.test/postgres?sslmode=require",
  );
});

test("API database uses only its custom URL and transaction-pooler-safe options", async () => {
  const reads: string[] = [];
  let receivedUrl = "";
  let receivedOptions: Record<string, unknown> = {};
  const database = await RuntimeDatabase.fromEnvironment("api", {
    environment(name) {
      reads.push(name);
      return "postgresql://swara_api_login:secret@example.test/postgres?sslmode=require";
    },
    factory(url, options) {
      receivedUrl = url;
      receivedOptions = { ...options };
      return fakeClient();
    },
  });

  assert.deepEqual(reads, ["SWARA_API_DATABASE_URL"]);
  assert.match(receivedUrl, /^postgresql:\/\/swara_api_login:/);
  assert.equal(receivedOptions.prepare, false);
  assert.equal(receivedOptions.max, 1);
  assert.equal(receivedOptions.ssl, "require");
  assert.equal(receivedOptions.application_name, "swara-edge-api");
  await database.close();
});

test("worker database accepts loopback for local development", async () => {
  let ssl: unknown;
  const database = await RuntimeDatabase.fromEnvironment("worker", {
    environment: () => "postgresql://swara_worker_login:secret@127.0.0.1:55322/postgres",
    factory(_url, options) {
      ssl = options.ssl;
      return fakeClient();
    },
  });
  assert.equal(ssl, false);
  await database.close();
});

test("transaction and close failures are redacted and closed clients stay closed", async () => {
  const database = await RuntimeDatabase.fromEnvironment("api", {
    environment: () => "postgresql://swara_api_login:secret@localhost:55322/postgres",
    factory: () => ({
      async begin<T>(): Promise<T> {
        throw new Error("postgresql://secret@example.test and sensitive value");
      },
      async end(): Promise<void> {},
    }),
  });

  await assert.rejects(database.transaction(async () => 1), (error: unknown) => {
    assert(error instanceof RuntimeDatabaseError);
    assert.equal(error.message, "Runtime database transaction failed.");
    assert.doesNotMatch(String(error), /secret|sensitive|example\.test/);
    return true;
  });

  await database.close();
  await database.close();
  await assert.rejects(database.transaction(async () => 1), /Runtime database is closed/);
});
