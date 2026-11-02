import type { SwaraOverlayStatusMessage } from '../types';
import { getActionOverlay } from './actionOverlay';
import { resolveActionTarget } from './execute';

/**
 * Renders browser-action progress in the current tab. This is deliberately a
 * display-only bridge: it resolves an existing extracted target when supplied
 * but does not click, focus, fill, or otherwise interact with the page.
 */
export function showOverlayStatus(message: SwaraOverlayStatusMessage): void {
  const overlay = getActionOverlay();
  const target = message.fieldId
    ? resolveActionTarget(message.fieldId)
    : undefined;
  overlay.show({
    target,
    status: message.status,
    step: message.step,
    title: message.title,
    reason: message.reason,
  });
  if (message.status === 'success' || message.status === 'failure') {
    overlay.hideAfter();
  }
}
