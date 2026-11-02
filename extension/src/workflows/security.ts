import { safeNavigationUrl } from '../background/navigation';
import type { Action, ActionType, PageContext, PageControl } from '../types';
import type { PageFingerprint, WorkflowAction, WorkflowVariable } from './types';

export const WORKFLOW_PLACEHOLDER = /\{\{([A-Za-z][A-Za-z0-9_]*)\}\}/g;

const BLOCKED_LABEL = /\b(submit|send|pay|purchase|delete|remove|cancel|apply|confirm)\b/i;
const SENSITIVE_FIELD = /password|passcode|otp|token|secret|api[ _-]?key|cvv|card[ _-]?number|social[ _-]?security|ssn/i;
const SECRET_VALUE = /(?:^|\s)(?:sk|pk|api)[_-][A-Za-z0-9_-]{12,}|-----BEGIN(?: [A-Z]+)? PRIVATE KEY-----|\b\d{13,19}\b/i;

export const workflowActionTypes: readonly ActionType[] = [
  'fill', 'select', 'check', 'uncheck', 'clear', 'click', 'scroll_to',
  'open_url', 'navigate', 'open_tab', 'switch_tab', 'close_tab',
  'go_back', 'go_forward', 'wait_for_page',
] as const;

export function isSensitiveText(value: string): boolean {
  return SENSITIVE_FIELD.test(value) || SECRET_VALUE.test(value);
}

export function isBlockedControl(control: Pick<PageControl, 'role' | 'label'>): boolean {
  return control.role === 'submit' || BLOCKED_LABEL.test(control.label);
}

export function isBrowserUrlAction(action: Action): boolean {
  return action.action === 'open_url' || action.action === 'navigate' || action.action === 'open_tab';
}

export function assertSafeWorkflowAction(action: Action, safety?: WorkflowAction['safety']): void {
  if (!workflowActionTypes.includes(action.action)) throw new Error('Unsupported workflow action.');
  if (isSensitiveText(action.fieldId) || isSensitiveText(action.reasoning ?? '')) {
    throw new Error('Sensitive targets cannot be stored in a workflow.');
  }
  if (action.action === 'click') {
    if (
      !safety?.targetRole
      || BLOCKED_LABEL.test(safety.targetLabel ?? '')
      || BLOCKED_LABEL.test(action.fieldId)
      || BLOCKED_LABEL.test(action.reasoning ?? '')
    ) {
      throw new Error('Workflows can only replay observed non-submit clicks.');
    }
  }
  if (isBrowserUrlAction(action) && !hasPlaceholder(action.value)) safeNavigationUrl(action.value);
}

export function createPageFingerprint(page: PageContext): PageFingerprint {
  const url = safeNavigationUrl(page.url);
  const parsed = new URL(url);
  return {
    origin: parsed.origin,
    path: parsed.pathname,
    title: cleanFingerprintText(page.title),
    heading: cleanFingerprintText(page.heading),
    fieldIds: page.fields.slice(0, 30).map((field) => field.fieldId),
    controlIds: page.controls.slice(0, 30).map((control) => control.controlId),
  };
}

export function fingerprintMatches(fingerprint: PageFingerprint, page: PageContext): boolean {
  let actual: PageFingerprint;
  try {
    actual = createPageFingerprint(page);
  } catch {
    return false;
  }
  if (fingerprint.origin !== actual.origin || fingerprint.path !== actual.path) return false;
  if (fingerprint.title && fingerprint.title !== actual.title) return false;
  if (fingerprint.heading && fingerprint.heading !== actual.heading) return false;
  if (fingerprint.fieldIds?.some((id) => !actual.fieldIds?.includes(id))) return false;
  if (fingerprint.controlIds?.some((id) => !actual.controlIds?.includes(id))) return false;
  return true;
}

export function placeholders(value: string): string[] {
  return [...value.matchAll(WORKFLOW_PLACEHOLDER)].map((match) => match[1]);
}

export function hasPlaceholder(value: string): boolean {
  return placeholders(value).length > 0;
}

export function substitutePlaceholders(value: string, values: Readonly<Record<string, string>>, variables: WorkflowVariable[]): string {
  const declared = new Set(variables.map((variable) => variable.key));
  return value.replace(WORKFLOW_PLACEHOLDER, (_whole, key: string) => {
    if (!declared.has(key)) throw new Error(`Workflow variable "${key}" is not declared.`);
    const variable = variables.find((candidate) => candidate.key === key);
    const replacement = values[key] ?? variable?.defaultValue;
    if (replacement === undefined) throw new Error(`Workflow variable "${key}" needs a value.`);
    if (replacement.length > 4_000) throw new Error(`Workflow variable "${key}" is too long.`);
    return replacement;
  });
}

function cleanFingerprintText(value: string | undefined): string | undefined {
  if (!value) return undefined;
  const normalized = value.trim().replace(/\s+/g, ' ');
  return normalized.slice(0, 200) || undefined;
}
