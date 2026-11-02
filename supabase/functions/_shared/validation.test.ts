import {
  enumValue,
  idempotencyKey,
  safeVaultFilename,
  safeVaultStorageLocation,
  safeVaultStoragePath,
  sha256Hex,
  strictObject,
  uuid,
  validateVaultStoragePath,
  vaultStorageBucket,
  VAULT_ORIGINALS_BUCKET,
  LEGACY_DOCUMENTS_BUCKET,
  ValidationError,
} from "./validation.ts";
import { sanitizeLogMetadata, structuredLog } from "./logging.ts";

const TEST_USER = "11111111-1111-4111-8111-111111111111";
const TEST_RESOURCE = "22222222-2222-4222-8222-222222222222";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function rejects(action: () => unknown, message: string): void {
  let didReject = false;
  try {
    action();
  } catch (error) {
    didReject = error instanceof ValidationError;
  }
  assert(didReject, message);
}

async function runSmokeTests(): Promise<void> {
  strictObject({ first: "ok" }, ["first"], { requiredKeys: ["first"] });
  rejects(() => strictObject({ extra: true }, ["first"]), "unknown fields must be rejected");
  assert(uuid(TEST_USER) === TEST_USER, "UUID should be normalized and accepted");
  rejects(() => uuid("not-a-uuid"), "invalid UUID must be rejected");
  assert(enumValue("ready", ["pending", "ready"] as const) === "ready", "enum should be accepted");
  assert(idempotencyKey("request-01") === "request-01", "idempotency key should be accepted");
  rejects(() => idempotencyKey("  request-01  "), "padded idempotency key must be rejected");
  rejects(() => idempotencyKey("contains space"), "unsafe idempotency key must be rejected");
  assert(safeVaultFilename(" report.pdf ") === "report.pdf", "filename should be trimmed");
  rejects(() => safeVaultFilename("../secret.txt"), "path traversal filename must be rejected");
  rejects(() => safeVaultFilename("%2fsecret.txt"), "encoded separator must be rejected");
  assert(
    safeVaultStoragePath(TEST_USER, TEST_RESOURCE, "report.pdf") ===
      `${TEST_USER}/${TEST_RESOURCE}/report.pdf`,
    "Vault path must have the exact three segments",
  );
  assert(
    safeVaultStoragePath(VAULT_ORIGINALS_BUCKET, TEST_USER, TEST_RESOURCE, "report.pdf") ===
      `${TEST_USER}/${TEST_RESOURCE}/report.pdf`,
    "the bucket overload must produce the exact path",
  );
  rejects(
    () => safeVaultStoragePath(LEGACY_DOCUMENTS_BUCKET, TEST_USER, TEST_RESOURCE, "report.pdf"),
    "legacy bucket must be rejected",
  );
  assert(
    validateVaultStoragePath(`${TEST_USER}/${TEST_RESOURCE}/report.pdf`) ===
      `${TEST_USER}/${TEST_RESOURCE}/report.pdf`,
    "safe Vault path should validate",
  );
  rejects(
    () => validateVaultStoragePath(`${TEST_USER}/${TEST_RESOURCE}/../secret.txt`),
    "unsafe Vault path should be rejected",
  );
  assert(vaultStorageBucket(VAULT_ORIGINALS_BUCKET) === VAULT_ORIGINALS_BUCKET, "Vault bucket should be accepted");
  assert(
    safeVaultStorageLocation(VAULT_ORIGINALS_BUCKET, TEST_USER, TEST_RESOURCE, "report.pdf").path ===
      `${TEST_USER}/${TEST_RESOURCE}/report.pdf`,
    "Vault storage location should contain a safe path",
  );
  assert((await sha256Hex("abc")) === "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 should be deterministic");

  const metadata = sanitizeLogMetadata({
    function: "vault-search",
    event: "completed",
    correlation: "corr-1",
    status: "ok",
    duration: 12,
    attempt: 1,
    queue: "vault-ingest",
    message_id: "msg-1",
  });
  assert(metadata.duration === 12 && !Object.prototype.hasOwnProperty.call(metadata, "body"), "metadata should be allowlisted");
  rejects(() => sanitizeLogMetadata({ event: "x", payload: "secret" }), "payload must be rejected recursively");
  rejects(() => sanitizeLogMetadata({ event: { value: "secret" } }), "nested value must be rejected");
  rejects(() => sanitizeLogMetadata({ event: "x", unknown: "field" }), "unknown log field must be rejected");
  const lines: string[] = [];
  const record = structuredLog("info", { event: "completed" }, (line) => lines.push(line));
  assert(record.level === "info" && lines.length === 1, "structured logger should emit one JSON line");
  assert(!lines[0].includes("Error") && !lines[0].includes("secret"), "logs must not contain raw errors or secrets");
}

const deno = (globalThis as unknown as { Deno?: { test: (name: string, test: () => unknown) => void } }).Deno;
const nodeRuntime = (globalThis as unknown as { process?: { argv?: string[]; exitCode?: number } }).process;
if (deno) {
  deno.test("Swara validation and logging foundation", runSmokeTests);
} else if (nodeRuntime?.argv?.[1]?.endsWith("validation.test.ts")) {
  void runSmokeTests().then(
    () => console.log("validation.test.ts: smoke tests passed"),
    () => {
      nodeRuntime.exitCode = 1;
      console.error("validation smoke test failed");
    },
  );
}
