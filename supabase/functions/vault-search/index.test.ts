import assert from "node:assert/strict";
import test from "node:test";
import { parseVaultSearchInput, vaultSearchPattern } from "./logic.ts";

test("Vault search input is bounded and LIKE metacharacters are escaped", () => {
  assert.deepEqual(parseVaultSearchInput({ query: "  invoice  " }), { query: "invoice", limit: 20 });
  assert.equal(vaultSearchPattern("100%_ready\\"), "%100\\%\\_ready\\\\%");
  assert.throws(() => parseVaultSearchInput({ query: "x", limit: 51 }));
  assert.throws(() => parseVaultSearchInput({ query: "x", extra: true }));
});
