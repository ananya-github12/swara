import type { Action, ActionResult } from '../types';

const MAX_URL_LENGTH = 2_048;

export type BrowserTab = {
  id?: number;
  url?: string;
  title?: string;
  status?: string;
};

export type BrowserNavigationApi = {
  getTab: (tabId: number) => Promise<BrowserTab>;
  createTab: (options: { url: string; active: boolean }) => Promise<BrowserTab>;
  updateTab: (tabId: number, options: { url?: string; active?: boolean }) => Promise<BrowserTab>;
  removeTab: (tabId: number) => Promise<void>;
  goBack: (tabId: number) => Promise<void>;
  goForward: (tabId: number) => Promise<void>;
  waitForComplete: (tabId: number, timeoutMs: number) => Promise<boolean>;
};

type NavigationSession = {
  sourceTabId: number;
  activeTabId: number;
  /** Tabs opened by this exact run. Source tabs are never included. */
  createdTabIds: Set<number>;
};

export type NavigationSessionSnapshot = {
  sourceTabId: number;
  activeTabId: number;
  createdTabIds: number[];
};

export type NavigationSessionStore = {
  get: (sessionId: string) => Promise<NavigationSessionSnapshot | undefined>;
  set: (sessionId: string, session: NavigationSessionSnapshot) => Promise<void>;
  remove: (sessionId: string) => Promise<void>;
};

export function safeNavigationUrl(value: string): string {
  const candidate = value.trim();
  if (!candidate || candidate.length > MAX_URL_LENGTH) {
    throw new Error('Navigation requires a valid URL.');
  }

  let url: URL;
  try {
    url = new URL(candidate);
  } catch {
    throw new Error('Navigation requires a complete http or https URL.');
  }

  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) {
    throw new Error('Only credential-free http and https URLs can be opened.');
  }
  return url.toString();
}

function tabIdFromAction(value: string): number {
  if (!/^\d+$/.test(value.trim())) {
    throw new Error('Tab actions require a valid tab identifier.');
  }
  const tabId = Number(value);
  if (!Number.isSafeInteger(tabId) || tabId <= 0) {
    throw new Error('Tab actions require a valid tab identifier.');
  }
  return tabId;
}

function isBrowserAction(action: Action): boolean {
  return [
    'open_url',
    'navigate',
    'open_tab',
    'switch_tab',
    'close_tab',
    'go_back',
    'go_forward',
    'wait_for_page',
  ].includes(action.action);
}

/**
 * Owns only the tabs created during one Swara run. This lives in the service
 * worker so a model cannot turn an action into arbitrary tab control.
 */
export class BrowserNavigationController {
  private readonly sessions = new Map<string, NavigationSession>();

  constructor(
    private readonly api: BrowserNavigationApi,
    private readonly store?: NavigationSessionStore,
  ) {}

  async execute(
    sessionId: string,
    sourceTabId: number,
    action: Action,
  ): Promise<ActionResult> {
    if (!isBrowserAction(action)) {
      return this.failure(action, 'This is not a browser navigation action.');
    }

    try {
      const session = await this.session(sessionId, sourceTabId);
      let tab: BrowserTab;
      let navigated = false;

      switch (action.action) {
        case 'open_url':
        case 'open_tab': {
          const url = safeNavigationUrl(action.value);
          tab = await this.api.createTab({ url, active: true });
          if (tab.id === undefined) throw new Error('Chrome did not return the opened tab.');
          session.createdTabIds.add(tab.id);
          session.activeTabId = tab.id;
          await this.persist(sessionId, session);
          navigated = true;
          break;
        }
        case 'navigate': {
          const url = safeNavigationUrl(action.value);
          tab = await this.api.updateTab(session.activeTabId, { url, active: true });
          navigated = true;
          break;
        }
        case 'switch_tab': {
          const tabId = tabIdFromAction(action.value);
          this.assertControlledTab(session, tabId);
          tab = await this.api.updateTab(tabId, { active: true });
          session.activeTabId = tabId;
          await this.persist(sessionId, session);
          break;
        }
        case 'close_tab': {
          const tabId = tabIdFromAction(action.value);
          // Never close the user's original tab; only a tab this run created
          // may be closed. It also prevents the run from closing its last tab.
          if (!session.createdTabIds.has(tabId)) {
            throw new Error('Refused: Swara can only close a tab opened during this run.');
          }
          await this.api.removeTab(tabId);
          session.createdTabIds.delete(tabId);
          if (session.activeTabId === tabId) session.activeTabId = session.sourceTabId;
          await this.api.updateTab(session.activeTabId, { active: true });
          await this.persist(sessionId, session);
          tab = await this.api.getTab(session.activeTabId);
          break;
        }
        case 'go_back':
          await this.api.goBack(session.activeTabId);
          tab = await this.api.getTab(session.activeTabId);
          navigated = true;
          break;
        case 'go_forward':
          await this.api.goForward(session.activeTabId);
          tab = await this.api.getTab(session.activeTabId);
          navigated = true;
          break;
        case 'wait_for_page':
          tab = await this.api.getTab(session.activeTabId);
          break;
        default:
          return this.failure(action, 'Unsupported browser navigation action.');
      }

      if (tab.id === undefined) throw new Error('Chrome did not return the target tab.');
      const ready = await this.api.waitForComplete(tab.id, 10_000);
      // Re-read after navigation so the result is an observation, not merely
      // an acknowledgement that Chrome accepted the command.
      const verified = await this.api.getTab(tab.id);
      return {
        fieldId: action.fieldId,
        ok: true,
        verification: {
          tabId: tab.id,
          url: verified.url ?? tab.url,
          title: verified.title ?? tab.title,
          ready,
          navigated,
        },
      };
    } catch (error) {
      return this.failure(
        action,
        error instanceof Error ? error.message : 'Could not navigate the browser.',
      );
    }
  }

  /** Remove a completed run's tab allowlist before Chrome can recycle IDs. */
  async end(sessionId: string): Promise<void> {
    this.sessions.delete(sessionId);
    await this.store?.remove(sessionId);
  }

  private async session(sessionId: string, sourceTabId: number): Promise<NavigationSession> {
    const existing = this.sessions.get(sessionId);
    if (existing) {
      if (existing.sourceTabId !== sourceTabId) {
        throw new Error('Refused: this navigation session belongs to another tab.');
      }
      return existing;
    }

    const stored = await this.store?.get(sessionId);
    if (stored) {
      if (stored.sourceTabId !== sourceTabId) {
        throw new Error('Refused: this navigation session belongs to another tab.');
      }
      const hydrated: NavigationSession = {
        sourceTabId: stored.sourceTabId,
        activeTabId: stored.activeTabId,
        createdTabIds: new Set(stored.createdTabIds),
      };
      // Ensure a stale storage entry cannot turn into control of a reused ID.
      await this.api.getTab(hydrated.sourceTabId);
      await this.api.getTab(hydrated.activeTabId);
      this.sessions.set(sessionId, hydrated);
      return hydrated;
    }

    await this.api.getTab(sourceTabId);
    const session: NavigationSession = {
      sourceTabId,
      activeTabId: sourceTabId,
      createdTabIds: new Set(),
    };
    this.sessions.set(sessionId, session);
    await this.persist(sessionId, session);
    return session;
  }

  private async persist(sessionId: string, session: NavigationSession): Promise<void> {
    await this.store?.set(sessionId, {
      sourceTabId: session.sourceTabId,
      activeTabId: session.activeTabId,
      createdTabIds: [...session.createdTabIds],
    });
  }

  private assertControlledTab(session: NavigationSession, tabId: number): void {
    if (tabId !== session.sourceTabId && !session.createdTabIds.has(tabId)) {
      throw new Error('Refused: this tab is outside the current Swara run.');
    }
  }

  private failure(action: Action, error: string): ActionResult {
    return { fieldId: action.fieldId, ok: false, error };
  }
}
