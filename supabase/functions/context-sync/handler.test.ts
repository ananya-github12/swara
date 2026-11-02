import assert from "node:assert/strict";
import test from "node:test";

import { createContextSyncHandler } from "./handler.ts";
import type { ContextSyncClient, ContextSyncTable } from "./logic.ts";

const EXTENSION_ORIGIN = "chrome-extension://abcdefghijklmnopabcdefghijklmnop";
const USER_ID = "11111111-1111-4111-8111-111111111111";
const ITEM_ID = "22222222-2222-4222-8222-222222222222";
const REPLACEMENT_ID = "33333333-3333-4333-8333-333333333333";
const DOCUMENT_ID = "44444444-4444-4444-8444-444444444444";
const UPDATED_AT = "2026-08-27T00:00:00.000Z";

class FakeTable implements ContextSyncTable {
  readonly inserts: Record<string, unknown>[] = [];

  constructor(
    private readonly selectedRows: unknown,
    private readonly insertedRow: unknown,
    private readonly selectError: unknown = null,
    private readonly insertError: unknown = null,
  ) {}

  select(_columns: string): FakeSelectQuery {
    return new FakeSelectQuery(this.selectedRows, this.selectError);
  }

  insert(values: Record<string, unknown>): FakeInsertQuery {
    this.inserts.push(values);
    return new FakeInsertQuery(this.insertedRow, this.insertError);
  }
}

class FakeSelectQuery implements PromiseLike<{ data: unknown; error: unknown }> {
  constructor(private readonly data: unknown, private readonly error: unknown) {}
  select(_columns: string): this { return this; }
  eq(_column: string, _value: string): this { return this; }
  limit(_limit: number): this { return this; }
  then<TResult1 = { data: unknown; error: unknown }, TResult2 = never>(
    onfulfilled?: ((value: { data: unknown; error: unknown }) => TResult1 | PromiseLike<TResult1>) | null,
    onrejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null,
  ): PromiseLike<TResult1 | TResult2> {
    return Promise.resolve({ data: this.data, error: this.error }).then(onfulfilled, onrejected);
  }
}

class FakeInsertQuery implements PromiseLike<{ data: unknown; error: unknown }> {
  constructor(private readonly data: unknown, private readonly error: unknown) {}
  select(_columns: string): this { return this; }
  single(): this { return this; }
  then<TResult1 = { data: unknown; error: unknown }, TResult2 = never>(
    onfulfilled?: ((value: { data: unknown; error: unknown }) => TResult1 | PromiseLike<TResult1>) | null,
    onrejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null,
  ): PromiseLike<TResult1 | TResult2> {
    return Promise.resolve({ data: this.data, error: this.error }).then(onfulfilled, onrejected);
  }
}

function activeRow(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: ITEM_ID,
    user_id: USER_ID,
    type: "fact",
    key: "preferred_name",
    value: "Vasu",
    category: "profile",
    sensitivity: "standard",
    source_document_id: DOCUMENT_ID,
    source_type: "cloud_sync",
    scope: "persistent",
    status: "active",
    version: 1,
    supersedes_id: null,
    browser_session_id: null,
    task_id: null,
    created_at: UPDATED_AT,
    updated_at: UPDATED_AT,
    ...overrides,
  };
}

function createHarness(options: {
  selectedRows?: unknown;
  insertedRow?: unknown;
  selectError?: unknown;
  insertError?: unknown;
  origins?: string | undefined;
} = {}) {
  const table = new FakeTable(options.selectedRows ?? [], options.insertedRow ?? activeRow(), options.selectError, options.insertError);
  const logs: unknown[] = [];
  const client: ContextSyncClient = { from: () => table };
  const handler = createContextSyncHandler({
    authenticate: async () => ({ userId: USER_ID, client }),
    environment: (name) => name === "SWARA_EXTENSION_ORIGINS" ? (options.origins ?? EXTENSION_ORIGIN) : undefined,
    log: (_level, metadata) => logs.push(metadata),
  });
  return { handler, table, logs };
}

function post(item: Record<string, unknown>): Request {
  return new Request("https://swara.test/functions/v1/context-sync", {
    method: "POST",
    headers: { origin: EXTENSION_ORIGIN, "content-type": "application/json" },
    body: JSON.stringify({ operation: "upsert", item }),
  });
}

test("context-sync derives ownership and creates only a version-one persistent item", async () => {
  const harness = createHarness({ insertedRow: activeRow({ source_document_id: null, category: "general" }) });
  const response = await harness.handler(post({
    type: "fact",
    key: "preferred_name",
    value: "Vasu",
    scope: "persistent",
    category: null,
    updatedAt: UPDATED_AT,
  }));
  const envelope = await response.json() as { ok: boolean; data: { operation: string; item: Record<string, unknown> } };

  assert.equal(response.status, 200);
  assert.equal(envelope.ok, true);
  assert.equal(envelope.data.operation, "created");
  assert.deepEqual(envelope.data.item, {
    id: ITEM_ID,
    type: "fact",
    category: "general",
    key: "preferred_name",
    value: "Vasu",
    scope: "persistent",
    documentId: null,
    updatedAt: UPDATED_AT,
  });
  assert.deepEqual(harness.table.inserts, [{
    user_id: USER_ID,
    type: "fact",
    key: "preferred_name",
    value: "Vasu",
    category: "general",
    sensitivity: "standard",
    source_document_id: null,
    source_type: "cloud_sync",
    scope: "persistent",
    status: "active",
    version: 1,
    supersedes_id: null,
    browser_session_id: null,
    task_id: null,
  }]);
  assert.equal(JSON.stringify(harness.logs).includes("Vasu"), false);
});

test("context-sync turns a changed existing item into an inherited correction instead of an update", async () => {
  const harness = createHarness({
    selectedRows: [activeRow()],
    insertedRow: activeRow({
      id: REPLACEMENT_ID,
      type: "correction",
      value: "Yogesh",
      version: 2,
      supersedes_id: ITEM_ID,
      source_type: "cloud_sync_correction",
    }),
  });
  const response = await harness.handler(post({
    id: ITEM_ID,
    type: "document",
    key: "attacker-chosen-key",
    value: "Yogesh",
    scope: "persistent",
    category: "attacker-category",
    documentId: null,
  }));
  const envelope = await response.json() as { data: { operation: string; item: Record<string, unknown> } };

  assert.equal(response.status, 200);
  assert.equal(envelope.data.operation, "corrected");
  assert.equal(envelope.data.item.id, REPLACEMENT_ID);
  assert.deepEqual(harness.table.inserts, [{
    user_id: USER_ID,
    type: "correction",
    key: "preferred_name",
    value: "Yogesh",
    category: "profile",
    sensitivity: "standard",
    source_document_id: DOCUMENT_ID,
    source_type: "cloud_sync_correction",
    scope: "persistent",
    status: "active",
    version: 2,
    supersedes_id: ITEM_ID,
    browser_session_id: null,
    task_id: null,
  }]);
});

test("context-sync returns an unchanged active item without a write", async () => {
  const harness = createHarness({ selectedRows: [activeRow()] });
  const response = await harness.handler(post({ type: "fact", key: "preferred_name", value: "Vasu", scope: "persistent" }));
  const envelope = await response.json() as { data: { operation: string } };
  assert.equal(response.status, 200);
  assert.equal(envelope.data.operation, "unchanged");
  assert.equal(harness.table.inserts.length, 0);
});

test("context-sync rejects owner/lifecycle fields, temporary scope, and invalid values before persistence", async () => {
  const badItems = [
    { type: "fact", key: "name", value: "Vasu", scope: "persistent", user_id: USER_ID },
    { type: "correction", key: "name", value: "Vasu", scope: "persistent" },
    { type: "fact", key: "name", value: "Vasu", scope: "session" },
    { type: "fact", key: " name", value: "Vasu", scope: "persistent" },
    { type: "fact", key: "name", value: "\u0000", scope: "persistent" },
  ];
  for (const item of badItems) {
    const harness = createHarness();
    const response = await harness.handler(post(item));
    assert.equal(response.status, 400, JSON.stringify(item));
    assert.equal(harness.table.inserts.length, 0, JSON.stringify(item));
  }
});

test("context-sync enforces exact extension CORS and redacts persistence failures", async () => {
  const harness = createHarness({ insertError: Object.assign(new Error("duplicate value Vasu in postgres://secret@db"), { code: "23505" }) });
  const preflight = await harness.handler(new Request("https://swara.test/functions/v1/context-sync", {
    method: "OPTIONS",
    headers: {
      origin: EXTENSION_ORIGIN,
      "access-control-request-method": "POST",
      "access-control-request-headers": "authorization, apikey, content-type, idempotency-key",
    },
  }));
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get("access-control-allow-origin"), EXTENSION_ORIGIN);

  const response = await harness.handler(post({ type: "fact", key: "preferred_name", value: "Vasu", scope: "persistent" }));
  assert.equal(response.status, 409);
  const body = await response.text();
  assert.doesNotMatch(body, /duplicate value|postgres|secret@db|Vasu/);
});
