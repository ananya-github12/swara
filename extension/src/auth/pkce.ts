const PKCE_TRANSACTION_KEY = 'swara.auth.pkce.transaction.v1';
const SESSION_KEY = 'swara.auth.session.v1';
const REFRESH_SKEW_SECONDS = 60;

export type AuthStorage = {
  get: (key: string) => Promise<Record<string, unknown>>;
  set: (items: Record<string, unknown>) => Promise<void>;
  remove: (key: string) => Promise<void>;
};

export type WebAuthFlowApi = {
  getRedirectURL: (path?: string) => string;
  launchWebAuthFlow: (details: { url: string; interactive: boolean }) => Promise<string>;
};

export type PkceAuthConfig = {
  supabaseUrl: string;
  publishableKey: string;
  redirectPath?: string;
};

export type AuthSession = {
  access_token: string;
  refresh_token: string;
  expires_in: number;
  expires_at: number;
  token_type: string;
};

export type AuthTokenProvider = {
  getAccessToken: (forceRefresh?: boolean) => Promise<string | null>;
};

type PkceTransaction = {
  state: string;
  codeVerifier: string;
  redirectUri: string;
  createdAt: number;
};

export class AuthError extends Error {
  readonly code: 'configuration' | 'state' | 'exchange' | 'refresh' | 'unauthenticated' | 'network';

  constructor(code: AuthError['code'], message: string) {
    super(message);
    this.name = 'AuthError';
    this.code = code;
  }
}

export class ChromeSessionAuthStorage implements AuthStorage {
  async get(key: string): Promise<Record<string, unknown>> {
    return chrome.storage.session.get(key) as Promise<Record<string, unknown>>;
  }

  async set(items: Record<string, unknown>): Promise<void> {
    await chrome.storage.session.set(items);
  }

  async remove(key: string): Promise<void> {
    await chrome.storage.session.remove(key);
  }
}

export class PkceAuthClient implements AuthTokenProvider {
  private redirectExchange?: Promise<AuthSession>;
  private refreshInFlight?: Promise<AuthSession | null>;

  constructor(
    private readonly config: PkceAuthConfig,
    private readonly storage: AuthStorage,
    private readonly webAuthFlow: WebAuthFlowApi,
    private readonly fetchImpl: typeof fetch = fetch,
    private readonly now: () => number = () => Date.now(),
  ) {
    validateConfig(config);
  }

  async signInWithOAuth(provider: string): Promise<AuthSession> {
    const normalizedProvider = validateProvider(provider);
    const redirectUri = this.webAuthFlow.getRedirectURL(this.config.redirectPath ?? 'supabase');
    const state = randomBase64Url(32);
    const codeVerifier = randomBase64Url(48);
    const codeChallenge = await sha256Base64Url(codeVerifier);
    const transaction: PkceTransaction = {
      state,
      codeVerifier,
      redirectUri,
      createdAt: this.now(),
    };

    await this.storage.set({ [PKCE_TRANSACTION_KEY]: transaction });
    const authorizeUrl = new URL(`${trimTrailingSlash(this.config.supabaseUrl)}/auth/v1/authorize`);
    authorizeUrl.searchParams.set('provider', normalizedProvider);
    authorizeUrl.searchParams.set('redirect_to', redirectUri);
    authorizeUrl.searchParams.set('state', state);
    authorizeUrl.searchParams.set('code_challenge', codeChallenge);
    authorizeUrl.searchParams.set('code_challenge_method', 'S256');

    try {
      const callbackUrl = await this.webAuthFlow.launchWebAuthFlow({
        url: authorizeUrl.toString(),
        interactive: true,
      });
      return await this.handleRedirect(callbackUrl);
    } catch (error) {
      if (!(error instanceof AuthError)) await this.storage.remove(PKCE_TRANSACTION_KEY);
      throw error;
    }
  }

  async handleRedirect(callbackUrl: string): Promise<AuthSession> {
    if (this.redirectExchange) return this.redirectExchange;
    this.redirectExchange = this.exchangeRedirect(callbackUrl);
    try {
      return await this.redirectExchange;
    } finally {
      this.redirectExchange = undefined;
    }
  }

  async getSession(): Promise<AuthSession | null> {
    const stored = await this.storage.get(SESSION_KEY);
    return parseSession(stored[SESSION_KEY]);
  }

  async getAccessToken(forceRefresh = false): Promise<string | null> {
    const session = await this.getSession();
    if (!session) return null;
    if (!forceRefresh && session.expires_at - Math.floor(this.now() / 1000) > REFRESH_SKEW_SECONDS) {
      return session.access_token;
    }
    const refreshed = await this.refreshSession(session);
    return refreshed?.access_token ?? null;
  }

  async refreshSession(existing?: AuthSession): Promise<AuthSession | null> {
    if (this.refreshInFlight) return this.refreshInFlight;
    this.refreshInFlight = this.performRefresh(existing).finally(() => {
      this.refreshInFlight = undefined;
    });
    return this.refreshInFlight;
  }

  async signOut(): Promise<void> {
    const session = await this.getSession();
    try {
      if (session) {
        await this.fetchImpl(`${trimTrailingSlash(this.config.supabaseUrl)}/auth/v1/logout`, {
          method: 'POST',
          headers: this.authHeaders(session.access_token),
        });
      }
    } finally {
      await this.storage.remove(SESSION_KEY);
      await this.storage.remove(PKCE_TRANSACTION_KEY);
    }
  }

  private async exchangeRedirect(callbackUrl: string): Promise<AuthSession> {
    const transaction = await this.consumeTransaction();
    const parsed = parseCallbackUrl(callbackUrl);
    if (parsed.state !== transaction.state) {
      throw new AuthError('state', 'The authentication response could not be verified.');
    }
    if (parsed.error) throw new AuthError('exchange', 'Authentication was not completed.');
    if (!parsed.code) throw new AuthError('exchange', 'The authentication response did not contain a code.');
    const response = await this.authRequest('/auth/v1/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...this.authHeaders() },
      body: JSON.stringify({
        grant_type: 'pkce',
        code: parsed.code,
        code_verifier: transaction.codeVerifier,
        redirect_uri: transaction.redirectUri,
      }),
    });
    const session = parseSession(response, Math.floor(this.now() / 1000));
    if (!session) throw new AuthError('exchange', 'Authentication returned an invalid session.');
    await this.storage.set({ [SESSION_KEY]: session });
    return session;
  }

  private async performRefresh(existing?: AuthSession): Promise<AuthSession | null> {
    const session = existing ?? await this.getSession();
    if (!session) return null;
    const response = await this.fetchImpl(`${trimTrailingSlash(this.config.supabaseUrl)}/auth/v1/token`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...this.authHeaders() },
      body: JSON.stringify({ grant_type: 'refresh_token', refresh_token: session.refresh_token }),
    }).catch((error) => {
      throw new AuthError(error instanceof TypeError ? 'network' : 'refresh', 'Session refresh failed.');
    });
    if (!response.ok) {
      if (response.status === 400 || response.status === 401) {
        await this.storage.remove(SESSION_KEY);
        return null;
      }
      throw new AuthError('refresh', 'Session refresh failed.');
    }
    const next = parseSession(await safeJson(response), Math.floor(this.now() / 1000));
    if (!next) {
      await this.storage.remove(SESSION_KEY);
      throw new AuthError('refresh', 'Session refresh returned an invalid session.');
    }
    await this.storage.set({ [SESSION_KEY]: next });
    return next;
  }

  private async consumeTransaction(): Promise<PkceTransaction> {
    const stored = await this.storage.get(PKCE_TRANSACTION_KEY);
    const transaction = parseTransaction(stored[PKCE_TRANSACTION_KEY]);
    await this.storage.remove(PKCE_TRANSACTION_KEY);
    if (!transaction || this.now() - transaction.createdAt > 5 * 60 * 1000) {
      throw new AuthError('state', 'The authentication attempt expired.');
    }
    return transaction;
  }

  private async authRequest(path: string, init: RequestInit): Promise<unknown> {
    let response: Response;
    try {
      response = await this.fetchImpl(`${trimTrailingSlash(this.config.supabaseUrl)}${path}`, init);
    } catch (error) {
      throw new AuthError(error instanceof TypeError ? 'network' : 'exchange', 'Authentication request failed.');
    }
    if (!response.ok) throw new AuthError('exchange', 'Authentication request was rejected.');
    return safeJson(response);
  }

  private authHeaders(accessToken?: string): Record<string, string> {
    return {
      apikey: this.config.publishableKey,
      ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {}),
    };
  }
}

export function createChromePkceAuth(
  config: PkceAuthConfig,
  fetchImpl: typeof fetch = fetch,
): PkceAuthClient {
  return new PkceAuthClient(
    config,
    new ChromeSessionAuthStorage(),
    {
      getRedirectURL: (path) => chrome.identity.getRedirectURL(path),
      launchWebAuthFlow: async (details) => {
        const callbackUrl = await chrome.identity.launchWebAuthFlow(details);
        if (!callbackUrl) throw new AuthError('exchange', 'Authentication did not return a callback.');
        return callbackUrl;
      },
    },
    fetchImpl,
  );
}

export function supabaseExtensionConfig(): PkceAuthConfig {
  const env = (import.meta as ImportMeta & { env?: Record<string, string | undefined> }).env;
  const supabaseUrl = env?.VITE_SUPABASE_URL;
  const publishableKey = env?.VITE_SUPABASE_PUBLISHABLE_KEY ?? env?.VITE_SUPABASE_ANON_KEY;
  if (!supabaseUrl || !publishableKey) {
    throw new AuthError('configuration', 'Supabase Auth is not configured for this extension build.');
  }
  return { supabaseUrl, publishableKey };
}

function validateConfig(config: PkceAuthConfig): void {
  let parsed: URL;
  try { parsed = new URL(config.supabaseUrl); } catch { throw new AuthError('configuration', 'Supabase Auth is not configured.'); }
  if (!['https:', 'http:'].includes(parsed.protocol) || (parsed.protocol === 'http:' && parsed.hostname !== 'localhost')) {
    throw new AuthError('configuration', 'Supabase Auth requires a secure project URL.');
  }
  if (!config.publishableKey.trim() || /(?:service_role|sb_secret|secret[_-]?key)/i.test(config.publishableKey)) {
    throw new AuthError('configuration', 'Only a Supabase publishable key may be used in the extension.');
  }
}

function validateProvider(value: string): string {
  if (!/^[a-z][a-z0-9_-]{0,31}$/i.test(value)) throw new AuthError('configuration', 'The requested sign-in provider is invalid.');
  return value;
}

function parseCallbackUrl(value: string): { code?: string; state?: string; error?: string } {
  let url: URL;
  try { url = new URL(value); } catch { throw new AuthError('state', 'The authentication response is invalid.'); }
  return {
    code: url.searchParams.get('code') ?? undefined,
    state: url.searchParams.get('state') ?? undefined,
    error: url.searchParams.get('error') ?? undefined,
  };
}

function parseTransaction(value: unknown): PkceTransaction | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const candidate = value as Partial<PkceTransaction>;
  if (typeof candidate.state !== 'string' || typeof candidate.codeVerifier !== 'string' ||
    typeof candidate.redirectUri !== 'string' || typeof candidate.createdAt !== 'number') return null;
  return candidate as PkceTransaction;
}

function parseSession(value: unknown, nowSeconds = Math.floor(Date.now() / 1000)): AuthSession | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const candidate = value as Partial<AuthSession>;
  if (typeof candidate.access_token !== 'string' || !candidate.access_token ||
    typeof candidate.refresh_token !== 'string' || !candidate.refresh_token ||
    typeof candidate.expires_in !== 'number' || !Number.isFinite(candidate.expires_in) ||
    typeof candidate.token_type !== 'string') return null;
  const expiresAt = typeof candidate.expires_at === 'number' && Number.isFinite(candidate.expires_at)
    ? candidate.expires_at
    : nowSeconds + candidate.expires_in;
  return {
    access_token: candidate.access_token,
    refresh_token: candidate.refresh_token,
    expires_in: candidate.expires_in,
    expires_at: expiresAt,
    token_type: candidate.token_type,
  };
}

async function safeJson(response: Response): Promise<unknown> {
  try { return await response.json(); } catch { return null; }
}

function trimTrailingSlash(value: string): string { return value.replace(/\/+$/u, ''); }

function randomBase64Url(size: number): string {
  const bytes = new Uint8Array(size);
  crypto.getRandomValues(bytes);
  return base64Url(bytes);
}

async function sha256Base64Url(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return base64Url(new Uint8Array(digest));
}

function base64Url(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/u, '');
}

export const AUTH_STORAGE_KEYS = Object.freeze({ PKCE_TRANSACTION_KEY, SESSION_KEY });
