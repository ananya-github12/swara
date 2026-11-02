import type { SwaraMessage } from '../types';
import { destroyActionOverlay } from './actionOverlay';
import { executeActions } from './execute';
import { extractPage } from './extract';
import { showOverlayStatus } from './overlayStatus';

// Needed for back/forward cache restores, where Chrome can keep a content
// script alive after its document has stopped being the visible page.
window.addEventListener('pagehide', destroyActionOverlay);

chrome.runtime.onMessage.addListener(
  (message: SwaraMessage, _sender, sendResponse) => {
    if (message.type === 'SWARA_OVERLAY_STATUS') {
      showOverlayStatus(message);
      return;
    }

    if (message.type === 'SWARA_PING') {
      sendResponse({
        type: 'SWARA_PONG',
        url: location.href,
        title: document.title,
      });
      return;
    }

    if (message.type === 'SWARA_EXTRACT') {
      sendResponse({
        type: 'SWARA_EXTRACT_RESULT',
        page: extractPage(),
      });
      return;
    }

    if (message.type === 'SWARA_EXECUTE') {
      sendResponse({
        type: 'SWARA_EXECUTE_RESULT',
        results: executeActions(message.actions),
      });
    }
  },
);
