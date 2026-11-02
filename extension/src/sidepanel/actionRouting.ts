import { safeNavigationUrl } from '../background/navigation';
import type { Action, ActionResult } from '../types';

export { safeNavigationUrl };

const browserActions = new Set<Action['action']>([
  'open_url',
  'navigate',
  'open_tab',
  'switch_tab',
  'close_tab',
  'go_back',
  'go_forward',
  'wait_for_page',
]);

export type ActionRoutingDependencies = {
  /** The tab selected when this Swara run started. */
  initialTabId: number;
  /** DOM actions run only against the controlled tab supplied here. */
  executeDomActions: (tabId: number, actions: Action[]) => Promise<ActionResult[]>;
  /** The service worker owns the allowlist and performs browser actions. */
  executeBrowserAction: (action: Action) => Promise<ActionResult>;
  allowBrowserNavigation: boolean;
  /** Cooperative boundary checked before each action in a batch. */
  shouldContinue?: () => boolean;
  /** Stable reason attached to actions which were intentionally not started. */
  interruptionReason?: () => string;
};

export type RoutedActionResult = {
  results: ActionResult[];
  /** The tab that must be extracted before the next agent observation. */
  activeTabId: number;
};

function requiresUrlValidation(action: Action): boolean {
  return action.action === 'open_url' || action.action === 'open_tab' || action.action === 'navigate';
}

/**
 * Preserve action order across page and browser work. Browser operations are
 * never sent to content scripts, and every later DOM action follows the tab
 * verified by the service worker rather than whichever tab happens to be
 * active in Chrome.
 */
export async function executeRoutedActions(
  actions: Action[],
  dependencies: ActionRoutingDependencies,
): Promise<RoutedActionResult> {
  const results = new Array<ActionResult>(actions.length);
  let activeTabId = dependencies.initialTabId;

  for (const [index, action] of actions.entries()) {
    if (dependencies.shouldContinue?.() === false) {
      results[index] = {
        fieldId: action.fieldId,
        ok: false,
        error: dependencies.interruptionReason?.() ?? 'Stopped before this action started.',
      };
      continue;
    }

    if (!browserActions.has(action.action)) {
      try {
        // One DOM action per await creates a real pause/cancel/skip boundary.
        // The page executor itself remains synchronous, so an action which has
        // already started is allowed to finish and be reported honestly.
        const [result] = await dependencies.executeDomActions(activeTabId, [action]);
        results[index] = result ?? {
          fieldId: action.fieldId,
          ok: false,
          error: 'The page did not return an action result.',
        };
      } catch (error) {
        results[index] = {
          fieldId: action.fieldId,
          ok: false,
          error: error instanceof Error ? error.message : 'Could not change this page.',
        };
      }
      continue;
    }

    try {
      if (!dependencies.allowBrowserNavigation) {
        throw new Error('Browser navigation is disabled for this page session.');
      }
      // Fail locally before asking Chrome, providing a stable error for plans
      // which accidentally propose javascript:, data:, file:, or credentials.
      if (requiresUrlValidation(action)) safeNavigationUrl(action.value);
      const result = await dependencies.executeBrowserAction(action);
      results[index] = result;
      if (result.ok && result.verification?.tabId !== undefined) {
        activeTabId = result.verification.tabId;
      }
    } catch (error) {
      results[index] = {
        fieldId: action.fieldId,
        ok: false,
        error: error instanceof Error ? error.message : 'Could not navigate the browser.',
      };
    }
  }
  return { results, activeTabId };
}
