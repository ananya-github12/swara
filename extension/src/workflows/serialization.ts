import type { Action, ActionType } from '../types';
import { assertSafeWorkflowAction, isSensitiveText, placeholders, workflowActionTypes } from './security';
import {
  MAX_WORKFLOW_ACTIONS,
  MAX_WORKFLOW_BYTES,
  MAX_WORKFLOW_VARIABLES,
  WORKFLOW_SCHEMA_VERSION,
  type LocalWorkflow,
  type PageFingerprint,
  type WorkflowAction,
  type WorkflowVariable,
} from './types';

const MAX_STRING = 4_000;

export function exportWorkflow(workflow: LocalWorkflow): string {
  const validated = validateWorkflow(workflow);
  const serialized = JSON.stringify(validated, null, 2);
  if (new TextEncoder().encode(serialized).byteLength > MAX_WORKFLOW_BYTES) throw new Error('Workflow export exceeds the size limit.');
  return serialized;
}

export function importWorkflow(serialized: string): LocalWorkflow {
  if (new TextEncoder().encode(serialized).byteLength > MAX_WORKFLOW_BYTES) throw new Error('Workflow import exceeds the 256 KB size limit.');
  let parsed: unknown;
  try {
    parsed = JSON.parse(serialized);
  } catch {
    throw new Error('Workflow import is not valid JSON.');
  }
  return validateWorkflow(parsed);
}

/** Strictly validates untrusted JSON and strips no unknown data: unknown keys fail. */
export function validateWorkflow(value: unknown): LocalWorkflow {
  const record = object(value, 'Workflow');
  exactKeys(record, ['schemaVersion', 'id', 'name', 'createdAt', 'updatedAt', 'variables', 'actions'], 'Workflow');
  if (record.schemaVersion !== WORKFLOW_SCHEMA_VERSION) throw new Error(`Unsupported workflow schema version. Expected ${WORKFLOW_SCHEMA_VERSION}.`);
  const workflow: LocalWorkflow = {
    schemaVersion: WORKFLOW_SCHEMA_VERSION,
    id: identifier(record.id, 'Workflow id'),
    name: text(record.name, 'Workflow name', 120, false),
    createdAt: isoDate(record.createdAt, 'Workflow createdAt'),
    updatedAt: isoDate(record.updatedAt, 'Workflow updatedAt'),
    variables: array(record.variables, 'Workflow variables', MAX_WORKFLOW_VARIABLES).map(validateVariable),
    actions: array(record.actions, 'Workflow actions', MAX_WORKFLOW_ACTIONS).map(validateAction),
  };
  if (new Set(workflow.variables.map((variable) => variable.key)).size !== workflow.variables.length) throw new Error('Workflow variable names must be unique.');
  if (new Set(workflow.actions.map((action) => action.id)).size !== workflow.actions.length) throw new Error('Workflow action identifiers must be unique.');
  const variableKeys = new Set(workflow.variables.map((variable) => variable.key));
  for (const action of workflow.actions) {
    for (const key of placeholders(action.action.value)) {
      if (!variableKeys.has(key)) throw new Error(`Workflow action references undeclared variable "${key}".`);
    }
  }
  return workflow;
}

function validateVariable(value: unknown): WorkflowVariable {
  const record = object(value, 'Workflow variable');
  exactKeys(record, ['key', 'label', 'defaultValue', 'sensitive'], 'Workflow variable', ['defaultValue', 'sensitive']);
  const sensitive = optionalBoolean(record.sensitive, 'Workflow variable sensitive') ?? false;
  const defaultValue = optionalText(record.defaultValue, 'Workflow variable defaultValue', MAX_STRING);
  if (sensitive && defaultValue !== undefined) throw new Error('Sensitive workflow variables cannot have saved default values.');
  if (defaultValue !== undefined && isSensitiveText(defaultValue)) throw new Error('Workflow variable defaults cannot contain secrets.');
  return {
    key: variableKey(record.key),
    label: text(record.label, 'Workflow variable label', 120, false),
    ...(defaultValue === undefined ? {} : { defaultValue }),
    ...(sensitive ? { sensitive: true } : {}),
  };
}

function validateAction(value: unknown): WorkflowAction {
  const record = object(value, 'Workflow action');
  exactKeys(record, ['id', 'action', 'precondition', 'verified', 'safety'], 'Workflow action', ['precondition', 'safety']);
  if (record.verified !== true) throw new Error('Workflow actions must be verified.');
  const actionRecord = object(record.action, 'Workflow action payload');
  exactKeys(actionRecord, ['fieldId', 'action', 'value', 'reasoning'], 'Workflow action payload', ['reasoning']);
  if (typeof actionRecord.action !== 'string' || !workflowActionTypes.includes(actionRecord.action as ActionType)) throw new Error('Workflow action type is invalid.');
  const action: Action = {
    fieldId: text(actionRecord.fieldId, 'Workflow field id', 240, false),
    action: actionRecord.action as ActionType,
    value: text(actionRecord.value, 'Workflow action value', MAX_STRING, true),
    ...(optionalText(actionRecord.reasoning, 'Workflow reasoning', 500) === undefined ? {} : { reasoning: optionalText(actionRecord.reasoning, 'Workflow reasoning', 500) }),
  };
  if (isSensitiveText(action.value) && placeholders(action.value).length === 0) {
    throw new Error('Workflow actions cannot contain raw secrets.');
  }
  const precondition = record.precondition === undefined ? undefined : validateFingerprint(record.precondition);
  const safety = record.safety === undefined ? undefined : validateSafety(record.safety);
  assertSafeWorkflowAction(action, safety);
  return {
    id: identifier(record.id, 'Workflow action id'),
    action,
    ...(precondition ? { precondition } : {}),
    verified: true,
    ...(safety ? { safety } : {}),
  };
}

function validateFingerprint(value: unknown): PageFingerprint {
  const record = object(value, 'Page fingerprint');
  exactKeys(record, ['origin', 'path', 'title', 'heading', 'fieldIds', 'controlIds'], 'Page fingerprint', ['title', 'heading', 'fieldIds', 'controlIds']);
  const origin = text(record.origin, 'Page fingerprint origin', 2_048, false);
  let parsed: URL;
  try { parsed = new URL(origin); } catch { throw new Error('Page fingerprint origin is invalid.'); }
  if (!['http:', 'https:'].includes(parsed.protocol) || parsed.origin !== origin || parsed.username || parsed.password) throw new Error('Page fingerprint origin must be a credential-free http or https origin.');
  const path = text(record.path, 'Page fingerprint path', 1_024, false);
  if (!path.startsWith('/') || path.includes('?') || path.includes('#')) throw new Error('Page fingerprint paths cannot contain query strings or fragments.');
  const ids = (field: unknown, label: string) => field === undefined ? undefined : array(field, label, 30).map((entry) => text(entry, label, 240, false));
  return {
    origin,
    path,
    ...(optionalText(record.title, 'Page fingerprint title', 200) === undefined ? {} : { title: optionalText(record.title, 'Page fingerprint title', 200) }),
    ...(optionalText(record.heading, 'Page fingerprint heading', 200) === undefined ? {} : { heading: optionalText(record.heading, 'Page fingerprint heading', 200) }),
    ...(ids(record.fieldIds, 'Page fingerprint field ids') === undefined ? {} : { fieldIds: ids(record.fieldIds, 'Page fingerprint field ids') }),
    ...(ids(record.controlIds, 'Page fingerprint control ids') === undefined ? {} : { controlIds: ids(record.controlIds, 'Page fingerprint control ids') }),
  };
}

function validateSafety(value: unknown): WorkflowAction['safety'] {
  const record = object(value, 'Workflow action safety');
  exactKeys(record, ['targetRole', 'targetLabel'], 'Workflow action safety', ['targetRole', 'targetLabel']);
  const role = record.targetRole;
  if (role !== undefined && role !== 'button' && role !== 'link' && role !== 'tab') throw new Error('Workflow click target role is invalid.');
  const targetLabel = optionalText(record.targetLabel, 'Workflow click target label', 240);
  return { ...(role === undefined ? {} : { targetRole: role }), ...(targetLabel === undefined ? {} : { targetLabel }) };
}

function object(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label} must be an object.`);
  return value as Record<string, unknown>;
}

function exactKeys(record: Record<string, unknown>, allowed: string[], label: string, optional: string[] = []): void {
  for (const key of Object.keys(record)) if (!allowed.includes(key)) throw new Error(`${label} contains unsupported property "${key}".`);
  for (const key of allowed) if (!optional.includes(key) && !(key in record)) throw new Error(`${label} is missing "${key}".`);
}

function array(value: unknown, label: string, maximum: number): unknown[] {
  if (!Array.isArray(value) || value.length > maximum) throw new Error(`${label} must be an array with at most ${maximum} items.`);
  return value;
}

function text(value: unknown, label: string, maximum: number, allowEmpty: boolean): string {
  if (typeof value !== 'string' || value.length > maximum || (!allowEmpty && !value.trim())) throw new Error(`${label} is invalid.`);
  return value;
}

function optionalText(value: unknown, label: string, maximum: number): string | undefined {
  return value === undefined ? undefined : text(value, label, maximum, true);
}

function optionalBoolean(value: unknown, label: string): boolean | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== 'boolean') throw new Error(`${label} is invalid.`);
  return value;
}

function identifier(value: unknown, label: string): string {
  const candidate = text(value, label, 80, false);
  if (!/^[A-Za-z0-9_-]+$/.test(candidate)) throw new Error(`${label} is invalid.`);
  return candidate;
}

function variableKey(value: unknown): string {
  const candidate = identifier(value, 'Workflow variable key');
  if (!/^[A-Za-z][A-Za-z0-9_]*$/.test(candidate)) throw new Error('Workflow variable key is invalid.');
  return candidate;
}

function isoDate(value: unknown, label: string): string {
  const candidate = text(value, label, 40, false);
  if (Number.isNaN(Date.parse(candidate))) throw new Error(`${label} is invalid.`);
  return candidate;
}
