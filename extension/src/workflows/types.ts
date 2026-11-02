import type { Action, ActionResult, PageContext, PageControl } from '../types';

/** Export format version. Imports intentionally reject every other version. */
export const WORKFLOW_SCHEMA_VERSION = 1 as const;
export const MAX_WORKFLOW_BYTES = 256 * 1024;
export const MAX_WORKFLOW_ACTIONS = 50;
export const MAX_WORKFLOW_VARIABLES = 25;
export const MAX_STORED_WORKFLOWS = 25;

export type WorkflowVariable = {
  key: string;
  label: string;
  /** Never persisted for a sensitive variable. */
  defaultValue?: string;
  sensitive?: boolean;
};

/**
 * A deliberately small, non-content fingerprint. We do not persist readable
 * page text, cookies, form values, account identifiers, or query strings.
 */
export type PageFingerprint = {
  origin: string;
  path: string;
  title?: string;
  heading?: string;
  fieldIds?: string[];
  controlIds?: string[];
};

export type WorkflowActionSafety = {
  /** Clicks must carry an observed, non-submit control role. */
  targetRole?: Exclude<PageControl['role'], 'submit'>;
  targetLabel?: string;
};

export type WorkflowAction = {
  id: string;
  action: Action;
  /** Checked immediately before this one action is replayed. */
  precondition?: PageFingerprint;
  /** All stored actions have an observed successful result. */
  verified: true;
  safety?: WorkflowActionSafety;
};

export type LocalWorkflow = {
  schemaVersion: typeof WORKFLOW_SCHEMA_VERSION;
  id: string;
  name: string;
  createdAt: string;
  updatedAt: string;
  variables: WorkflowVariable[];
  actions: WorkflowAction[];
};

export type WorkflowRecordingInput = {
  action: Action;
  result: ActionResult;
  precondition?: PageFingerprint;
  /** Required for click actions so submit-like targets never enter a workflow. */
  target?: PageControl;
};

export type WorkflowValues = Readonly<Record<string, string>>;

export type ReplayStep = {
  workflowId: string;
  actionId: string;
  index: number;
  action: Action;
};

export type WorkflowStorageAdapter = {
  get: (key?: string | string[] | null) => Promise<Record<string, unknown>>;
  set: (items: Record<string, unknown>) => Promise<void>;
  remove: (keys: string | string[]) => Promise<void>;
};

export type WorkflowLibrary = {
  workflows: LocalWorkflow[];
  loading: boolean;
  error?: string;
  refresh: () => Promise<void>;
  save: (workflow: LocalWorkflow) => Promise<void>;
  remove: (workflowId: string) => Promise<void>;
  importJson: (serialized: string) => Promise<LocalWorkflow>;
  exportJson: (workflowId: string) => string;
};
