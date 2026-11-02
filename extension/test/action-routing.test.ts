import assert from 'node:assert/strict';

import type { Action } from '../src/types';
import { executeRoutedActions, safeNavigationUrl } from '../src/sidepanel/actionRouting';

const domCalls: Array<{ tabId: number; actions: Action[] }> = [];
const browserCalls: Action[] = [];
const actions: Action[] = [
  { fieldId: 'full_name', action: 'fill', value: 'Vasu' },
  { fieldId: 'browser:new', action: 'open_tab', value: 'https://example.com/research?q=swara' },
  { fieldId: 'about', action: 'fill', value: 'Builder' },
  { fieldId: 'browser:back', action: 'go_back', value: '' },
  { fieldId: 'browser:bad', action: 'navigate', value: 'javascript:alert(1)' },
];

const routed = await executeRoutedActions(actions, {
  initialTabId: 10,
  allowBrowserNavigation: true,
  executeDomActions: async (tabId, batch) => {
    domCalls.push({ tabId, actions: batch });
    return batch.map((action) => ({ fieldId: action.fieldId, ok: true }));
  },
  executeBrowserAction: async (action) => {
    browserCalls.push(action);
    if (action.action === 'open_tab') {
      return { fieldId: action.fieldId, ok: true, verification: { tabId: 20, url: action.value, ready: true } };
    }
    return { fieldId: action.fieldId, ok: true, verification: { tabId: 20, url: 'https://example.com/research', ready: true } };
  },
});

assert.deepEqual(domCalls.map((call) => call.actions.map((action) => action.fieldId)), [
  ['full_name'],
  ['about'],
]);
assert.deepEqual(domCalls.map((call) => call.tabId), [10, 20], 'DOM must follow the verified target tab');
assert.deepEqual(browserCalls.map((action) => action.action), ['open_tab', 'go_back']);
assert.deepEqual(routed.results.map((result) => result.ok), [true, true, true, true, false]);
assert.equal(routed.activeTabId, 20);
assert.match(routed.results[4].error ?? '', /http and https/i);
assert.throws(() => safeNavigationUrl('https://user:secret@example.com'), /credential-free/i);
assert.throws(() => safeNavigationUrl('/relative'), /complete http or https/i);

// The side panel feeds the previous batch's resolved tab back into the next
// batch. This prevents an open_tab followed by a DOM-only batch from silently
// returning to the original source tab.
let resumedDomTab: number | undefined;
const resumed = await executeRoutedActions(
  [{ fieldId: 'next_page_field', action: 'fill', value: 'still on the new tab' }],
  {
    initialTabId: routed.activeTabId,
    allowBrowserNavigation: true,
    executeDomActions: async (tabId, batch) => {
      resumedDomTab = tabId;
      return batch.map((action) => ({ fieldId: action.fieldId, ok: true }));
    },
    executeBrowserAction: async () => {
      throw new Error('must not be called');
    },
  },
);
assert.equal(resumedDomTab, 20);
assert.equal(resumed.activeTabId, 20);

const isolated = await executeRoutedActions(
  [
    { fieldId: 'name', action: 'fill', value: 'Vasu' },
    { fieldId: 'browser:new', action: 'open_url', value: 'https://example.com' },
  ],
  {
    initialTabId: 10,
    allowBrowserNavigation: true,
    executeDomActions: async () => { throw new Error('content script unavailable'); },
    executeBrowserAction: async (action) => ({
      fieldId: action.fieldId,
      ok: true,
      verification: { tabId: 11, ready: true },
    }),
  },
);
assert.equal(isolated.results[0].ok, false);
assert.equal(isolated.results[1].ok, true, 'DOM failure must not abort navigation');
assert.equal(isolated.activeTabId, 11);

const disabled = await executeRoutedActions(
  [{ fieldId: 'browser:new', action: 'open_tab', value: 'https://example.com' }],
  {
    initialTabId: 10,
    allowBrowserNavigation: false,
    executeDomActions: async () => [],
    executeBrowserAction: async () => { throw new Error('must not be called'); },
  },
);
assert.equal(disabled.results[0].ok, false);
assert.match(disabled.results[0].error ?? '', /disabled/i);

let allowed = true;
const cooperativelyStopped = await executeRoutedActions(
  [
    { fieldId: 'first', action: 'fill', value: 'one' },
    { fieldId: 'second', action: 'fill', value: 'two' },
  ],
  {
    initialTabId: 10,
    allowBrowserNavigation: true,
    shouldContinue: () => allowed,
    interruptionReason: () => 'Paused before this action started.',
    executeDomActions: async (_tabId, batch) => {
      allowed = false;
      return batch.map((action) => ({ fieldId: action.fieldId, ok: true }));
    },
    executeBrowserAction: async () => { throw new Error('must not be called'); },
  },
);
assert.equal(cooperativelyStopped.results[0].ok, true);
assert.equal(cooperativelyStopped.results[1].ok, false);
assert.match(cooperativelyStopped.results[1].error ?? '', /paused/i);

console.log('All action-routing checks passed.');
