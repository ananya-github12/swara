import type {
  SwaraBrowserActionMessage,
  SwaraBrowserActionResultMessage,
  SwaraMessage,
} from '../types';
import {
  BrowserNavigationController,
  type BrowserNavigationApi,
  type NavigationSessionSnapshot,
  type NavigationSessionStore,
} from './navigation';

const navigationApi: BrowserNavigationApi = {
  getTab: (tabId) => chrome.tabs.get(tabId),
  createTab: (options) => chrome.tabs.create(options),
  updateTab: (tabId, options) => chrome.tabs.update(tabId, options),
  removeTab: (tabId) => chrome.tabs.remove(tabId),
  goBack: (tabId) => chrome.tabs.goBack(tabId),
  goForward: (tabId) => chrome.tabs.goForward(tabId),
  waitForComplete: (tabId, timeoutMs) =>
    new Promise<boolean>((resolve) => {
      let settled = false;
      const finish = (ready: boolean) => {
        if (settled) return;
        settled = true;
        chrome.tabs.onUpdated.removeListener(onUpdated);
        clearTimeout(timeout);
        resolve(ready);
      };
      const onUpdated = (updatedTabId: number, change: chrome.tabs.TabChangeInfo) => {
        if (updatedTabId === tabId && change.status === 'complete') finish(true);
      };
      const timeout = setTimeout(() => finish(false), timeoutMs);
      chrome.tabs.onUpdated.addListener(onUpdated);
      void chrome.tabs.get(tabId).then((tab) => {
        if (tab.status === 'complete') finish(true);
      }).catch(() => finish(false));
    }),
};

const navigationSessionKey = (sessionId: string) => `swara.navigation.${sessionId}`;

function isNavigationSessionSnapshot(value: unknown): value is NavigationSessionSnapshot {
  if (!value || typeof value !== 'object') return false;
  const snapshot = value as Partial<NavigationSessionSnapshot>;
  return (
    Number.isSafeInteger(snapshot.sourceTabId) &&
    Number.isSafeInteger(snapshot.activeTabId) &&
    Array.isArray(snapshot.createdTabIds) &&
    snapshot.createdTabIds.every((tabId) => Number.isSafeInteger(tabId) && tabId > 0)
  );
}

// MV3 workers are short-lived. Persist only the tab allowlist needed to resume
// a run; it contains no page contents, credentials, Vault, or account data.
const navigationStore: NavigationSessionStore = {
  get: async (sessionId) => {
    const key = navigationSessionKey(sessionId);
    const record = await chrome.storage.session.get(key);
    const value: unknown = record[key];
    return isNavigationSessionSnapshot(value) ? value : undefined;
  },
  set: async (sessionId, session) => {
    await chrome.storage.session.set({ [navigationSessionKey(sessionId)]: session });
  },
  remove: async (sessionId) => {
    await chrome.storage.session.remove(navigationSessionKey(sessionId));
  },
};

const navigation = new BrowserNavigationController(navigationApi, navigationStore);

function isExtensionPage(sender: chrome.runtime.MessageSender): boolean {
  return Boolean(sender.url?.startsWith(chrome.runtime.getURL('')));
}

chrome.runtime.onInstalled.addListener(() => {
  void chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true });
});

chrome.runtime.onMessage.addListener(
  (message: SwaraMessage, sender, sendResponse) => {
    if (message.type === 'SWARA_BROWSER_SESSION_END') {
      if (!isExtensionPage(sender)) return;
      void navigation.end(message.sessionId).then(() => sendResponse());
      return true;
    }
    if (message.type !== 'SWARA_BROWSER_ACTION') return;
    if (!isExtensionPage(sender)) {
      sendResponse({
        type: 'SWARA_BROWSER_ACTION_RESULT',
        result: {
          fieldId: message.action.fieldId,
          ok: false,
          error: 'Refused: browser control is available only from Swara.',
        },
      } satisfies SwaraBrowserActionResultMessage);
      return;
    }

    void handleBrowserAction(message).then(sendResponse);
    return true;
  },
);

async function handleBrowserAction(
  message: SwaraBrowserActionMessage,
): Promise<SwaraBrowserActionResultMessage> {
  return {
    type: 'SWARA_BROWSER_ACTION_RESULT',
    result: await navigation.execute(message.sessionId, message.sourceTabId, message.action),
  };
}

chrome.action.onClicked.addListener((tab) => {
  if (tab.id !== undefined) {
    void chrome.sidePanel.open({ tabId: tab.id });
  }
});
