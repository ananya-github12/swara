import React, { useState, useEffect, useRef } from 'react';
import { createRoot } from 'react-dom/client';
import {
  BookOpen,
  FileText,
  Plus,
  ShieldCheck,
  Sparkles,
  UploadCloud,
  Zap,
} from 'lucide-react';
import { authenticatedServerRequest, extensionAuth } from '../sidepanel/api';
import { supabaseExtensionConfig } from '../auth';
import { AuthenticatedEdgeFunctionClient, ChromeLocalSyncCache, VaultMetadataCloudSync, type VaultMetadataInput } from '../cloud';
import { DocumentScanUpload, type ScanStage } from './DocumentScanUpload';
import {
  DOCUMENT_ACCEPT,
  MAX_BATCH_BYTES,
  MAX_BATCH_FILES,
  fileValidationError,
  prepareDocument,
  type PreparedDocument,
} from './documentPreparation';

type ContextItem = {
  id?: string;
  type: 'fact' | 'document' | 'preference' | 'correction' | 'instruction';
  category?: string | null;
  key: string;
  value: string;
  scope: 'persistent' | 'session' | 'task';
  supersededBy?: string | null;
  documentId?: string | null;
};

type DocumentRow = {
  id: string;
  filename: string;
  status: 'pending' | 'processing' | 'done' | 'failed';
  createdAt?: string | null;
  contextItemsCreated: number;
  error?: string | null;
  processingMethod?: 'local' | 'ocr' | null;
};

type Activity = {
  id: string;
  event: 'created' | 'updated' | 'superseded';
  key: string;
  value: string;
  type: ContextItem['type'];
  scope?: ContextItem['scope'];
  updatedAt?: string | null;
};

const categories = ['identity', 'education', 'experience', 'preferences'];

async function request<T>(path: string, options?: RequestInit): Promise<T> {
  const response = await authenticatedServerRequest(path, options);
  if (!response.ok) {
    let detail = `Request failed (${response.status}).`;
    try {
      const body = await response.json() as { detail?: string; message?: string };
      if (body.detail) detail = body.detail;
      else if (body.message) detail = body.message;
    } catch { /* use status text */ }
    throw new Error(detail);
  }
  if (response.status === 204) return undefined as T;
  return response.json() as Promise<T>;
}

function displayDate(value?: string | null) {
  if (!value) return 'Just now';
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? value : date.toLocaleDateString(undefined, {
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit'
  });
}

function timeAgo(dateString?: string | null): string {
  if (!dateString) return 'just now';
  const now = new Date();
  const date = new Date(dateString);
  const seconds = Math.floor((now.getTime() - date.getTime()) / 1000);
  if (Number.isNaN(seconds) || seconds < 0) return 'just now';

  const intervals = {
    year: 31536000,
    month: 2592000,
    week: 604800,
    day: 86400,
    hour: 3600,
    minute: 60,
    second: 1
  };

  for (const [unit, value] of Object.entries(intervals)) {
    const count = Math.floor(seconds / value);
    if (count >= 1) {
      return `${count} ${unit}${count > 1 ? 's' : ''} ago`;
    }
  }
  return 'just now';
}

const Notice: React.FC<{
  message: string;
  type: 'success' | 'error';
  onDismiss: () => void;
}> = ({ message, type, onDismiss }) => {
  return (
    <div className={`notice-banner notice-banner--${type}`} role="alert">
      <div className="notice-message">{message}</div>
      <button
        type="button"
        className="notice-dismiss"
        onClick={onDismiss}
        aria-label="Dismiss message"
      >
        ✕
      </button>
    </div>
  );
};

const FactRow: React.FC<{
  item: ContextItem;
  onSave: (item: ContextItem, newValue: string) => Promise<void>;
  onDelete: (item: ContextItem) => Promise<void>;
}> = ({ item, onSave, onDelete }) => {
  const [isEditing, setIsEditing] = useState(false);
  const [editValue, setEditValue] = useState(item.value);
  const [isSaving, setIsSaving] = useState(false);
  const [deleteConfirm, setDeleteConfirm] = useState(false);

  const handleSave = async () => {
    if (!editValue.trim()) return;
    if (editValue.trim() === item.value) {
      setIsEditing(false);
      return;
    }
    setIsSaving(true);
    try {
      await onSave(item, editValue.trim());
      setIsEditing(false);
    } catch {
      // Handled by parent notice
    } finally {
      setIsSaving(false);
    }
  };

  const handleDelete = async () => {
    setIsSaving(true);
    try {
      await onDelete(item);
    } catch {
      // Handled by parent notice
    } finally {
      setIsSaving(false);
      setDeleteConfirm(false);
    }
  };

  return (
    <article className="fact-row-card">
      <div className="fact-row-header">
        <div className="fact-row-meta">
          <strong className="fact-row-key">{item.key}</strong>
          <span className={`badge badge--type badge--${item.type}`}>{item.type}</span>
          <span className={`badge badge--scope badge--${item.scope}`}>{item.scope}</span>
        </div>

        <div className="fact-row-actions">
          {isEditing ? (
            <>
              <button
                type="button"
                className="text-button text-button--success"
                onClick={handleSave}
                disabled={isSaving}
              >
                {isSaving ? 'Saving...' : 'Save'}
              </button>
              <button
                type="button"
                className="text-button text-button--muted"
                onClick={() => {
                  setIsEditing(false);
                  setEditValue(item.value);
                }}
                disabled={isSaving}
              >
                Cancel
              </button>
            </>
          ) : deleteConfirm ? (
            <span className="inline-confirm">
              Delete? ·{' '}
              <button
                type="button"
                className="text-button text-button--danger text-button--bold"
                onClick={handleDelete}
                disabled={isSaving}
              >
                Yes
              </button>{' '}
              /{' '}
              <button
                type="button"
                className="text-button text-button--muted"
                onClick={() => setDeleteConfirm(false)}
                disabled={isSaving}
              >
                Cancel
              </button>
            </span>
          ) : (
            <>
              <button
                type="button"
                className="text-button"
                onClick={() => setIsEditing(true)}
              >
                Edit
              </button>
              <button
                type="button"
                className="text-button text-button--danger"
                onClick={() => setDeleteConfirm(true)}
              >
                Delete
              </button>
            </>
          )}
        </div>
      </div>

      <div className="fact-row-content">
        {isEditing ? (
          <input
            type="text"
            className="fact-edit-input"
            value={editValue}
            onChange={(e) => setEditValue(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter') handleSave();
              if (e.key === 'Escape') {
                setIsEditing(false);
                setEditValue(item.value);
              }
            }}
            autoFocus
            aria-label={`Edit value for ${item.key}`}
          />
        ) : (
          <p className="fact-value">{item.value}</p>
        )}
      </div>
    </article>
  );
};

const CategorySection: React.FC<{
  title: string;
  items: ContextItem[];
  guidanceText: string;
  onAddFact: (category: string, key: string, value: string) => Promise<void>;
  onSaveFact: (item: ContextItem, newValue: string) => Promise<void>;
  onDeleteFact: (item: ContextItem) => Promise<void>;
}> = ({ title, items, guidanceText, onAddFact, onSaveFact, onDeleteFact }) => {
  const [showAddForm, setShowAddForm] = useState(false);
  const [newKey, setNewKey] = useState('');
  const [newValue, setNewValue] = useState('');
  const [isSubmitting, setIsSubmitting] = useState(false);

  const handleAddSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!newKey.trim() || !newValue.trim()) return;
    setIsSubmitting(true);
    try {
      await onAddFact(title, newKey.trim(), newValue.trim());
      setNewKey('');
      setNewValue('');
      setShowAddForm(false);
    } catch {
      // Parent displays notice
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <div className="category-group">
      <div className="category-header">
        <h3 className="category-title">{title}</h3>
        {!showAddForm && (
          <button
            type="button"
            className="text-button text-button--accent"
            onClick={() => setShowAddForm(true)}
          >
            Add fact
          </button>
        )}
      </div>

      {showAddForm && (
        <form onSubmit={handleAddSubmit} className="add-fact-form">
          <input
            type="text"
            className="add-fact-input"
            placeholder="Fact name (e.g. Email Address)"
            value={newKey}
            onChange={(e) => setNewKey(e.target.value)}
            required
            disabled={isSubmitting}
            aria-label="New fact name"
          />
          <input
            type="text"
            className="add-fact-input"
            placeholder="Value (e.g. alex@example.com)"
            value={newValue}
            onChange={(e) => setNewValue(e.target.value)}
            required
            disabled={isSubmitting}
            aria-label="New fact value"
          />
          <div className="add-fact-actions">
            <button type="submit" className="button" disabled={isSubmitting}>
              {isSubmitting ? 'Saving...' : 'Save fact'}
            </button>
            <button
              type="button"
              className="button button--secondary"
              onClick={() => {
                setShowAddForm(false);
                setNewKey('');
                setNewValue('');
              }}
              disabled={isSubmitting}
            >
              Cancel
            </button>
          </div>
        </form>
      )}

      <div className="category-items">
        {items.length === 0 ? (
          <p className="empty-guidance">{guidanceText}</p>
        ) : (
          items.map((item) => (
            <FactRow
              key={item.id || item.key}
              item={item}
              onSave={onSaveFact}
              onDelete={onDeleteFact}
            />
          ))
        )}
      </div>
    </div>
  );
};

const OtherSection: React.FC<{
  items: ContextItem[];
  onSaveFact: (item: ContextItem, newValue: string) => Promise<void>;
  onDeleteFact: (item: ContextItem) => Promise<void>;
}> = ({ items, onSaveFact, onDeleteFact }) => {
  if (items.length === 0) return null;

  return (
    <div className="category-group">
      <div className="category-header">
        <h3 className="category-title">Other</h3>
      </div>

      <div className="category-items">
        {items.map((item) => (
          <FactRow
            key={item.id || item.key}
            item={item}
            onSave={onSaveFact}
            onDelete={onDeleteFact}
          />
        ))}
      </div>
    </div>
  );
};

const DocumentRowComponent: React.FC<{
  document: DocumentRow;
  contextItems: ContextItem[];
  onDelete: (docId: string) => Promise<void>;
}> = ({ document, contextItems, onDelete }) => {
  const [isExpanded, setIsExpanded] = useState(false);
  const [deleteConfirm, setDeleteConfirm] = useState(false);
  const [isDeleting, setIsDeleting] = useState(false);

  // Everything OCR pulled out of this file. It stays out of the profile and
  // lives here instead — the server sends `documentId` on each derived item.
  const docItems = contextItems.filter(
    (item) => item.type === 'document' && item.documentId === document.id,
  );

  const handleDelete = async (e: React.MouseEvent) => {
    e.stopPropagation();
    setIsDeleting(true);
    try {
      await onDelete(document.id);
    } catch {
      setIsDeleting(false);
    }
  };

  const cleanKey = (key: string) => {
    const parts = key.split(':');
    if (parts.length > 2) {
      return parts.slice(2).join(':').replace(/_/g, ' ');
    }
    return key;
  };

  return (
    <div
      className={`document-card ${isExpanded ? 'document-card--expanded' : ''}`}
      role="button"
      tabIndex={0}
      aria-expanded={isExpanded}
      aria-label={`${document.filename}, ${docItems.length} extracted details`}
      onClick={() => setIsExpanded(!isExpanded)}
      onKeyDown={(event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          setIsExpanded(!isExpanded);
        }
      }}
    >
      <div className="document-card-header">
        <span className="document-icon"><FileText size={17} /></span>
        <div className="document-card-info">
          <div className="document-card-title">
            <span className="document-card-filename">{document.filename}</span>
            <span className={`badge badge--status badge--${document.status}`}>
              {document.status}
            </span>
            {document.processingMethod && (
              <span className={`badge badge--method badge--${document.processingMethod}`}>
                {document.processingMethod === 'local' ? 'AnyDoc' : 'OCR'}
              </span>
            )}
          </div>
          <div className="document-card-meta">
            <span className="tabular">{docItems.length}</span> details extracted
            {document.createdAt && (
              <>
                {' · '}
                <span>{displayDate(document.createdAt)}</span>
              </>
            )}
          </div>
        </div>

        <div className="document-card-actions" onClick={(e) => e.stopPropagation()}>
          {deleteConfirm ? (
            <span className="inline-confirm warning-confirm">
              Delete doc & derived facts? ·{' '}
              <button
                type="button"
                className="text-button text-button--danger text-button--bold"
                onClick={handleDelete}
                disabled={isDeleting}
              >
                {isDeleting ? 'Deleting...' : 'Yes'}
              </button>{' '}
              /{' '}
              <button
                type="button"
                className="text-button text-button--muted"
                onClick={() => setDeleteConfirm(false)}
                disabled={isDeleting}
              >
                Cancel
              </button>
            </span>
          ) : (
            <button
              type="button"
              className="text-button text-button--danger"
              onClick={() => setDeleteConfirm(true)}
            >
              Delete
            </button>
          )}
        </div>
      </div>

      {document.status === 'failed' && document.error && (
        <div className="document-card-error">
          Error: {document.error}
        </div>
      )}

      {isExpanded && (
        <div className="document-card-disclosure" onClick={(e) => e.stopPropagation()}>
          {docItems.length === 0 ? (
            <p className="empty-subtext">
              {document.status === 'pending' || document.status === 'processing'
                ? 'Processing document text and extracting details...'
                : 'No details were extracted from this document.'}
            </p>
          ) : (
            <div className="document-derived-list">
              {docItems.map((item) => (
                <div key={item.id || item.key} className="document-derived-item">
                  <div className="derived-item-header">
                    <span className="derived-item-key">{cleanKey(item.key)}</span>
                    <span className="badge badge--scope">{item.scope}</span>
                  </div>
                  <p className="derived-item-value">{item.value}</p>
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
};

const ActivityRowComponent: React.FC<{
  activity: Activity;
}> = ({ activity }) => {
  const [history, setHistory] = useState<ContextItem[] | null>(null);
  const [isLoadingHistory, setIsLoadingHistory] = useState(false);

  useEffect(() => {
    if (activity.event !== 'superseded') return;

    let isMounted = true;
    const fetchHistory = async () => {
      setIsLoadingHistory(true);
      try {
        const data = await request<ContextItem[]>(`/vault/context?include_history=true`);
        if (isMounted) {
          setHistory(data);
        }
      } catch {
        // Fail silently per instructions
      } finally {
        if (isMounted) {
          setIsLoadingHistory(false);
        }
      }
    };

    fetchHistory();
    return () => {
      isMounted = false;
    };
  }, [activity.event, activity.key]);

  const renderCorrection = () => {
    if (!history) return null;
    const index = history.findIndex(version => version.id === activity.id);
    if (index === -1) return null;
    const after = history[index + 1];
    if (!after) return null;

    return (
      <div className="activity-correction">
        <span className="correction-label">Corrected:</span>{' '}
        <span className="value-old">{activity.value}</span>{' '}
        <span className="arrow">→</span>{' '}
        <span className="value-new">{after.value}</span>
      </div>
    );
  };

  return (
    <div className="activity-item">
      <div className="activity-item-header">
        <div className="activity-item-meta">
          <span className={`badge badge--event badge--${activity.event}`}>{activity.event}</span>
          <span className={`badge badge--type badge--${activity.type}`}>{activity.type}</span>
          {activity.scope && (
            <span className={`badge badge--scope badge--${activity.scope}`}>{activity.scope}</span>
          )}
        </div>
        <time className="activity-item-time">{displayDate(activity.updatedAt)}</time>
      </div>

      <div className="activity-item-title">
        <strong>{activity.key}</strong>
      </div>
      <p className="activity-item-value">{activity.value}</p>

      {activity.event === 'superseded' && renderCorrection()}
    </div>
  );
};

const App: React.FC = () => {
  const [context, setContext] = useState<ContextItem[]>([]);
  const [documents, setDocuments] = useState<DocumentRow[]>([]);
  const [activityItems, setActivityItems] = useState<Activity[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [notice, setNotice] = useState<{ message: string; type: 'success' | 'error' } | null>(null);

  const [uploadOpen, setUploadOpen] = useState(false);
  const [isDragActive, setIsDragActive] = useState(false);
  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  const [scanFileName, setScanFileName] = useState<string | null>(null);
  const [scanStage, setScanStage] = useState<ScanStage>('idle');
  const [scanText, setScanText] = useState('');
  const [scanFullText, setScanFullText] = useState('');
  const [sourceValue, setSourceValue] = useState('');
  const [batchProgress, setBatchProgress] = useState<{ current: number; total: number } | null>(null);
  const [uploading, setUploading] = useState(false);
  const selectionRef = useRef(0);

  const load = async () => {
    try {
      const [ctx, docs] = await Promise.all([
        request<ContextItem[]>('/vault/context'),
        request<DocumentRow[]>('/vault/documents'),
      ]);
      setContext(ctx);
      setDocuments(docs);
      setActivityItems([]);
    } catch (error) {
      setNotice({
        message: error instanceof Error ? error.message : 'Could not load the vault.',
        type: 'error',
      });
    } finally {
      setIsLoading(false);
    }
  };

  useEffect(() => {
    load();
  }, []);

  // Poll only while document processing is running. Each document is polled on its
  // own endpoint so concurrent jobs stay independent, and the whole vault is
  // reloaded once at the end to pick up the context items OCR produced.
  useEffect(() => {
    const inFlight = documents.filter(
      (doc) => doc.status === 'pending' || doc.status === 'processing',
    );
    if (inFlight.length === 0) return;

    let cancelled = false;
    const intervalId = setInterval(async () => {
      try {
        const refreshed = await Promise.all(
          inFlight.map((doc) =>
            request<DocumentRow>(`/vault/documents/${encodeURIComponent(doc.id)}`),
          ),
        );
        if (cancelled) return;

        const byId = new Map(refreshed.map((doc) => [doc.id, doc]));
        setDocuments((prevDocs) => prevDocs.map((doc) => byId.get(doc.id) ?? doc));
        const settled = refreshed.every(
          (doc) => doc.status !== 'pending' && doc.status !== 'processing',
        );
        if (settled) load();
      } catch (err) {
        if (cancelled) return;
        setNotice({
          message: err instanceof Error ? err.message : 'Could not check document status.',
          type: 'error',
        });
      }
    }, 2000);

    return () => {
      cancelled = true;
      clearInterval(intervalId);
    };
  }, [documents]);

  // AnyDoc returns the full Markdown at once. Reveal it progressively so the
  // user can see what was extracted before choosing to save it to the Vault.
  useEffect(() => {
    if (scanStage !== 'local' || !scanFullText) return;
    const selectionId = selectionRef.current;
    const duration = Math.min(1800, Math.max(650, scanFullText.length / 8));
    const startedAt = performance.now();
    let frame = 0;
    const reveal = (now: number) => {
      if (selectionId !== selectionRef.current) return;
      const progress = Math.min(1, (now - startedAt) / duration);
      setScanText(scanFullText.slice(0, Math.floor(scanFullText.length * progress)));
      if (progress < 1) frame = requestAnimationFrame(reveal);
      else setScanStage('ready');
    };
    frame = requestAnimationFrame(reveal);
    return () => cancelAnimationFrame(frame);
  }, [scanFullText, scanStage]);

  const handleSaveFact = async (item: ContextItem, newValue: string) => {
    if (!item.id) return;
    try {
      await request<ContextItem>(`/vault/context/${encodeURIComponent(item.id)}/corrections`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ value: newValue }),
      });
      setNotice({ message: 'Fact updated.', type: 'success' });
      await load();
    } catch (error) {
      setNotice({
        message: error instanceof Error ? error.message : 'Could not update fact.',
        type: 'error',
      });
      throw error;
    }
  };

  const handleDeleteFact = async (item: ContextItem) => {
    if (!item.id) return;
    try {
      setNotice({ message: 'Facts are immutable; add a correction to preserve history.', type: 'error' });
    } catch (error) {
      setNotice({
        message: error instanceof Error ? error.message : 'Could not delete fact.',
        type: 'error',
      });
      throw error;
    }
  };

  const handleAddFact = async (category: string, key: string, value: string) => {
    try {
      await request<ContextItem>('/vault/context', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          type: category === 'preferences' ? 'preference' : 'fact',
          category,
          key,
          value,
          scope: 'persistent',
        }),
      });
      setNotice({ message: 'Fact added.', type: 'success' });
      await load();
    } catch (error) {
      setNotice({
        message: error instanceof Error ? error.message : 'Could not add fact.',
        type: 'error',
      });
      throw error;
    }
  };

  const handleDeleteDocument = async (docId: string) => {
    try {
      const config = supabaseExtensionConfig();
      const auth = extensionAuth();
      const edge = new AuthenticatedEdgeFunctionClient({ supabaseUrl: config.supabaseUrl, publishableKey: config.publishableKey, auth });
      const cache = new ChromeLocalSyncCache<VaultMetadataInput[]>({
        get: (key) => chrome.storage.local.get(key),
        set: (items) => chrome.storage.local.set(items),
        remove: (key) => chrome.storage.local.remove(key),
      });
      const result = await new VaultMetadataCloudSync(edge, cache).deleteDocument(docId);
      if (result.state !== 'synced') throw result.error ?? new Error('Vault deletion failed.');
      setNotice({ message: 'Document and derived context deleted.', type: 'success' });
      await load();
    } catch (error) {
      setNotice({
        message: error instanceof Error ? error.message : 'Could not delete document.',
        type: 'error',
      });
      throw error;
    }
  };

  const resetUpload = () => {
    selectionRef.current += 1;
    setSelectedFile(null);
    setScanFileName(null);
    setScanStage('idle');
    setScanText('');
    setScanFullText('');
    setSourceValue('');
    setBatchProgress(null);
    setUploading(false);
  };

  const openUpload = () => {
    resetUpload();
    setUploadOpen(true);
  };

  const uploadPreparedDocument = async (
    file: File,
    filename: string,
    prepared: PreparedDocument,
  ): Promise<DocumentRow> => {
    const config = supabaseExtensionConfig();
    const auth = extensionAuth();
    const edge = new AuthenticatedEdgeFunctionClient({
      supabaseUrl: config.supabaseUrl,
      publishableKey: config.publishableKey,
      auth,
    });
    const cache = new ChromeLocalSyncCache<VaultMetadataInput[]>({
      get: (key) => chrome.storage.local.get(key),
      set: (items) => chrome.storage.local.set(items),
      remove: (key) => chrome.storage.local.remove(key),
    });
    const sync = new VaultMetadataCloudSync(edge, cache);
    const bytes = new Uint8Array(await file.arrayBuffer());
    const digest = await crypto.subtle.digest('SHA-256', bytes);
    const sha256 = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
    const intent = await sync.createUploadIntent({
      filename,
      mimeType: file.type || 'text/plain',
      sizeBytes: file.size,
      sha256,
      extractionMethod: prepared.method,
    });
    if (intent.state !== 'synced' || !intent.remote) throw intent.error ?? new Error('Could not create the Vault upload intent.');
    const token = await auth.getAccessToken();
    if (!token) throw new Error('Sign in to upload to the Vault.');
    const encodedPath = intent.remote.storage_path.split('/').map(encodeURIComponent).join('/');
    const upload = await fetch(`${config.supabaseUrl.replace(/\/+$/u, '')}/storage/v1/object/${encodeURIComponent(intent.remote.storage_bucket)}/${encodedPath}`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        apikey: config.publishableKey,
        'Content-Type': file.type || 'application/octet-stream',
        'x-upsert': 'false',
      },
      body: bytes,
    });
    if (!upload.ok) throw new Error('Vault object upload was rejected.');
    const finalized = await sync.finalizeUpload(intent.remote.document_id, sha256);
    if (finalized.state !== 'synced' || !finalized.remote) throw finalized.error ?? new Error('Vault upload finalization failed.');
    return {
      id: finalized.remote.document_id,
      filename,
      status: finalized.remote.status as DocumentRow['status'],
      contextItemsCreated: 0,
      processingMethod: prepared.method,
    };
  };

  const prepareSingleFile = async (file: File) => {
    const selectionId = ++selectionRef.current;
    setSelectedFile(file);
    setScanFileName(file.name);
    setSourceValue(file.name);
    setScanText('');
    setScanFullText('');
    setScanStage('local');
    try {
      const prepared = await prepareDocument(file);
      if (selectionId !== selectionRef.current) return;
      if (prepared.method === 'ocr') {
        setScanStage('ocr');
      } else {
        setScanFullText(prepared.markdown);
      }
    } catch (error) {
      if (selectionId !== selectionRef.current) return;
      resetUpload();
      setNotice({
        message: error instanceof Error ? error.message : 'Could not read this document.',
        type: 'error',
      });
    }
  };

  const processBatch = async (files: File[]) => {
    const selectionId = ++selectionRef.current;
    setUploading(true);
    setBatchProgress({ current: 1, total: files.length });
    const completed: DocumentRow[] = [];
    const failures: string[] = [];

    for (let index = 0; index < files.length; index += 1) {
      if (selectionId !== selectionRef.current) return;
      const file = files[index];
      setBatchProgress({ current: index + 1, total: files.length });
      setSelectedFile(file);
      setScanFileName(file.name);
      setSourceValue(file.name);
      setScanText('');
      setScanFullText('');
      setScanStage('local');
      try {
        const prepared = await prepareDocument(file);
        if (selectionId !== selectionRef.current) return;
        setScanStage(prepared.method === 'ocr' ? 'ocr' : 'uploading');
        if (prepared.method === 'local') {
          setScanText(prepared.markdown);
          setScanFullText(prepared.markdown);
        }
        const document = await uploadPreparedDocument(file, file.name, prepared);
        completed.push(document);
      } catch (error) {
        failures.push(`${file.name}: ${error instanceof Error ? error.message : 'processing failed'}`);
      }
    }

    if (selectionId !== selectionRef.current) return;
    setUploading(false);
    setUploadOpen(false);
    resetUpload();
    await load();
    setNotice({
      message: failures.length
        ? `${completed.length} document(s) added; ${failures.join(' ')}`
        : `${completed.length} documents added. Readable files were parsed locally; OCR was queued only where needed.`,
      type: failures.length ? 'error' : 'success',
    });
  };

  const handleSelectedFiles = (files: File[]) => {
    if (!files.length) return;
    const accepted: File[] = [];
    const errors: string[] = [];
    let totalBytes = 0;

    for (const file of files.slice(0, MAX_BATCH_FILES)) {
      const validation = fileValidationError(file);
      if (validation) {
        errors.push(validation);
        continue;
      }
      if (totalBytes + file.size > MAX_BATCH_BYTES) {
        errors.push(`${file.name}: the batch exceeds the 100 MB limit.`);
        continue;
      }
      totalBytes += file.size;
      accepted.push(file);
    }
    if (files.length > MAX_BATCH_FILES) errors.push(`Only the first ${MAX_BATCH_FILES} documents were considered.`);
    if (errors.length) setNotice({ message: errors.join(' '), type: 'error' });
    if (!accepted.length) return;

    setUploadOpen(true);
    if (accepted.length === 1) void prepareSingleFile(accepted[0]);
    else void processBatch(accepted);
  };

  const saveSingleDocument = async () => {
    let file = selectedFile;
    let prepared: PreparedDocument;
    let filename = sourceValue.trim() || selectedFile?.name || 'vault-note.md';
    if (!/\.[a-z0-9]+$/i.test(filename)) {
      const originalSuffix = selectedFile?.name.match(/\.[a-z0-9]+$/i)?.[0] ?? '.md';
      filename = `${filename}${originalSuffix}`;
    }

    if (!file) {
      if (!scanText.trim()) return;
      file = new File([scanText], filename, { type: 'text/markdown' });
      prepared = { method: 'local', markdown: scanText, format: 'md' };
    } else if (scanStage === 'ocr') {
      prepared = { method: 'ocr', markdown: '', format: 'ocr' };
    } else {
      if (!scanText.trim()) return;
      prepared = { method: 'local', markdown: scanText, format: 'markdown' };
    }

    setUploading(true);
    setScanStage('uploading');
    try {
      const document = await uploadPreparedDocument(file, filename, prepared);
      setDocuments((current) => [document, ...current]);
      setUploadOpen(false);
      resetUpload();
      setNotice({
        message: prepared.method === 'local'
          ? 'Document added with local AnyDoc extraction—no OCR charge.'
          : 'Document added. OCR is running in the background.',
        type: 'success',
      });
    } catch (error) {
      setUploading(false);
      setScanStage(prepared.method === 'ocr' ? 'ocr' : 'ready');
      setNotice({
        message: error instanceof Error ? error.message : 'Could not add document.',
        type: 'error',
      });
    }
  };

  const handleDrag = (e: React.DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
    if (e.type === "dragenter" || e.type === "dragover") {
      setIsDragActive(true);
    } else if (e.type === "dragleave") {
      setIsDragActive(false);
    }
  };

  const handleDrop = async (e: React.DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
    setIsDragActive(false);

    if (e.dataTransfer.files && e.dataTransfer.files.length > 0) {
      handleSelectedFiles(Array.from(e.dataTransfer.files));
    }
  };

  // Filtering for curated Profile view
  const getCategoryItems = (category: string) => {
    return context.filter(
      (item) =>
        (item.category || '').toLowerCase() === category &&
        item.type !== 'document' &&
        !item.supersededBy
    );
  };

  const getUngroupedItems = () => {
    return context.filter(
      (item) =>
        !categories.includes((item.category || '').toLowerCase()) &&
        item.type !== 'document' &&
        !item.supersededBy
    );
  };

  const curatedFactsCount = context.filter(
    (item) => item.type !== 'document' && !item.supersededBy
  ).length;
  const processingCount = documents.filter(
    (document) => document.status === 'pending' || document.status === 'processing',
  ).length;
  const localDocumentCount = documents.filter(
    (document) => document.processingMethod === 'local',
  ).length;

  const getLatestUpdateText = () => {
    let latestDate: Date | null = null;

    for (const item of activityItems) {
      if (item.updatedAt) {
        const d = new Date(item.updatedAt);
        if (!Number.isNaN(d.valueOf()) && (latestDate === null || d.getTime() > latestDate.getTime())) {
          latestDate = d;
        }
      }
    }

    for (const doc of documents) {
      if (doc.createdAt) {
        const d = new Date(doc.createdAt);
        if (!Number.isNaN(d.valueOf()) && (latestDate === null || d.getTime() > latestDate.getTime())) {
          latestDate = d;
        }
      }
    }

    if (latestDate === null) return 'recently';
    return timeAgo(latestDate.toISOString());
  };

  const guidanceTexts: Record<string, string> = {
    identity: 'No identity details saved yet. Add key details like your name or contact info.',
    education: 'No education history saved yet. Add details about your degrees or certifications.',
    experience: 'No professional experience saved yet. Add details about your past roles or skills.',
    preferences: 'No preferences saved yet. Add details about your job search preferences or requirements.'
  };

  return (
    <div className="vault-container">
      <header className="vault-hero">
        <div className="vault-hero-gradient" />
        <div className="vault-hero-glow" />
        <div className="vault-hero-content">
          <div className="vault-hero-copy">
            <div className="vault-hero-eyebrow"><Sparkles size={14} /> Personal knowledge</div>
            <h1>Your Vault</h1>
            <p>
              The facts, preferences, and documents Swara can use to understand you
              and complete the web without asking twice.
            </p>

            {!isLoading && (
              <div className="vault-stat-row">
                <span className="vault-stat vault-stat--indigo"><BookOpen size={16} /><strong>{curatedFactsCount}</strong> facts</span>
                <span className="vault-stat vault-stat--emerald"><FileText size={16} /><strong>{documents.length}</strong> documents</span>
                <span className="vault-stat vault-stat--amber"><Zap size={16} /><strong>{localDocumentCount}</strong> parsed locally</span>
              </div>
            )}
          </div>
          <button type="button" className="hero-action" onClick={openUpload}>
            <Plus size={16} /> Add content
          </button>
        </div>
        {!isLoading && <div className="vault-updated">Updated {getLatestUpdateText()}</div>}
      </header>

      {notice && (
        <Notice
          message={notice.message}
          type={notice.type}
          onDismiss={() => setNotice(null)}
        />
      )}

      {isLoading ? (
        <div className="loading-state">
          <div className="spinner"></div>
          <p>Loading personal vault...</p>
        </div>
      ) : (
        <div className="vault-grid">
          {/* Profile Section (Left Column) */}
          <section className="vault-column profile-section">
            <div className="column-header">
              <h2>Profile</h2>
              <p className="section-description">
                Curated facts and preferences available for auto-filling web forms.
              </p>
            </div>

            <div className="categories-list">
              {categories.map((cat) => (
                <CategorySection
                  key={cat}
                  title={cat}
                  items={getCategoryItems(cat)}
                  guidanceText={guidanceTexts[cat]}
                  onAddFact={handleAddFact}
                  onSaveFact={handleSaveFact}
                  onDeleteFact={handleDeleteFact}
                />
              ))}

              <OtherSection
                items={getUngroupedItems()}
                onSaveFact={handleSaveFact}
                onDeleteFact={handleDeleteFact}
              />
            </div>
          </section>

          {/* Sidebar Section (Right Column) */}
          <div className="vault-column sidebar-column">
            {/* Documents Section */}
            <section className="documents-section card-panel">
              <div className="panel-header">
                <div>
                  <h2>Document knowledge</h2>
                  <p className="section-description">
                    AnyDoc reads supported files locally. OCR runs only when a document truly needs it.
                  </p>
                </div>
                <button type="button" className="panel-action" onClick={openUpload}>
                  <Plus size={14} /> Add
                </button>
              </div>

              <input
                type="file"
                id="vault-quick-upload"
                multiple
                accept={DOCUMENT_ACCEPT}
                className="hidden-file-input"
                onChange={(event) => {
                  handleSelectedFiles(Array.from(event.target.files ?? []));
                  event.target.value = '';
                }}
              />
              <label
                htmlFor="vault-quick-upload"
                className={`drop-zone ${isDragActive ? 'drop-zone--active' : ''}`}
                onDragEnter={handleDrag}
                onDragOver={handleDrag}
                onDragLeave={handleDrag}
                onDrop={handleDrop}
              >
                <span className="drop-zone-icon"><UploadCloud size={20} /></span>
                <strong>Drop documents or click to browse</strong>
                <span className="drop-zone-sub">Up to 20 files · 20 MB each · local-first processing</span>
              </label>

              <div className="local-first-note">
                <ShieldCheck size={15} />
                <span>Readable content is extracted on-device before the original is stored.</span>
                {processingCount > 0 && <strong>{processingCount} processing</strong>}
              </div>

              <div className="documents-list">
                {documents.length === 0 ? (
                  <div className="empty-card">
                    <p className="empty-text">No documents uploaded yet.</p>
                    <p className="empty-subtext">Add files to derive automated context.</p>
                  </div>
                ) : (
                  documents.map((doc) => (
                    <DocumentRowComponent
                      key={doc.id}
                      document={doc}
                      contextItems={context}
                      onDelete={handleDeleteDocument}
                    />
                  ))
                )}
              </div>
            </section>

            {/* Activity Feed Section */}
            <section className="activity-section card-panel">
              <div className="panel-header">
                <h2>Recent Activity</h2>
                <p className="section-description">
                  History of modifications and auto-derived updates.
                </p>
              </div>

              <div className="activity-list">
                {activityItems.length === 0 ? (
                  <div className="empty-card">
                    <p className="empty-text">No activity recorded yet.</p>
                  </div>
                ) : (
                  activityItems.map((act) => (
                    <ActivityRowComponent key={act.id} activity={act} />
                  ))
                )}
              </div>
            </section>
          </div>
        </div>
      )}

      {uploadOpen && (
        <div className="modal-backdrop" role="presentation">
          <section className="upload-dialog" role="dialog" aria-modal="true" aria-labelledby="upload-dialog-title">
            <header className="upload-dialog-header">
              <div>
                <span className="dialog-eyebrow">Local-first ingestion</span>
                <h2 id="upload-dialog-title">Add content to your Vault</h2>
                <p>Review locally extracted content before saving. Scanned documents fall back to OCR.</p>
              </div>
              <button
                type="button"
                className="dialog-close"
                aria-label="Close upload dialog"
                disabled={uploading}
                onClick={() => { setUploadOpen(false); resetUpload(); }}
              >
                ✕
              </button>
            </header>

            <DocumentScanUpload
              fileName={scanFileName}
              stage={scanStage}
              text={scanText}
              fullText={scanFullText}
              sourceValue={sourceValue}
              batchProgress={batchProgress}
              locked={uploading && batchProgress !== null}
              onFilesSelected={handleSelectedFiles}
              onReset={resetUpload}
              onTextChange={setScanText}
              onSourceChange={setSourceValue}
            />

            <footer className="upload-dialog-footer">
              <span className="privacy-copy"><ShieldCheck size={14} /> AnyDoc runs inside this extension.</span>
              <div>
                <button
                  type="button"
                  className="button button--secondary"
                  disabled={uploading}
                  onClick={() => { setUploadOpen(false); resetUpload(); }}
                >
                  Cancel
                </button>
                <button
                  type="button"
                  className="button"
                  disabled={uploading || scanStage === 'local' || (scanStage !== 'ocr' && !scanText.trim())}
                  onClick={() => void saveSingleDocument()}
                >
                  {uploading
                    ? `Processing ${batchProgress?.current ?? 1} of ${batchProgress?.total ?? 1}`
                    : scanStage === 'ocr' ? 'Queue OCR' : 'Save to Vault'}
                </button>
              </div>
            </footer>
          </section>
        </div>
      )}
    </div>
  );
};

export function mountVault(root: HTMLElement) {
  root.className = 'vault-root';
  const reactRoot = createRoot(root);
  reactRoot.render(
    <React.StrictMode>
      <App />
    </React.StrictMode>
  );
}
