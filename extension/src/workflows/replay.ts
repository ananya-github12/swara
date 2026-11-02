import { executeRoutedActions, type ActionRoutingDependencies, type RoutedActionResult } from '../sidepanel/actionRouting';
import type { Action, PageContext } from '../types';
import { assertSafeWorkflowAction, fingerprintMatches, isBrowserUrlAction, substitutePlaceholders } from './security';
import { validateWorkflow } from './serialization';
import type { LocalWorkflow, ReplayStep, WorkflowValues } from './types';

export type PrepareReplayStepInput = {
  workflow: LocalWorkflow;
  index: number;
  page: PageContext;
  values: WorkflowValues;
  /** UI must pass true only after an explicit click or voice confirmation. */
  userInitiated: boolean;
};

/**
 * Preparing one step at a time forces the caller to provide a fresh page
 * observation before each action. This is intentionally not a scheduler or
 * autonomous background runner.
 */
export function prepareReplayStep(input: PrepareReplayStepInput): ReplayStep {
  const workflow = validateWorkflow(input.workflow);
  if (input.userInitiated !== true) throw new Error('Workflows run only after an explicit user action.');
  if (!Number.isInteger(input.index) || input.index < 0 || input.index >= workflow.actions.length) throw new Error('Workflow step does not exist.');
  const step = workflow.actions[input.index];
  if (step.precondition && !fingerprintMatches(step.precondition, input.page)) {
    throw new Error('This page no longer matches the recorded workflow step.');
  }
  const action: Action = {
    ...step.action,
    value: substitutePlaceholders(step.action.value, input.values, workflow.variables),
  };
  // URL validation runs only after values have been resolved, so a placeholder
  // can never smuggle javascript:, file:, credentials, or a relative URL.
  assertSafeWorkflowAction(action, step.safety);
  if (isBrowserUrlAction(action)) {
    // assertSafeWorkflowAction invokes the shared navigation validator. Kept
    // here as an explicit policy boundary for future action additions.
  }
  return { workflowId: workflow.id, actionId: step.id, index: input.index, action };
}

export type ExecuteReplayStepInput = PrepareReplayStepInput & {
  routing: ActionRoutingDependencies;
};

/**
 * The only executing replay helper routes through the existing safety-aware
 * action router. It cannot bypass content-script or navigation guardrails.
 */
export async function executeReplayStep(input: ExecuteReplayStepInput): Promise<RoutedActionResult> {
  const step = prepareReplayStep(input);
  return executeRoutedActions([step.action], input.routing);
}
