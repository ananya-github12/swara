import assert from 'node:assert/strict';

import type { PageContext } from '../src/types';
import {
  LocalWorkflowStore,
  WorkflowRecorder,
  createPageFingerprint,
  executeReplayStep,
  exportWorkflow,
  importWorkflow,
  prepareReplayStep,
  type WorkflowStorageAdapter,
} from '../src/workflows';

const page: PageContext = {
  url: 'https://example.com/profile?private=never-recorded',
  title: 'Profile',
  heading: 'Edit profile',
  fields: [{ fieldId: 'display_name', label: 'Display name', question: 'Display name', type: 'text', required: false, options: [] }],
  controls: [{ controlId: 'next', label: 'Next', role: 'button', disabled: false }],
};

const recorder = new WorkflowRecorder('profile_update', 'Update profile', '2026-08-24T00:00:00.000Z');
const fingerprint = createPageFingerprint(page);
assert.equal(fingerprint.path, '/profile');
assert.equal(fingerprint.origin, 'https://example.com');

recorder.record({
  action: { fieldId: 'display_name', action: 'fill', value: 'Vasu' },
  result: { fieldId: 'display_name', ok: true },
  precondition: fingerprint,
});
recorder.record({
  action: { fieldId: 'next', action: 'click', value: '' },
  result: { fieldId: 'next', ok: true },
  target: page.controls[0],
});

assert.throws(() => recorder.record({
  action: { fieldId: 'submit', action: 'click', value: '' },
  result: { fieldId: 'submit', ok: true },
  target: { controlId: 'submit', label: 'Submit application', role: 'submit', disabled: false },
}), /non-submit/i);
assert.throws(() => recorder.record({
  action: { fieldId: 'display_name', action: 'fill', value: 'nope' },
  result: { fieldId: 'display_name', ok: false },
}), /verified successful/i);

// The literal secret never reaches the finished workflow or JSON export.
recorder.record({
  action: { fieldId: 'note', action: 'fill', value: 'sk_abcdefghijklmnopqrstuvwxyz' },
  result: { fieldId: 'note', ok: true },
});
const workflow = recorder.finish();
assert.equal(workflow.actions[2].action.value, '{{sensitive_value_1}}');
assert.equal(workflow.variables[0].defaultValue, undefined);
assert.match(exportWorkflow(workflow), /sensitive_value_1/);
assert.doesNotMatch(exportWorkflow(workflow), /sk_abcdefghijklmnopqrstuvwxyz/);

const imported = importWorkflow(exportWorkflow(workflow));
assert.deepEqual(imported, workflow);
assert.throws(() => importWorkflow(JSON.stringify({ ...workflow, schedule: '* * * * *' })), /unsupported property/i);

// Replays require an explicit user trigger and a fresh matching page check.
assert.throws(() => prepareReplayStep({ workflow, index: 0, page, values: {}, userInitiated: false }), /explicit user action/i);
const prepared = prepareReplayStep({ workflow, index: 0, page, values: {}, userInitiated: true });
assert.equal(prepared.action.value, 'Vasu');
assert.throws(() => prepareReplayStep({
  workflow,
  index: 0,
  page: { ...page, url: 'https://example.com/other' },
  values: {},
  userInitiated: true,
}), /no longer matches/i);

const maliciousNavigation = importWorkflow(JSON.stringify({
  ...workflow,
  id: 'navigation',
  actions: [{
    id: 'step_1', verified: true,
    action: { fieldId: 'browser:new', action: 'open_tab', value: '{{destination}}' },
  }],
  variables: [{ key: 'destination', label: 'Destination' }],
}));
assert.throws(() => prepareReplayStep({
  workflow: maliciousNavigation,
  index: 0,
  page,
  values: { destination: 'javascript:alert(1)' },
  userInitiated: true,
}), /http and https/i);

let saved: Record<string, unknown> = {};
const adapter: WorkflowStorageAdapter = {
  get: async () => structuredClone(saved),
  set: async (items) => { saved = { ...saved, ...structuredClone(items) }; },
  remove: async (keys) => { for (const key of (Array.isArray(keys) ? keys : [keys])) delete saved[key]; },
};
const store = new LocalWorkflowStore(adapter);
await store.save(workflow);
assert.equal((await store.list()).length, 1);
await store.remove(workflow.id);
assert.equal((await store.list()).length, 0);

const routed = await executeReplayStep({
  workflow,
  index: 0,
  page,
  values: {},
  userInitiated: true,
  routing: {
    initialTabId: 10,
    allowBrowserNavigation: true,
    executeDomActions: async (tabId, actions) => {
      assert.equal(tabId, 10);
      assert.equal(actions[0].value, 'Vasu');
      return actions.map((action) => ({ fieldId: action.fieldId, ok: true }));
    },
    executeBrowserAction: async () => { throw new Error('not expected'); },
  },
});
assert.equal(routed.results[0].ok, true);

console.log('All local workflow checks passed.');
