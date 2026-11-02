import type { SwaraOverlayStatus, SwaraOverlayStep } from '../types';

/**
 * A page-local, non-interactive progress indicator for browser actions.
 *
 * The overlay is deliberately rendered in an isolated shadow root and uses
 * `pointer-events: none` everywhere. It never becomes part of a form, never
 * takes focus, and does not listen for keyboard or pointer events. The target
 * is outlined by a fixed viewport rectangle instead of changing its styles,
 * which avoids affecting framework-managed pages.
 */

export type ActionOverlayStatus = SwaraOverlayStatus;
export type ActionOverlayStep = SwaraOverlayStep;

export type ActionOverlayOptions = {
  target?: HTMLElement | null;
  status: ActionOverlayStatus;
  step?: ActionOverlayStep;
  reason?: string;
  title?: string;
};

const HOST_ID = 'swara-action-overlay';
const STATUS_LABEL: Record<ActionOverlayStatus, string> = {
  waiting: 'Waiting',
  executing: 'Working',
  success: 'Done',
  failure: 'Could not complete',
  confirmation: 'Your confirmation needed',
};

function clampStep(step?: ActionOverlayStep): ActionOverlayStep | undefined {
  if (!step || !Number.isFinite(step.current) || !Number.isFinite(step.total)) {
    return undefined;
  }
  const total = Math.max(1, Math.floor(step.total));
  return { current: Math.min(total, Math.max(1, Math.floor(step.current))), total };
}

function isVisibleTarget(target?: HTMLElement | null): target is HTMLElement {
  return Boolean(target?.isConnected && target.getClientRects().length);
}

/**
 * Owns one overlay instance for a content-document. Consumers may update it
 * freely while executing a run and must call destroy when their run ends.
 */
export class ActionOverlay {
  private readonly host: HTMLDivElement;
  private readonly shadow: ShadowRoot;
  private readonly targetRing: HTMLDivElement;
  private readonly card: HTMLDivElement;
  private readonly statusNode: HTMLDivElement;
  private readonly stepNode: HTMLElement;
  private readonly reasonNode: HTMLDivElement;
  private target?: HTMLElement;
  private observer?: ResizeObserver;
  private mutationObserver?: MutationObserver;
  private hideTimer?: number;
  private destroyed = false;
  private readonly reposition = () => this.position();

  constructor(private readonly doc: Document = document) {
    // A fresh content script can be injected after an extension reload. Remove
    // only our own stale host, never arbitrary page elements.
    this.doc.getElementById(HOST_ID)?.remove();

    this.host = this.doc.createElement('div');
    this.host.id = HOST_ID;
    this.host.setAttribute('aria-hidden', 'true');
    this.host.style.cssText = [
      'all: initial',
      'position: fixed',
      'inset: 0',
      'z-index: 2147483647',
      'pointer-events: none',
      'contain: strict',
    ].join(';');
    this.shadow = this.host.attachShadow({ mode: 'open' });

    const style = this.doc.createElement('style');
    style.textContent = `
      :host { all: initial; }
      .ring, .card { box-sizing: border-box; position: fixed; pointer-events: none; }
      .ring { border: 2px solid #7c3aed; border-radius: 7px; box-shadow: 0 0 0 4px rgb(124 58 237 / 20%); }
      .card { max-width: min(340px, calc(100vw - 32px)); padding: 10px 12px; border-radius: 10px; background: #18181b; color: #fafafa; font: 500 13px/1.35 system-ui, sans-serif; box-shadow: 0 8px 24px rgb(0 0 0 / 28%); }
      .meta { display: flex; gap: 8px; align-items: center; color: #d4d4d8; }
      .dot { width: 8px; height: 8px; border-radius: 50%; background: #a78bfa; flex: 0 0 auto; }
      .title { margin-top: 4px; color: #fafafa; font-weight: 650; }
      .reason { margin-top: 3px; color: #d4d4d8; font-weight: 400; }
      [data-status="success"] .ring { border-color: #22c55e; box-shadow: 0 0 0 4px rgb(34 197 94 / 20%); }
      [data-status="success"] .dot { background: #4ade80; }
      [data-status="failure"] .ring { border-color: #ef4444; box-shadow: 0 0 0 4px rgb(239 68 68 / 20%); }
      [data-status="failure"] .dot { background: #f87171; }
      [data-status="confirmation"] .ring { border-color: #f59e0b; box-shadow: 0 0 0 4px rgb(245 158 11 / 20%); }
      [data-status="confirmation"] .dot { background: #fbbf24; }
      @media (prefers-reduced-motion: no-preference) {
        .ring, .card { transition: top 140ms ease-out, left 140ms ease-out, width 140ms ease-out, height 140ms ease-out, opacity 140ms ease-out; }
      }
    `;
    this.targetRing = this.doc.createElement('div');
    this.targetRing.className = 'ring';
    this.card = this.doc.createElement('div');
    this.card.className = 'card';
    this.statusNode = this.doc.createElement('div');
    this.statusNode.className = 'meta';
    const dot = this.doc.createElement('span');
    dot.className = 'dot';
    this.stepNode = this.doc.createElement('span');
    this.statusNode.append(dot, this.stepNode);
    const title = this.doc.createElement('div');
    title.className = 'title';
    this.reasonNode = this.doc.createElement('div');
    this.reasonNode.className = 'reason';
    this.card.append(this.statusNode, title, this.reasonNode);
    this.shadow.append(style, this.targetRing, this.card);

    (this.doc.documentElement ?? this.doc.body).append(this.host);
    this.host.dataset.status = 'waiting';
    this.hideTarget();
    this.hideCard();
    this.doc.defaultView?.addEventListener('scroll', this.reposition, true);
    this.doc.defaultView?.addEventListener('resize', this.reposition);
    // SPAs can replace or move the target without a browser navigation. Watch
    // page content (not our host under <html>) so the ring either follows the
    // target or disappears as soon as it is detached.
    const MutationObserverCtor = this.doc.defaultView?.MutationObserver;
    if (MutationObserverCtor && this.doc.body) {
      this.mutationObserver = new MutationObserverCtor(this.reposition);
      this.mutationObserver.observe(this.doc.body, { childList: true, subtree: true });
    }
  }

  show(options: ActionOverlayOptions): void {
    if (this.destroyed) return;
    this.clearHideTimer();
    this.target = isVisibleTarget(options.target) ? options.target : undefined;
    this.host.dataset.status = options.status;
    const step = clampStep(options.step);
    this.stepNode.textContent = `${STATUS_LABEL[options.status]}${step ? ` · Step ${step.current} of ${step.total}` : ''}`;
    const title = this.card.querySelector<HTMLElement>('.title');
    if (title) title.textContent = options.title ?? 'Swara is working on this page';
    this.reasonNode.textContent = options.reason ?? '';
    this.reasonNode.hidden = !options.reason;
    this.card.style.opacity = '1';
    this.position();
    this.observeTarget();
  }

  hide(): void {
    if (this.destroyed) return;
    this.clearHideTimer();
    this.target = undefined;
    this.observer?.disconnect();
    this.observer = undefined;
    this.hideTarget();
    this.hideCard();
  }

  /** Keep terminal feedback visible briefly, then leave no page chrome behind. */
  hideAfter(delayMs = 1_600): void {
    if (this.destroyed) return;
    this.clearHideTimer();
    const view = this.doc.defaultView;
    if (!view) return;
    this.hideTimer = view.setTimeout(() => this.hide(), Math.max(0, delayMs));
  }

  destroy(): void {
    if (this.destroyed) return;
    this.destroyed = true;
    this.clearHideTimer();
    this.observer?.disconnect();
    this.mutationObserver?.disconnect();
    this.doc.defaultView?.removeEventListener('scroll', this.reposition, true);
    this.doc.defaultView?.removeEventListener('resize', this.reposition);
    this.host.remove();
  }

  private observeTarget(): void {
    this.observer?.disconnect();
    const ResizeObserverCtor = this.doc.defaultView?.ResizeObserver;
    if (this.target && ResizeObserverCtor) {
      this.observer = new ResizeObserverCtor(this.reposition);
      this.observer.observe(this.target);
    }
  }

  private position(): void {
    if (this.destroyed) return;
    if (!isVisibleTarget(this.target)) {
      this.hideTarget();
      this.positionCard(undefined);
      return;
    }
    const rect = this.target.getBoundingClientRect();
    const padding = 4;
    this.targetRing.style.left = `${Math.max(0, rect.left - padding)}px`;
    this.targetRing.style.top = `${Math.max(0, rect.top - padding)}px`;
    this.targetRing.style.width = `${Math.max(0, rect.width + padding * 2)}px`;
    this.targetRing.style.height = `${Math.max(0, rect.height + padding * 2)}px`;
    this.targetRing.style.opacity = '1';
    this.positionCard(rect);
  }

  private positionCard(rect?: DOMRect): void {
    const view = this.doc.defaultView;
    const viewportWidth = view?.innerWidth ?? 0;
    const viewportHeight = view?.innerHeight ?? 0;
    const margin = 12;
    const cardWidth = this.card.offsetWidth || 260;
    const cardHeight = this.card.offsetHeight || 70;
    const preferredTop = rect ? rect.bottom + margin : margin;
    const top = Math.max(margin, Math.min(preferredTop, Math.max(margin, viewportHeight - cardHeight - margin)));
    const preferredLeft = rect ? rect.left : margin;
    const left = Math.max(margin, Math.min(preferredLeft, Math.max(margin, viewportWidth - cardWidth - margin)));
    this.card.style.left = `${left}px`;
    this.card.style.top = `${top}px`;
  }

  private hideTarget(): void {
    this.targetRing.style.opacity = '0';
    this.targetRing.style.width = '0';
    this.targetRing.style.height = '0';
  }

  private hideCard(): void {
    this.card.style.opacity = '0';
  }

  private clearHideTimer(): void {
    if (this.hideTimer === undefined) return;
    this.doc.defaultView?.clearTimeout(this.hideTimer);
    this.hideTimer = undefined;
  }
}

let activeOverlay: ActionOverlay | undefined;

/** Returns the document's shared overlay, creating it only when needed. */
export function getActionOverlay(): ActionOverlay {
  if (!activeOverlay) activeOverlay = new ActionOverlay();
  return activeOverlay;
}

/** Removes the shared overlay, for page teardown and tests. */
export function destroyActionOverlay(): void {
  activeOverlay?.destroy();
  activeOverlay = undefined;
}
