import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { AUTH_STORAGE_KEYS, PkceAuthClient, type AuthStorage, type WebAuthFlowApi } from '../src/auth';

if (!globalThis.crypto) Object.assign(globalThis, { crypto: webcrypto });

class MemoryStorage implements AuthStorage {
  readonly values = new Map<string, unknown>();
  async get(key: string) { return { [key]: structuredClone(this.values.get(key)) }; }
  async set(items: Record<string, unknown>) { for (const [key, value] of Object.entries(items)) this.values.set(key, structuredClone(value)); }
  async remove(key: string) { this.values.delete(key); }
}

const storage = new MemoryStorage();
let authorizeUrl = '';
let exchangeCalls = 0;
const webAuthFlow: WebAuthFlowApi = {
  getRedirectURL: (path) => `https://extension-id.chromiumapp.org/${path ?? ''}`,
  launchWebAuthFlow: async ({ url }) => {
    authorizeUrl = url;
    const state = new URL(url).searchParams.get('state');
    return `https://extension-id.chromiumapp.org/supabase?code=one-time-code&state=${encodeURIComponent(state ?? '')}`;
  },
};
const fetchImpl: typeof fetch = async (input, init) => {
  assert.equal(String(input), 'https://project.supabase.co/auth/v1/token');
  assert.equal(new Headers(init?.headers).get('apikey'), 'sb_publishable_test');
  exchangeCalls += 1;
  const body = JSON.parse(String(init?.body));
  assert.equal(body.grant_type, 'pkce');
  assert.ok(body.code_verifier);
  return Response.json({ access_token: 'access', refresh_token: 'refresh', expires_in: 3600, token_type: 'bearer' });
};

const client = new PkceAuthClient({ supabaseUrl: 'https://project.supabase.co', publishableKey: 'sb_publishable_test' }, storage, webAuthFlow, fetchImpl, () => 1_700_000_000_000);
const session = await client.signInWithOAuth('google');
assert.equal(session.access_token, 'access');
assert.equal(exchangeCalls, 1, 'the one-time code is exchanged once');
assert.equal((await client.getSession())?.refresh_token, 'refresh');
assert.equal((await storage.get(AUTH_STORAGE_KEYS.PKCE_TRANSACTION_KEY))[AUTH_STORAGE_KEYS.PKCE_TRANSACTION_KEY], undefined);
const query = new URL(authorizeUrl).searchParams;
assert.equal(query.get('code_challenge_method'), 'S256');
assert.ok(query.get('code_challenge'));
assert.ok(query.get('state'));

const mismatchStorage = new MemoryStorage();
await mismatchStorage.set({ [AUTH_STORAGE_KEYS.PKCE_TRANSACTION_KEY]: {
  state: 'expected', codeVerifier: 'verifier', redirectUri: 'https://extension-id.chromiumapp.org/supabase', createdAt: 1_700_000_000_000,
} });
const mismatch = new PkceAuthClient({ supabaseUrl: 'https://project.supabase.co', publishableKey: 'sb_publishable_test' }, mismatchStorage, webAuthFlow, fetchImpl, () => 1_700_000_000_000);
await assert.rejects(() => mismatch.handleRedirect('https://extension-id.chromiumapp.org/supabase?code=code&state=wrong'), /could not be verified/i);
assert.equal((await mismatchStorage.get(AUTH_STORAGE_KEYS.PKCE_TRANSACTION_KEY))[AUTH_STORAGE_KEYS.PKCE_TRANSACTION_KEY], undefined);

assert.throws(
  () => new PkceAuthClient({ supabaseUrl: 'https://project.supabase.co', publishableKey: 'service_role_should_never_ship' }, storage, webAuthFlow),
  /publishable key/i,
);
console.log('All PKCE authentication checks passed.');
