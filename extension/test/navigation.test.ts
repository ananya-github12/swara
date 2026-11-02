import assert from 'node:assert/strict';

import {
  BrowserNavigationController,
  safeNavigationUrl,
  type BrowserNavigationApi,
  type BrowserTab,
  type NavigationSessionSnapshot,
  type NavigationSessionStore,
} from '../src/background/navigation';
import type { Action } from '../src/types';

const tabs = new Map<number, BrowserTab>([
  [1, { id: 1, url: 'https://start.example/', title: 'Start', status: 'complete' }],
  [99, { id: 99, url: 'https://unrelated.example/', title: 'Unrelated', status: 'complete' }],
]);
let nextTabId = 2;
const calls: string[] = [];
const stored = new Map<string, NavigationSessionSnapshot>();

const api: BrowserNavigationApi = {
  getTab: async (tabId) => {
    const tab = tabs.get(tabId);
    if (!tab) throw new Error(`No tab ${tabId}`);
    return { ...tab };
  },
  createTab: async ({ url, active }) => {
    calls.push(`create:${url}:${active}`);
    const tab = { id: nextTabId++, url, title: url, status: 'complete' };
    tabs.set(tab.id, tab);
    return { ...tab };
  },
  updateTab: async (tabId, options) => {
    calls.push(`update:${tabId}:${options.url ?? ''}:${options.active ?? false}`);
    const tab = tabs.get(tabId);
    if (!tab) throw new Error(`No tab ${tabId}`);
    if (options.url) tab.url = options.url;
    return { ...tab };
  },
  removeTab: async (tabId) => {
    calls.push(`remove:${tabId}`);
    if (!tabs.delete(tabId)) throw new Error(`No tab ${tabId}`);
  },
  goBack: async (tabId) => { calls.push(`back:${tabId}`); },
  goForward: async (tabId) => { calls.push(`forward:${tabId}`); },
  waitForComplete: async (tabId) => {
    calls.push(`wait:${tabId}`);
    return true;
  },
};

const store: NavigationSessionStore = {
  get: async (sessionId) => stored.get(sessionId),
  set: async (sessionId, snapshot) => { stored.set(sessionId, snapshot); },
  remove: async (sessionId) => { stored.delete(sessionId); },
};
const controller = new BrowserNavigationController(api, store);
const action = (actionType: Action['action'], value = ''): Action => ({
  fieldId: `browser:${actionType}`,
  action: actionType,
  value,
});

const opened = await controller.execute('run-a', 1, action('open_tab', 'https://example.com/path'));
assert.equal(opened.ok, true);
assert.equal(opened.verification?.tabId, 2);
assert.equal(opened.verification?.url, 'https://example.com/path');
assert.equal(opened.verification?.ready, true);
assert.deepEqual(stored.get('run-a'), { sourceTabId: 1, activeTabId: 2, createdTabIds: [2] });

// This simulates an MV3 worker restart: the allowlist must hydrate from
// storage.session and still reject tabs the run did not create.
const resumedController = new BrowserNavigationController(api, store);
const switched = await resumedController.execute('run-a', 1, action('switch_tab', '2'));
assert.equal(switched.ok, true);
assert.equal(switched.verification?.tabId, 2);

const arbitrarySwitch = await resumedController.execute('run-a', 1, action('switch_tab', '99'));
assert.equal(arbitrarySwitch.ok, false);
assert.match(arbitrarySwitch.error ?? '', /outside the current Swara run/i);

const closeSource = await resumedController.execute('run-a', 1, action('close_tab', '1'));
assert.equal(closeSource.ok, false);
assert.match(closeSource.error ?? '', /only close a tab opened/i);

const closeCreated = await resumedController.execute('run-a', 1, action('close_tab', '2'));
assert.equal(closeCreated.ok, true);
assert.equal(tabs.has(2), false);
assert.equal(closeCreated.verification?.tabId, 1);
assert.deepEqual(stored.get('run-a'), { sourceTabId: 1, activeTabId: 1, createdTabIds: [] });

const navigation = await resumedController.execute('run-a', 1, action('navigate', 'https://example.org/next'));
assert.equal(navigation.ok, true);
assert.equal(navigation.verification?.tabId, 1);
assert.equal(navigation.verification?.navigated, true);

const blockedProtocol = await resumedController.execute('run-a', 1, action('navigate', 'javascript:alert(1)'));
assert.equal(blockedProtocol.ok, false);
assert.match(blockedProtocol.error ?? '', /http and https/i);
assert.throws(() => safeNavigationUrl('data:text/html,nope'), /http and https/i);
assert.throws(() => safeNavigationUrl('https://user:pass@example.com'), /credential-free/i);

const secondRunCannotUseFirstTab = await resumedController.execute('run-b', 1, action('switch_tab', '2'));
assert.equal(secondRunCannotUseFirstTab.ok, false);

await resumedController.end('run-a');
assert.equal(stored.has('run-a'), false, 'ending a session removes its persisted allowlist');
const afterEndCannotReuseTabs = await new BrowserNavigationController(api, store).execute(
  'run-a',
  1,
  action('switch_tab', '99'),
);
assert.equal(afterEndCannotReuseTabs.ok, false);
assert.match(afterEndCannotReuseTabs.error ?? '', /outside the current Swara run/i);

assert.ok(calls.includes('create:https://example.com/path:true'));
assert.equal(calls.includes('remove:1'), false, 'the source tab must never be closed');

console.log('All browser-navigation checks passed.');
