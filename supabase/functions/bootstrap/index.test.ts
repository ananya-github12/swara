import assert from "node:assert/strict";
import test from "node:test";

import {
  bootstrapUser,
  BootstrapAccessError,
  extensionCorsOptions,
} from "./logic.ts";

const USER_ID = "11111111-1111-4111-8111-111111111111";
const OTHER_USER_ID = "22222222-2222-4222-8222-222222222222";

type Row = Record<string, unknown>;

class FakeQuery implements PromiseLike<{ data: Row | null; error: unknown }> {
  private readonly table: FakeTable;
  private readonly columns: string;
  private readonly userId: string | undefined;

  constructor(
    table: FakeTable,
    columns: string,
    userId: string | undefined,
  ) {
    this.table = table;
    this.columns = columns;
    this.userId = userId;
  }

  eq(column: string, value: string): FakeQuery {
    assert.equal(column, "user_id");
    return new FakeQuery(this.table, this.columns, value);
  }

  maybeSingle(): FakeQuery {
    return this;
  }

  then<TResult1 = { data: Row | null; error: unknown }, TResult2 = never>(
    onfulfilled?: ((value: { data: Row | null; error: unknown }) => TResult1 | PromiseLike<TResult1>) | null,
    onrejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null,
  ): PromiseLike<TResult1 | TResult2> {
    return Promise.resolve(this.table.selectResult(this.userId, this.columns)).then(onfulfilled, onrejected);
  }
}

class FakeUpsert implements PromiseLike<{ data: null; error: unknown }> {
  private readonly table: FakeTable;
  private readonly row: Row;

  constructor(table: FakeTable, row: Row) {
    this.table = table;
    this.row = row;
  }

  then<TResult1 = { data: null; error: unknown }, TResult2 = never>(
    onfulfilled?: ((value: { data: null; error: unknown }) => TResult1 | PromiseLike<TResult1>) | null,
    onrejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null,
  ): PromiseLike<TResult1 | TResult2> {
    return Promise.resolve(this.table.upsertResult(this.row)).then(onfulfilled, onrejected);
  }
}

class FakeTable {
  readonly upserts: Row[] = [];
  private row: Row | null;
  private readonly ignoreFilters: boolean;

  constructor(row: Row | null, ignoreFilters = false) {
    this.row = row;
    this.ignoreFilters = ignoreFilters;
  }

  select(columns: string): FakeQuery {
    return new FakeQuery(this, columns, undefined);
  }

  upsert(row: Row, options: { onConflict: string; ignoreDuplicates: boolean }): FakeUpsert {
    assert.deepEqual(options, { onConflict: "user_id", ignoreDuplicates: true });
    this.upserts.push({ ...row });
    return new FakeUpsert(this, row);
  }

  selectResult(userId: string | undefined, columns: string): { data: Row | null; error: unknown } {
    if (!this.row || (!this.ignoreFilters && this.row.user_id !== userId)) return { data: null, error: null };
    const selected: Row = {};
    for (const column of columns.split(",")) {
      if (Object.hasOwn(this.row, column)) selected[column] = this.row[column];
    }
    return { data: selected, error: null };
  }

  upsertResult(row: Row): { data: null; error: unknown } {
    if (!this.row) this.row = { ...row, created_at: "now", updated_at: "now" };
    return { data: null, error: null };
  }
}

class FakeClient {
  private readonly tables: Record<string, FakeTable>;

  constructor(tables: Record<string, FakeTable>) {
    this.tables = tables;
  }

  from(table: string): FakeTable {
    const value = this.tables[table];
    assert.ok(value, `unexpected table ${table}`);
    return value;
  }
}

test("bootstrap is idempotent and creates each missing row once", async () => {
  const profiles = new FakeTable(null);
  const settings = new FakeTable(null);
  const client = new FakeClient({ profiles, user_settings: settings });

  const first = await bootstrapUser(client, USER_ID, {
    display_name: "Swara User",
    locale: "en-IN",
    timezone: "Asia/Kolkata",
    preferred_language: "en",
  });
  const second = await bootstrapUser(client, USER_ID, {
    display_name: "Changed Name",
    locale: "fr",
    preferred_language: "fr",
  });

  assert.deepEqual(first, second);
  assert.equal(profiles.upserts.length, 1);
  assert.equal(settings.upserts.length, 1);
  assert.equal(profiles.upserts[0].user_id, USER_ID);
  assert.equal(settings.upserts[0].user_id, USER_ID);
});

test("bootstrap never overwrites existing rows or returns unallowlisted columns", async () => {
  const profiles = new FakeTable({
    user_id: USER_ID,
    display_name: "Existing",
    locale: "en",
    timezone: "UTC",
    onboarding_state: "active",
    secret: "must-not-leave",
  });
  const settings = new FakeTable({
    user_id: USER_ID,
    preferred_language: "en",
    privacy_mode: "local-first",
    secret: "must-not-leave",
  });
  const result = await bootstrapUser(
    new FakeClient({ profiles, user_settings: settings }),
    USER_ID,
    { display_name: "Attempted overwrite", preferred_language: "fr" },
  );

  assert.equal(profiles.upserts.length, 0);
  assert.equal(settings.upserts.length, 0);
  assert.equal(result.profile.display_name, "Existing");
  assert.equal(result.settings.privacy_mode, "local-first");
  assert.equal("secret" in result.profile, false);
  assert.equal("secret" in result.settings, false);
});

test("bootstrap rejects a row that is not owned by the authenticated caller", async () => {
  const client = new FakeClient({
    profiles: new FakeTable({ user_id: OTHER_USER_ID, display_name: "Other" }, true),
    user_settings: new FakeTable(null),
  });

  await assert.rejects(
    bootstrapUser(client, USER_ID, {}),
    (error: unknown) => error instanceof BootstrapAccessError,
  );
});

test("bootstrap cannot reactivate a soft-deleted profile", async () => {
  const client = new FakeClient({
    profiles: new FakeTable({
      user_id: USER_ID,
      display_name: "Deleted",
      deleted_at: "2026-08-24T00:00:00Z",
    }),
    user_settings: new FakeTable({ user_id: USER_ID }),
  });

  await assert.rejects(
    bootstrapUser(client, USER_ID, {}),
    (error: unknown) => error instanceof BootstrapAccessError,
  );
});

test("bootstrap input and extension origins fail closed", async () => {
  assert.throws(() => extensionCorsOptions(undefined));
  assert.throws(() => extensionCorsOptions(""));
  assert.throws(() => extensionCorsOptions("*"));
  assert.throws(() => extensionCorsOptions("chrome-extension://invalid"));
  const client = new FakeClient({ profiles: new FakeTable(null), user_settings: new FakeTable(null) });
  await assert.rejects(bootstrapUser(client, USER_ID, { user_id: USER_ID }));
  await assert.rejects(bootstrapUser(client, USER_ID, { privacy_mode: "standard" }));
});
