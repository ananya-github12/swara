import assert from "node:assert/strict";
import test from "node:test";
import type { SqlTransaction } from "../_shared/database.ts";
import { createAlterityBillingWebhookHandler } from "./handler.ts";

const proof = {
  bodySha256: "a".repeat(64),
  eventId: "evt_swara_01a0317b-0000-7000-8000-000000000001",
  signatureVersion: "v1" as const,
  timestamp: 1_787_536_800,
};

const projection = {
  user_id: "11111111-1111-4111-8111-111111111111",
  customer_reference: "cus_alterity_001",
  link_status: "active",
  plan_code: "pro",
  subscription_status: "active",
  capabilities: { vault_search: true },
  limits: { actions_per_month: 1000 },
  valid_until: "2026-10-01T00:00:00.000Z",
  source_version: "entitlement-2026-10-01",
};

test("webhook verifies before database access and finalizes only the digest receipt", async () => {
  const events: string[] = [];
  const transaction = (async (strings: TemplateStringsArray, ...values: readonly unknown[]) => {
    events.push(Array.from(strings).join(" "));
    if (Array.from(strings).join(" ").includes("claim_alterity_webhook")) return [{ claim_outcome: "first_delivery" }];
    if (Array.from(strings).join(" ").includes("project_billing_entitlement")) {
      assert.equal(values.includes("cus_alterity_001"), true);
      assert.equal(values.some((value) => value === "ignored"), false);
      return [{ link_written: true, snapshot_written: true }];
    }
    return [{ status: "processed", finalized: true, processed_at: new Date().toISOString() }];
  }) as SqlTransaction;
  const handler = createAlterityBillingWebhookHandler({
    verify: async () => {
      events.push("verified");
      return proof;
    },
    createDatabase: async () => ({
      async transaction<T>(callback: (transaction: SqlTransaction) => Promise<T>): Promise<T> {
        events.push("database");
        return await callback(transaction);
      },
      async close() {},
    }),
  });

  const response = await handler(new Request("https://swara.test", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ type: "entitlement.updated", data: projection }),
  }));
  assert.equal(response.status, 200);
  assert.equal(events[0], "verified");
  assert.equal(events[1], "database");
  assert.doesNotMatch(events.join("\n"), /customer_reference|vault_search|actions_per_month/);
});

test("webhook rejects incomplete or unsupported billing projection before database access", async () => {
  let databaseCalls = 0;
  const handler = createAlterityBillingWebhookHandler({
    verify: async () => proof,
    createDatabase: async () => {
      databaseCalls += 1;
      throw new Error("must not create database");
    },
  });
  const response = await handler(new Request("https://swara.test", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ type: "invoice.paid", data: projection }),
  }));
  assert.equal(response.status, 400);
  assert.equal(databaseCalls, 0);
  const missing = await handler(new Request("https://swara.test", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ type: "entitlement.updated", data: { ...projection, source_version: undefined } }),
  }));
  assert.equal(missing.status, 400);
});

test("hash conflicts are fail-closed", async () => {
  const handler = createAlterityBillingWebhookHandler({
    verify: async () => proof,
    createDatabase: async () => ({
      async transaction<T>(callback: (transaction: SqlTransaction) => Promise<T>): Promise<T> {
        const tx = (async () => [{ claim_outcome: "hash_conflict" }]) as SqlTransaction;
        return await callback(tx);
      },
      async close() {},
    }),
  });
  const response = await handler(new Request("https://swara.test", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ type: "entitlement.updated", data: projection }),
  }));
  assert.equal(response.status, 409);
});
