import assert from "node:assert/strict";
import test from "node:test";
import type { SqlTransaction } from "../_shared/database.ts";
import { createBillingCheckoutHandler } from "./handler.ts";

const ORIGIN = "chrome-extension://abcdefghijklmnopabcdefghijklmnop";
function request(body: unknown = {}, key = "billing-checkout-001") {
  return new Request("https://swara.test/functions/v1/create-billing-checkout", { method: "POST", headers: { origin: ORIGIN, authorization: "Bearer verified-user-jwt", "content-type": "application/json", "idempotency-key": key }, body: JSON.stringify(body) });
}
function harness(response = new Response(JSON.stringify({ checkoutUrl: "https://billing.alterity.test/checkout/abc" }), { status: 201 })) {
  const calls: Request[] = [];
  const databaseCalls: { readonly query: string; readonly values: readonly unknown[] }[] = [];
  const logs: unknown[] = [];
  const handler = createBillingCheckoutHandler({
    authenticate: async () => ({ userId: "11111111-1111-4111-8111-111111111111" }),
    createDatabase: async () => ({
      async transaction<T>(callback: (transaction: SqlTransaction) => Promise<T>): Promise<T> {
        const transaction = (async (strings: TemplateStringsArray, ...values: readonly unknown[]) => {
          databaseCalls.push({ query: Array.from(strings).join(" "), values });
          return [{ link_created: true }];
        }) as SqlTransaction;
        return await callback(transaction);
      },
      async close() {},
    }),
    environment: (name) => name === "SWARA_EXTENSION_ORIGINS" ? ORIGIN : name === "ALTERITY_CONTROL_PLANE_URL" ? "https://control.alterity.test/functions/v1/swara-platform" : undefined,
    fetch: async (input, init) => { calls.push(new Request(input, init)); return response; },
    log: (_level, metadata) => logs.push(metadata),
  });
  return { handler, calls, databaseCalls, logs };
}
test("create-billing-checkout forwards a verified identity, header idempotency, and no caller owner to Alterity", async () => {
  const target = harness();
  const response = await target.handler(request());
  assert.equal(response.status, 200);
  assert.deepEqual((await response.json() as { data: unknown }).data, { url: "https://billing.alterity.test/checkout/abc" });
  assert.equal(target.calls.length, 1);
  assert.equal(target.calls[0].headers.get("idempotency-key"), "billing-checkout-001");
  assert.equal(target.calls[0].headers.get("authorization"), "Bearer verified-user-jwt");
  assert.deepEqual(await target.calls[0].json(), { action: "create_billing_checkout", product: "swara" });
});
test("create-billing-checkout establishes only an opaque customer reference returned by Alterity", async () => {
  const target = harness(new Response(JSON.stringify({
    checkout_url: "https://billing.alterity.test/checkout/abc",
    customer_reference: "cus_alterity_001",
  })));
  const response = await target.handler(request());
  assert.equal(response.status, 200);
  assert.deepEqual((await response.json() as { data: unknown }).data, { url: "https://billing.alterity.test/checkout/abc" });
  assert.equal(target.databaseCalls.length, 1);
  assert.match(target.databaseCalls[0].query, /establish_billing_link/);
  assert.deepEqual(target.databaseCalls[0].values, ["11111111-1111-4111-8111-111111111111", "cus_alterity_001"]);
});
test("create-billing-checkout validates an empty contract and never exposes billing-provider errors", async () => {
  const invalid = harness();
  assert.equal((await invalid.handler(request({ user_id: "11111111-1111-4111-8111-111111111111" }))).status, 400);
  assert.equal(invalid.calls.length, 0);
  assert.equal((await invalid.handler(request({}, "short"))).status, 400);
  const failed = harness(new Response("postgresql://secret@provider.test customer denied", { status: 500 }));
  const response = await failed.handler(request());
  assert.equal(response.status, 500);
  assert.doesNotMatch(await response.text(), /secret@provider|customer denied/);
  assert.equal(JSON.stringify(failed.logs).includes("secret@provider"), false);
});
