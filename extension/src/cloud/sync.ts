import { validateWorkflow } from '../workflows/serialization';
import { LocalWorkflowStore } from '../workflows/storage';
import type { LocalWorkflow, WorkflowStorageAdapter } from '../workflows/types';
import type { AuthTokenProvider } from '../auth/pkce';

export type SyncState = 'synced' | 'offline' | 'error' | 'unauthenticated';

export type SyncResult<Local, Remote> = {
  state: SyncState;
  local: Local;
  remote?: Remote;
  error?: Error;
};

export class CloudSyncError extends Error {
  readonly state: Exclude<SyncState, 'synced'>;
  readonly status?: number;

  constructor(state: Exclude<SyncState, 'synced'>, message: string, status?: number) {
    super(message);
    this.name = 'CloudSyncError';
    this.state = state;
    this.status = status;
  }
}

export type EdgeFunctionClientConfig = {
  supabaseUrl: string;
  publishableKey: string;
  auth: AuthTokenProvider;
  fetchImpl?: typeof fetch;
};

export class AuthenticatedEdgeFunctionClient {
  private readonly fetchImpl: typeof fetch;

  constructor(private readonly config: EdgeFunctionClientConfig) {
    this.fetchImpl = config.fetchImpl ?? fetch;
    validateEdgeConfig(config);
  }

  async call<T>(functionName: string, body: unknown, options: { idempotencyKey?: string } = {}): Promise<T> {
    if (!/^[a-z][a-z0-9-]{0,63}$/u.test(functionName)) throw new CloudSyncError('error', 'The cloud operation is invalid.');
    const firstToken = await this.config.auth.getAccessToken();
    if (!firstToken) throw new CloudSyncError('unauthenticated', 'Sign in to sync Swara data.');
    const request = (token: string) => this.fetchImpl(
      `${trimTrailingSlash(this.config.supabaseUrl)}/functions/v1/${functionName}`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${token}`,
          apikey: this.config.publishableKey,
          'Content-Type': 'application/json',
          'X-Client-Info': 'swara-extension',
          ...(options.idempotencyKey ? { 'Idempotency-Key': options.idempotencyKey } : {}),
        },
        body: JSON.stringify(body),
      },
    );

    let response: Response;
    try {
      response = await request(firstToken);
      if (response.status === 401) {
        const refreshed = await this.config.auth.getAccessToken(true);
        if (!refreshed) throw new CloudSyncError('unauthenticated', 'Your session has expired.', 401);
        response = await request(refreshed);
      }
    } catch (error) {
      if (error instanceof CloudSyncError) throw error;
      throw new CloudSyncError(error instanceof TypeError || isOffline() ? 'offline' : 'error', 'Cloud sync is unavailable.');
    }
    if (!response.ok) throw new CloudSyncError(isOffline() ? 'offline' : 'error', 'Cloud sync was rejected.', response.status);
    const payload = await readJson(response);
    if (isEnvelope(payload)) {
      if (!payload.ok) throw new CloudSyncError('error', 'Cloud sync was rejected.', response.status);
      return payload.data as T;
    }
    return payload as T;
  }
}

export type LocalSyncCache<T> = {
  get: (key: string) => Promise<T | undefined>;
  set: (key: string, value: T) => Promise<void>;
};

export class ChromeLocalSyncCache<T> implements LocalSyncCache<T> {
  constructor(private readonly storage: WorkflowStorageAdapter) {}

  async get(key: string): Promise<T | undefined> {
    return (await this.storage.get(key))[key] as T | undefined;
  }

  async set(key: string, value: T): Promise<void> {
    await this.storage.set({ [key]: value });
  }
}

export type WorkflowImportResult = {
  workflow_id: string;
  version_id: string;
  content_hash: string;
  step_count: number;
  duplicate: boolean;
};

export class WorkflowCloudSync {
  constructor(
    private readonly edge: AuthenticatedEdgeFunctionClient,
    private readonly local: LocalWorkflowStore,
  ) {}

  async save(workflow: LocalWorkflow, expectedCurrentVersionId?: string): Promise<SyncResult<LocalWorkflow, WorkflowImportResult>> {
    const valid = validateWorkflow(workflow);
    await this.local.save(valid);
    const idempotencyKey = `workflow-import:${valid.id}:${valid.updatedAt}`;
    try {
      const remote = await this.edge.call<WorkflowImportResult>('workflow-import', {
        workflow_id: uuidOrNull(valid.id),
        name: valid.name,
        schema_version: valid.schemaVersion,
        definition: {
          steps: valid.actions,
          variables: valid.variables.map(({ key, label, sensitive }) => ({ key, label, ...(sensitive ? { sensitive: true } : {}) })),
        },
        expected_current_version_id: expectedCurrentVersionId ?? null,
        idempotency_key: idempotencyKey,
      }, { idempotencyKey });
      return { state: 'synced', local: valid, remote };
    } catch (error) {
      return { state: syncState(error), local: valid, error: asError(error) };
    }
  }
}

export type ContextSyncItem = {
  id?: string;
  type: string;
  category?: string | null;
  key: string;
  value: string;
  scope: string;
  documentId?: string | null;
  updatedAt?: string | null;
};

export type ContextSyncConfig = { functionName?: string; localKey?: string };

export type ContextSyncRemoteItem = Required<Pick<ContextSyncItem, 'id' | 'type' | 'category' | 'key' | 'value' | 'scope' | 'updatedAt'>> & {
  documentId: string | null;
};

export type ContextSyncRemoteResult = {
  operation: 'created' | 'corrected' | 'unchanged';
  item: ContextSyncRemoteItem;
};

export class ContextCloudSync {
  private readonly functionName: string;
  private readonly localKey: string;

  constructor(
    private readonly edge: AuthenticatedEdgeFunctionClient,
    private readonly local: LocalSyncCache<ContextSyncItem[]>,
    config: ContextSyncConfig = {},
  ) {
    this.functionName = config.functionName ?? 'context-sync';
    this.localKey = config.localKey ?? 'swara.cloud.context.v1';
  }

  async save(item: ContextSyncItem): Promise<SyncResult<ContextSyncItem, ContextSyncRemoteResult>> {
    const existing = await this.local.get(this.localKey) ?? [];
    const next = [...existing.filter((candidate) => candidate.id !== item.id && candidate.key !== item.key), item];
    await this.local.set(this.localKey, next);
    const idempotencyKey = `context-sync:${item.id ?? item.key}:${item.updatedAt ?? 'new'}`;
    try {
      const remote = await this.edge.call<ContextSyncRemoteResult>(this.functionName, { operation: 'upsert', item }, { idempotencyKey });
      const local = remoteContextItem(remote.item);
      await this.local.set(this.localKey, [...next.filter((candidate) => candidate.id !== item.id && candidate.key !== item.key), local]);
      return { state: 'synced', local, remote };
    } catch (error) {
      return { state: syncState(error), local: item, error: asError(error) };
    }
  }
}

function remoteContextItem(item: ContextSyncRemoteItem): ContextSyncItem {
  return {
    id: item.id,
    type: item.type,
    category: item.category,
    key: item.key,
    value: item.value,
    scope: item.scope,
    documentId: item.documentId,
    updatedAt: item.updatedAt,
  };
}

export type VaultMetadataInput = {
  filename: string;
  mimeType: string;
  sizeBytes: number;
  sha256: string;
  extractionMethod: 'local' | 'ocr' | 'manual';
};

export type VaultUploadResult = {
  document_id: string;
  storage_bucket: string;
  storage_path: string;
  status: string;
  duplicate: boolean;
  next_step: string;
};

export class VaultMetadataCloudSync {
  constructor(
    private readonly edge: AuthenticatedEdgeFunctionClient,
    private readonly local: LocalSyncCache<VaultMetadataInput[]>,
    private readonly localKey = 'swara.cloud.vault-metadata.v1',
  ) {}

  async createUploadIntent(input: VaultMetadataInput): Promise<SyncResult<VaultMetadataInput, VaultUploadResult>> {
    const existing = await this.local.get(this.localKey) ?? [];
    await this.local.set(this.localKey, [...existing.filter((candidate) => candidate.sha256 !== input.sha256), input]);
    const idempotencyKey = `vault-intent:${input.sha256}`;
    try {
      const remote = await this.edge.call<VaultUploadResult>('vault-upload-intent', {
        filename: input.filename,
        mime_type: input.mimeType,
        size_bytes: input.sizeBytes,
        sha256: input.sha256,
        extraction_method: input.extractionMethod,
      }, { idempotencyKey });
      return { state: 'synced', local: input, remote };
    } catch (error) {
      return { state: syncState(error), local: input, error: asError(error) };
    }
  }

  async finalizeUpload(documentId: string, sha256: string): Promise<SyncResult<{ documentId: string; sha256: string }, VaultUploadResult>> {
    const local = { documentId, sha256 };
    const idempotencyKey = `vault-finalize:${documentId}:${sha256}`;
    try {
      const remote = await this.edge.call<VaultUploadResult>('vault-finalize-upload', {
        document_id: documentId,
        sha256,
      }, { idempotencyKey });
      return { state: 'synced', local, remote };
    } catch (error) {
      return { state: syncState(error), local, error: asError(error) };
    }
  }

  async deleteDocument(documentId: string): Promise<SyncResult<{ documentId: string }, unknown>> {
    const local = { documentId };
    const idempotencyKey = `vault-delete:${documentId}`;
    try {
      const remote = await this.edge.call('vault-delete', { document_id: documentId }, { idempotencyKey });
      return { state: 'synced', local, remote };
    } catch (error) {
      return { state: syncState(error), local, error: asError(error) };
    }
  }
}

export function localWorkflowStore(storage: WorkflowStorageAdapter): LocalWorkflowStore {
  return new LocalWorkflowStore(storage);
}

function syncState(error: unknown): SyncState {
  return error instanceof CloudSyncError ? error.state : (isOffline() ? 'offline' : 'error');
}

function asError(error: unknown): Error {
  return error instanceof Error ? error : new Error('Cloud sync is unavailable.');
}

function uuidOrNull(value: string): string | null {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(value) ? value.toLowerCase() : null;
}

function validateEdgeConfig(config: EdgeFunctionClientConfig): void {
  let url: URL;
  try { url = new URL(config.supabaseUrl); } catch { throw new CloudSyncError('error', 'Supabase cloud sync is not configured.'); }
  if (!['https:', 'http:'].includes(url.protocol) || (url.protocol === 'http:' && url.hostname !== 'localhost')) {
    throw new CloudSyncError('error', 'Supabase cloud sync requires a secure project URL.');
  }
  if (!config.publishableKey.trim() || /(?:service_role|sb_secret|secret[_-]?key)/i.test(config.publishableKey)) {
    throw new CloudSyncError('error', 'Only a Supabase publishable key may be used for cloud sync.');
  }
}

async function readJson(response: Response): Promise<unknown> {
  try { return await response.json(); } catch { throw new CloudSyncError('error', 'Cloud sync returned an invalid response.'); }
}

function isEnvelope(value: unknown): value is { ok: boolean; data?: unknown } {
  return !!value && typeof value === 'object' && !Array.isArray(value) && 'ok' in value;
}

function isOffline(): boolean {
  return typeof navigator !== 'undefined' && navigator.onLine === false;
}

function trimTrailingSlash(value: string): string { return value.replace(/\/+$/u, ''); }
