import type { Action } from '../types';
import { assertSafeWorkflowAction, isSensitiveText, placeholders } from './security';
import {
  MAX_WORKFLOW_ACTIONS,
  MAX_WORKFLOW_VARIABLES,
  WORKFLOW_SCHEMA_VERSION,
  type LocalWorkflow,
  type WorkflowAction,
  type WorkflowRecordingInput,
  type WorkflowVariable,
} from './types';

const now = () => new Date().toISOString();

export function createWorkflowDraft(id: string, name: string, timestamp = now()): LocalWorkflow {
  return {
    schemaVersion: WORKFLOW_SCHEMA_VERSION,
    id: assertId(id, 'workflow id'),
    name: assertName(name),
    createdAt: timestamp,
    updatedAt: timestamp,
    variables: [],
    actions: [],
  };
}

/**
 * An in-memory recorder. It accepts actions only after their existing executor
 * returned ok, which prevents a flaky or unverified action becoming replayable.
 */
export class WorkflowRecorder {
  private draft: LocalWorkflow;

  constructor(id: string, name: string, timestamp?: string) {
    this.draft = createWorkflowDraft(id, name, timestamp);
  }

  record(input: WorkflowRecordingInput): WorkflowAction {
    if (!input.result.ok) throw new Error('Only verified successful actions can be recorded.');
    if (this.draft.actions.length >= MAX_WORKFLOW_ACTIONS) throw new Error(`A workflow can contain at most ${MAX_WORKFLOW_ACTIONS} actions.`);

    const safety = input.target
      ? { targetRole: input.target.role === 'submit' ? undefined : input.target.role, targetLabel: input.target.label }
      : undefined;
    assertSafeWorkflowAction(input.action, safety);

    const redacted = this.redactAction(input.action);
    const recorded: WorkflowAction = {
      id: `step_${this.draft.actions.length + 1}`,
      action: redacted,
      ...(input.precondition ? { precondition: input.precondition } : {}),
      verified: true,
      ...(safety ? { safety } : {}),
    };
    this.draft.actions.push(recorded);
    this.draft.updatedAt = now();
    return structuredClone(recorded);
  }

  addVariable(variable: WorkflowVariable): void {
    if (this.draft.variables.length >= MAX_WORKFLOW_VARIABLES) throw new Error(`A workflow can contain at most ${MAX_WORKFLOW_VARIABLES} variables.`);
    if (!/^[A-Za-z][A-Za-z0-9_]*$/.test(variable.key)) throw new Error('Variable names must start with a letter and use letters, numbers, or underscores.');
    if (this.draft.variables.some((candidate) => candidate.key === variable.key)) throw new Error('Variable names must be unique.');
    if (!variable.label.trim() || variable.label.length > 120) throw new Error('Variable labels must be between 1 and 120 characters.');
    if (variable.sensitive && variable.defaultValue !== undefined) throw new Error('Sensitive workflow variables cannot have saved default values.');
    this.draft.variables.push({ ...variable, label: variable.label.trim() });
    this.draft.updatedAt = now();
  }

  /** Replaces exact non-secret values in recorded actions with a declared placeholder. */
  replaceValueWithVariable(value: string, variable: WorkflowVariable): void {
    if (!value || isSensitiveText(value)) throw new Error('Use a sensitive variable without storing the original secret.');
    if (!this.draft.variables.some((candidate) => candidate.key === variable.key)) this.addVariable(variable);
    const replacement = `{{${variable.key}}}`;
    let replacements = 0;
    this.draft.actions = this.draft.actions.map((step) => {
      if (!step.action.value.includes(value)) return step;
      replacements += 1;
      return { ...step, action: { ...step.action, value: step.action.value.split(value).join(replacement) } };
    });
    if (!replacements) throw new Error('That value does not occur in this workflow.');
    this.draft.updatedAt = now();
  }

  finish(): LocalWorkflow {
    return structuredClone(this.draft);
  }

  private redactAction(action: Action): Action {
    if (!isSensitiveText(action.value)) return { ...action };
    const key = this.nextSensitiveKey();
    this.addVariable({ key, label: 'Sensitive value', sensitive: true });
    return { ...action, value: `{{${key}}}` };
  }

  private nextSensitiveKey(): string {
    let index = 1;
    while (this.draft.variables.some((variable) => variable.key === `sensitive_value_${index}`)) index += 1;
    return `sensitive_value_${index}`;
  }
}

export function referencedVariables(action: Action): string[] {
  return placeholders(action.value);
}

function assertId(value: string, label: string): string {
  if (!/^[A-Za-z0-9_-]{1,80}$/.test(value)) throw new Error(`Invalid ${label}.`);
  return value;
}

function assertName(value: string): string {
  const name = value.trim();
  if (!name || name.length > 120) throw new Error('Workflow names must be between 1 and 120 characters.');
  return name;
}
