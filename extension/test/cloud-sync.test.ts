import assert from 'node:assert/strict';
import { AuthenticatedEdgeFunctionClient, ChromeLocalSyncCache, ContextCloudSync, VaultMetadataCloudSync, WorkflowCloudSync, type LocalSyncCache } from '../src/cloud';
import { LocalWorkflowStore } from '../src/workflows';
import type { LocalWorkflow, WorkflowStorageAdapter } from '../src/workflows';

const localValues: Record<string, unknown> = {};
const storage: WorkflowStorageAdapter = {
  get: async (key) => key ? { [key as string]: structuredClone(localValues[key as string]) } : structuredClone(localValues),
  set: async (items) => Object.assign(localValues, structuredClone(items)),
  remove: async (keys) => { for (const key of Array.isArray(keys) ? keys : [keys]) delete localValues[key]; },
};
const auth = { getAccessToken: async () => 'access-token' };
const requests: Array<{ name: string; headers: Headers; body: any }> = [];
const edge = new AuthenticatedEdgeFunctionClient({
  supabaseUrl: 'https://project.supabase.co', publishableKey: 'sb_publishable_test', auth,
  fetchImpl: async (input, init) => {
    const url = new URL(String(input));
    requests.push({ name: url.pathname.split('/').pop() ?? '', headers: new Headers(init?.headers), body: JSON.parse(String(init?.body)) });
    if (url.pathname.endsWith('workflow-import')) return Response.json({ ok: true, data: { workflow_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', version_id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', content_hash: 'a'.repeat(64), step_count: 1, duplicate: false } });
    if (url.pathname.endsWith('vault-upload-intent')) return Response.json({ ok: true, data: { document_id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', storage_bucket: 'vault-originals', storage_path: 'u/c', status: 'pending', duplicate: false, next_step: 'upload' } });
    if (url.pathname.endsWith('context-sync')) return Response.json({ ok: true, data: { operation: 'created', item: { id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', type: 'fact', category: 'general', key: 'name', value: 'Vasu', scope: 'persistent', documentId: null, updatedAt: '2026-08-27T00:00:00.000Z' } } });
    return Response.json({ ok: true, data: { synced: true } });
  },
});

const workflow: LocalWorkflow = {
  schemaVersion: 1, id: 'profile_update', name: 'Profile update', createdAt: '2026-08-24T00:00:00.000Z', updatedAt: '2026-08-24T00:00:00.000Z',
  variables: [], actions: [{ id: 'step_1', action: { fieldId: 'name', action: 'fill', value: 'Vasu' }, verified: true }],
};
const workflowResult = await new WorkflowCloudSync(edge, new LocalWorkflowStore(storage)).save(workflow);
assert.equal(workflowResult.state, 'synced');
assert.equal(requests[0].headers.get('authorization'), 'Bearer access-token');
assert.equal(requests[0].headers.get('apikey'), 'sb_publishable_test');
assert.equal(requests[0].body.definition.steps.length, 1);
assert.equal(requests[0].body.idempotency_key, requests[0].headers.get('idempotency-key'));
assert.equal((await new LocalWorkflowStore(storage).list()).length, 1, 'local workflow behavior remains first and intact');

const cache = new ChromeLocalSyncCache(storage);
const contextResult = await new ContextCloudSync(edge, cache).save({ type: 'fact', key: 'name', value: 'Vasu', scope: 'persistent' });
assert.equal(contextResult.state, 'synced');
assert.equal(contextResult.local.id, 'dddddddd-dddd-4ddd-8ddd-dddddddddddd');
assert.deepEqual(requests.find((request) => request.name === 'context-sync')?.body, { operation: 'upsert', item: { type: 'fact', key: 'name', value: 'Vasu', scope: 'persistent' } });
const vaultResult = await new VaultMetadataCloudSync(edge, cache).createUploadIntent({ filename: 'notes.md', mimeType: 'text/markdown', sizeBytes: 5, sha256: 'b'.repeat(64), extractionMethod: 'local' });
assert.equal(vaultResult.state, 'synced');
assert.equal(requests.find((request) => request.name === 'vault-upload-intent')?.headers.get('idempotency-key'), `vault-intent:${'b'.repeat(64)}`);

let offlineStored: unknown;
const offlineCache: LocalSyncCache<any> = { get: async () => [], set: async (_key, value) => { offlineStored = value; } };
const offlineEdge = new AuthenticatedEdgeFunctionClient({
  supabaseUrl: 'https://project.supabase.co', publishableKey: 'sb_publishable_test', auth,
  fetchImpl: async () => { throw new TypeError('offline'); },
});
const offlineResult = await new ContextCloudSync(offlineEdge, offlineCache).save({ type: 'fact', key: 'offline', value: 'kept locally', scope: 'persistent' });
assert.equal(offlineResult.state, 'offline');
assert.deepEqual(offlineStored, [{ type: 'fact', key: 'offline', value: 'kept locally', scope: 'persistent' }]);
console.log('All cloud sync checks passed.');
