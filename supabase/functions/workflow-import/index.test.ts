import assert from "node:assert/strict";
import test from "node:test";

import {
  classifyDatabaseError,
  executeWorkflowImportQuery,
  logWorkflowImportEvent,
  parseWorkflowImportInput,
  toWorkflowImportHttpError,
  workflowImportCorsOptions,
  type WorkflowImportInput,
  WorkflowImportDatabaseError,
} from "./logic.ts";
import {
  preflightResponse,
  requireMethod,
  HttpError,
} from "../_shared/http.ts";

const USER_ID = "11111111-1111-4111-8111-111111111111";
const OTHER_USER_ID = "22222222-2222-4222-8222-222222222222";
const WORKFLOW_ID = "33333333-3333-4333-8333-333333333333";
const EXPECTED_VERSION_ID = "44444444-4444-4444-8444-444444444444";
const CORRELATION_ID = "55555555-5555-4555-8555-555555555555";
const CONTENT_HASH = "a".repeat(64);
const DEFINITION = { steps: [{ action: "click" }], label: "safe" };

function body(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    name: "Example workflow",
    schema_version: 1,
    definition: DEFINITION,
    idempotency_key: "workflow-import-0001",
    ...overrides,
  };
}

function resultRow(overrides: Record<string, unknown> = {}) {
  return [{
    workflow_id: WORKFLOW_ID,
    version_id: EXPECTED_VERSION_ID,
    content_hash: CONTENT_HASH,
    step_count: 1,
    duplicate: false,
    ...overrides,
  }];
}

test("create parameters are strict, owner-derived, and parameterized", async () => {
  const input = parseWorkflowImportInput(body());
  let values: readonly unknown[] = [];
  let sql = "";
  const transaction = (strings: TemplateStringsArray, ...queryValues: readonly unknown[]) => {
    sql = Array.from(strings).join("?");
    values = queryValues;
    return Promise.resolve(resultRow());
  };

  const result = await executeWorkflowImportQuery(
    transaction,
    USER_ID,
    input,
    CORRELATION_ID,
  );

  assert.deepEqual(result, {
    workflow_id: WORKFLOW_ID,
    version_id: EXPECTED_VERSION_ID,
    content_hash: CONTENT_HASH,
    step_count: 1,
    duplicate: false,
  });
  assert.match(sql, /private\.import_workflow_atomic/);
  assert.equal(values[0], USER_ID);
  assert.equal(values[1], null);
  assert.equal(values[2], "Example workflow");
  assert.equal(values[3], 1);
  assert.equal(values[4], JSON.stringify(DEFINITION));
  assert.equal(values[5], null);
  assert.equal(values[6], "workflow-import-0001");
  assert.equal(values[7], CORRELATION_ID);
  assert.doesNotMatch(sql, /Example workflow|click|label/);
  assert.ok(!Object.hasOwn(body(), "user_id"));
});

test("existing-workflow parameters include the optimistic-concurrency version", async () => {
  const input = parseWorkflowImportInput(body({
    workflow_id: WORKFLOW_ID,
    expected_current_version_id: EXPECTED_VERSION_ID,
  }));
  let values: readonly unknown[] = [];
  const transaction = (_strings: TemplateStringsArray, ...queryValues: readonly unknown[]) => {
    values = queryValues;
    return Promise.resolve(resultRow({ duplicate: true }));
  };

  const result = await executeWorkflowImportQuery(transaction, USER_ID, input, CORRELATION_ID);
  assert.equal(result.duplicate, true);
  assert.equal(values[0], USER_ID);
  assert.equal(values[1], WORKFLOW_ID);
  assert.equal(values[5], EXPECTED_VERSION_ID);
});

test("an existing workflow without expected_current_version_id is a generic 409 conflict", () => {
  assert.throws(
    () => parseWorkflowImportInput(body({ workflow_id: WORKFLOW_ID })),
    (error: unknown) => {
      const httpError = toWorkflowImportHttpError(error);
      assert.equal(httpError.status, 409);
      assert.equal(httpError.publicMessage, "Workflow version conflict.");
      return true;
    },
  );
});

test("create rejects a non-null expected version and unknown fields", () => {
  assert.throws(() => parseWorkflowImportInput(body({ expected_current_version_id: EXPECTED_VERSION_ID })));
  assert.throws(() => parseWorkflowImportInput(body({ user_id: USER_ID })));
  assert.throws(() => parseWorkflowImportInput(body({ content_hash: CONTENT_HASH })));
  assert.throws(() => parseWorkflowImportInput(body({ step_count: 1 })));
});

test("oversized definitions and more than fifty steps are rejected", () => {
  assert.throws(() => parseWorkflowImportInput(body({
    definition: { steps: [{ value: "x".repeat(262_200) }] },
  })));
  assert.throws(() => parseWorkflowImportInput(body({
    definition: { steps: Array.from({ length: 51 }, () => ({ action: "click" })) },
  })));
});

test("the idempotency contract is exactly 8..200 safe ASCII characters", () => {
  assert.doesNotThrow(() => parseWorkflowImportInput(body({ idempotency_key: "A".repeat(200) })));
  assert.throws(() => parseWorkflowImportInput(body({ idempotency_key: "A".repeat(7) })));
  assert.throws(() => parseWorkflowImportInput(body({ idempotency_key: " AAAAAAA" })));
  assert.throws(() => parseWorkflowImportInput(body({ idempotency_key: "AAAAAAA/" })));
  assert.throws(() => parseWorkflowImportInput(body({ idempotency_key: "AAAAAAAA\n" })));
});

test("database secret validation is redacted and mapped to generic 400", async () => {
  const secretDefinition = { steps: [{ action: "fill", value: "sk-super-secret-definition" }] };
  const input = parseWorkflowImportInput(body({ definition: secretDefinition }));
  const transaction = async () => {
    const driverError = new Error("Workflow definitions cannot contain sk-super-secret-definition");
    Object.assign(driverError, {
      code: "22023",
      detail: "definition contains secret payload",
    });
    throw driverError;
  };

  await assert.rejects(
    executeWorkflowImportQuery(transaction, USER_ID, input, CORRELATION_ID),
    (error: unknown) => {
      assert(error instanceof WorkflowImportDatabaseError);
      assert.equal(error.kind, "validation");
      assert.doesNotMatch(String(error), /sk-super-secret-definition|definition contains secret/);
      const httpError = toWorkflowImportHttpError(error);
      assert.equal(httpError.status, 400);
      assert.equal(httpError.publicMessage, "The workflow import request is invalid.");
      return true;
    },
  );
});

test("cross-owner database denial does not disclose ownership", () => {
  const error = classifyDatabaseError({
    code: "42501",
    message: `workflow belongs to ${OTHER_USER_ID}`,
  });
  assert.equal(error.kind, "not_found");
  const httpError = toWorkflowImportHttpError(error);
  assert.equal(httpError.status, 404);
  assert.equal(httpError.publicMessage, "Workflow is not available.");
  assert.doesNotMatch(httpError.publicMessage, new RegExp(OTHER_USER_ID));
});

test("concurrency SQLSTATE maps to 409 without retaining provider text", () => {
  const error = classifyDatabaseError({
    code: "40001",
    message: "expected version 1 does not match current version 2",
  });
  assert.equal(error.kind, "conflict");
  const httpError = toWorkflowImportHttpError(error);
  assert.equal(httpError.status, 409);
  assert.equal(httpError.publicMessage, "Workflow version conflict.");
  assert.doesNotMatch(String(error), /expected version|current version/);
});

test("workflow-import logging has no raw definition/body fields", () => {
  const lines: string[] = [];
  logWorkflowImportEvent("error", "failed", CORRELATION_ID, 400, 3, (line) => lines.push(line));
  assert.equal(lines.length, 1);
  assert.doesNotMatch(lines[0], /definition|body|payload|sk-super-secret/iu);
  assert.match(lines[0], /workflow-import/);
});

test("CORS is exact-extension-only and only POST is allowed", () => {
  const origin = "chrome-extension://abcdefghijklmnopabcdefghijklmnop";
  const cors = workflowImportCorsOptions(origin);
  const preflight = new Request("https://api.example.test/workflow-import", {
    method: "OPTIONS",
    headers: {
      origin,
      "access-control-request-method": "POST",
      "access-control-request-headers": "authorization, content-type, x-correlation-id",
    },
  });
  const response = preflightResponse(preflight, cors, CORRELATION_ID);
  assert.equal(response.status, 204);
  assert.equal(response.headers.get("access-control-allow-origin"), origin);
  assert.throws(
    () => requireMethod(new Request("https://api.example.test/workflow-import", { method: "GET" }), "POST"),
    (error: unknown) => error instanceof HttpError && error.status === 405,
  );
  assert.throws(() => workflowImportCorsOptions("*"));
});

test("the projected row rejects malformed database output", async () => {
  const input = parseWorkflowImportInput(body());
  const transaction = (_strings: TemplateStringsArray, ..._values: readonly unknown[]) =>
    Promise.resolve(resultRow({ content_hash: "not-a-hash" }));
  await assert.rejects(
    executeWorkflowImportQuery(transaction, USER_ID, input, CORRELATION_ID),
    (error: unknown) => error instanceof WorkflowImportDatabaseError && error.kind === "internal",
  );
});
