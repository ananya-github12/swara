import assert from "node:assert/strict";
import test from "node:test";
import type { SqlTransaction } from "../_shared/database.ts";
import { createBillingPortalHandler } from "./handler.ts";

const ORIGIN = "chrome-extension://abcdefghijklmnopabcdefghijklmnop";
function request(body: unknown = {}, key = "billing-portal-001") {
  return new Request("https://swara.test/functions/v1/create-billing-portal-link", { method: "POST", headers: { origin: ORIGIN, authorization: "Bearer verified-user-jwt", "content-type": "application/json", "idempotency-key": key }, body: JSON.stringify(body) });
}
test("create-billing-portal-link uses header idempotency and the Alterity-owned portal action", async () => {
  const calls: Request[] = [];
  const databaseCalls: string[] = [];
  const handler = createBillingPortalHandler({
    authenticate: async () => ({ userId: "11111111-1111-4111-8111-111111111111" }),
    createDatabase: async () => ({
      async transaction<T>(callback: (transaction: SqlTransaction) => Promise<T>): Promise<T> {
        const transaction = (async (strings: TemplateStringsArray) => {
          databaseCalls.push(Array.from(strings).join(" "));
          return [{ link_created: true }];
        }) as SqlTransaction;
        return await callback(transaction);
      },
      async close() {},
    }),
    environment: (name) => name === "SWARA_EXTENSION_ORIGINS" ? ORIGIN : name === "ALTERITY_CONTROL_PLANE_URL" ? "https://control.alterity.test/functions/v1/swara-platform" : undefined,
    fetch: async (input, init) => { calls.push(new Request(input, init)); return new Response(JSON.stringify({ portal_url: "https://billing.alterity.test/portal/abc", customerReference: "cus_alterity_001" })); },
    log: () => undefined,
  });
  const response = await handler(request());
  assert.equal(response.status, 200);
  assert.deepEqual(await calls[0].json(), { action: "create_billing_portal_link", product: "swara" });
  assert.equal(calls[0].headers.get("idempotency-key"), "billing-portal-001");
  assert.equal(databaseCalls.length, 1);
  assert.match(databaseCalls[0], /establish_billing_link/);
});
test("create-billing-portal-link rejects injected owner input and unsafe provider links", async () => {
  const handler = createBillingPortalHandler({
    authenticate: async () => ({ userId: "11111111-1111-4111-8111-111111111111" }),
    createDatabase: async () => { throw new Error("must not be called"); },
    environment: (name) => name === "SWARA_EXTENSION_ORIGINS" ? ORIGIN : name === "ALTERITY_CONTROL_PLANE_URL" ? "https://control.alterity.test/functions/v1/swara-platform" : undefined,
    fetch: async () => new Response(JSON.stringify({ url: "javascript:alert(1)" })),
    log: () => undefined,
  });
  assert.equal((await handler(request({ user_id: "11111111-1111-4111-8111-111111111111" }))).status, 400);
  const response = await handler(request());
  assert.equal(response.status, 500);
  assert.doesNotMatch(await response.text(), /javascript/);
});
