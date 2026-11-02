import assert from "node:assert/strict";
import test from "node:test";
import type { SqlRow, SqlTransaction } from "../_shared/database.ts";
import { createAccountDeletionHandler, type AccountDeletionDatabase } from "./handler.ts";

const ORIGIN = "chrome-extension://abcdefghijklmnopabcdefghijklmnop";
const USER_ID = "11111111-1111-4111-8111-111111111111";
const EXPORT_ID = "22222222-2222-4222-8222-22222222222a";
const REQUEST_ID = "33333333-3333-4333-8333-333333333333";
class FakeDatabase implements AccountDeletionDatabase {
  invocations: Array<{ query: string; values: readonly unknown[] }> = [];
  async transaction<T>(callback: (transaction: SqlTransaction) => Promise<T>): Promise<T> {
    const transaction = ((strings: TemplateStringsArray, ...values: readonly unknown[]) => {
      this.invocations.push({ query: strings.join("?"), values });
      return Promise.resolve([{ request_id: REQUEST_ID }] as readonly SqlRow[]);
    }) as unknown as SqlTransaction;
    return await callback(transaction);
  }
  async close(): Promise<void> {}
}
function request(body: unknown, key = "account-delete-001") {
  return new Request("https://swara.test/functions/v1/request-account-deletion", { method: "POST", headers: { origin: ORIGIN, "content-type": "application/json", "idempotency-key": key }, body: JSON.stringify(body) });
}
function harness() {
  const database = new FakeDatabase();
  return { database, handler: createAccountDeletionHandler({ authenticate: async () => ({ userId: USER_ID }), createDatabase: async () => database, environment: (name) => name === "SWARA_EXTENSION_ORIGINS" ? ORIGIN : undefined, log: () => undefined }) };
}
test("request-account-deletion sends only verified owner, optional export, and header idempotency to its gateway", async () => {
  const target = harness();
  const response = await target.handler(request({ export_request_id: EXPORT_ID }));
  assert.equal(response.status, 200);
  assert.match(target.database.invocations[0].query, /private\.request_account_deletion/);
  assert.deepEqual(target.database.invocations[0].values, [USER_ID, "account-delete-001", EXPORT_ID]);
});
test("request-account-deletion rejects injected owners, noncanonical exports, and invalid keys", async () => {
  for (const [body, key] of [[{ user_id: USER_ID }, "account-delete-001"], [{ export_request_id: EXPORT_ID.toUpperCase() }, "account-delete-001"], [{}, "short"]] as const) {
    const target = harness();
    assert.equal((await target.handler(request(body, key))).status, 400);
    assert.equal(target.database.invocations.length, 0);
  }
});
