import assert from "node:assert/strict";
import test from "node:test";
import type { SqlRow, SqlTransaction } from "../_shared/database.ts";
import { createAccountExportHandler, type AccountExportDatabase } from "./handler.ts";

const ORIGIN = "chrome-extension://abcdefghijklmnopabcdefghijklmnop";
const USER_ID = "11111111-1111-4111-8111-111111111111";
const REQUEST_ID = "22222222-2222-4222-8222-222222222222";
class FakeDatabase implements AccountExportDatabase {
  invocations: Array<{ query: string; values: readonly unknown[] }> = [];
  constructor(readonly rows: readonly SqlRow[] = [], readonly failure?: unknown) {}
  async transaction<T>(callback: (transaction: SqlTransaction) => Promise<T>): Promise<T> {
    const transaction = ((strings: TemplateStringsArray, ...values: readonly unknown[]) => {
      this.invocations.push({ query: strings.join("?"), values });
      if (this.failure) throw this.failure;
      return Promise.resolve(this.rows);
    }) as unknown as SqlTransaction;
    return await callback(transaction);
  }
  async close(): Promise<void> {}
}
function request(body: unknown = {}, key = "account-export-001") {
  return new Request("https://swara.test/functions/v1/request-account-export", { method: "POST", headers: { origin: ORIGIN, authorization: "Bearer jwt", "content-type": "application/json", "idempotency-key": key }, body: JSON.stringify(body) });
}
function harness(options: { rows?: readonly SqlRow[]; failure?: unknown } = {}) {
  const database = new FakeDatabase(options.rows, options.failure);
  const logs: unknown[] = [];
  const handler = createAccountExportHandler({ authenticate: async () => ({ userId: USER_ID }), createDatabase: async () => database, environment: (name) => name === "SWARA_EXTENSION_ORIGINS" ? ORIGIN : undefined, log: (_level, metadata) => logs.push(metadata) });
  return { handler, database, logs };
}
test("request-account-export binds the private gateway to the authenticated owner and idempotency header", async () => {
  const target = harness({ rows: [{ request_id: REQUEST_ID }] });
  const response = await target.handler(request());
  assert.equal(response.status, 200);
  assert.deepEqual((await response.json() as { data: unknown }).data, { request_id: REQUEST_ID });
  assert.match(target.database.invocations[0].query, /private\.request_account_export/);
  assert.deepEqual(target.database.invocations[0].values, [USER_ID, "account-export-001"]);
});
test("request-account-export rejects caller-supplied owners and malformed idempotency before database access", async () => {
  for (const [body, key] of [[{ user_id: USER_ID }, "account-export-001"], [{}, "short"], [{}, "bad key"]] as const) {
    const target = harness();
    assert.equal((await target.handler(request(body, key))).status, 400);
    assert.equal(target.database.invocations.length, 0);
  }
});
test("request-account-export redacts private gateway failures", async () => {
  const target = harness({ failure: new Error("permission denied postgresql://secret@db.test for other user") });
  const response = await target.handler(request());
  assert.equal(response.status, 500);
  assert.doesNotMatch(await response.text(), /permission denied|secret@db|other user/);
  assert.equal(JSON.stringify(target.logs).includes("secret@db"), false);
});
