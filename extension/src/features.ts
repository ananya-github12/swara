import type { AssistantCapability } from './types';

/**
 * New assistant behaviours are independently reversible. Existing form
 * extraction and execution do not depend on any of these switches.
 */
export const ASSISTANT_FEATURES = {
  readablePageText: true,
  contentEditableFill: true,
  openUrl: true,
  browserNavigation: true,
} as const satisfies Record<AssistantCapability, boolean>;

export function enabledAssistantCapabilities(): AssistantCapability[] {
  return (Object.keys(ASSISTANT_FEATURES) as AssistantCapability[]).filter(
    (capability) => ASSISTANT_FEATURES[capability],
  );
}
