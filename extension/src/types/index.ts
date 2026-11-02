/**
 * Shared contract types for Swara.
 *
 * This file is the single source of truth for the extension side. The server
 * mirrors it in `server/schemas.py` — change both together or the two halves
 * silently disagree.
 */

/* ------------------------------------------------------------------ *
 * Page / form extraction (content script -> side panel -> server)
 * ------------------------------------------------------------------ */

export type FieldType =
  | 'text'
  | 'textarea'
  | 'select'
  | 'checkbox'
  | 'radio'
  | 'contenteditable';

export type AssistantCapability =
  | 'readablePageText'
  | 'contentEditableFill'
  | 'openUrl'
  | 'browserNavigation';

export type FieldOption = {
  /** The value actually submitted, i.e. the element's `value` attribute. */
  value: string;
  /** Human-readable option text, for the LLM to reason over. */
  label: string;
};

export type FormField = {
  /**
   * Stable identifier the executor uses to find this element again.
   * Derivation order: element `id` -> element `name` -> `<tag>:<index>`.
   * Radio and checkbox groups share one id (their common `name`).
   */
  fieldId: string;
  /** Cleaned label text, with asterisks/aria-hidden/hint nodes stripped. */
  label: string;
  /**
   * The semantic question being asked. Usually the label; for radio and
   * checkbox groups it is the `<fieldset><legend>` text, since the individual
   * `<label>`s belong to the options, not the question.
   */
  question: string;
  type: FieldType;
  required: boolean;
  /** Populated for select, radio, and checkbox-group fields. Empty otherwise. */
  options: FieldOption[];
  placeholder?: string;
  maxLength?: number;
  /** Whatever is already in the field, so the planner can avoid clobbering it. */
  currentValue?: string;
};

export type PageControl = {
  /** Stable identifier the executor uses to find this control again. */
  controlId: string;
  /** Cleaned visible text, with accessible fallbacks when it has none. */
  label: string;
  role: 'button' | 'link' | 'tab' | 'submit';
  disabled: boolean;
};

export type PageContext = {
  url: string;
  title: string;
  /** The page's main heading, e.g. the job title. Useful planner context. */
  heading?: string;
  /** Visible page prose for summarisation and question-answering. */
  readableText?: string;
  /** Additive features supported by this extension build. */
  capabilities?: AssistantCapability[];
  fields: FormField[];
  controls: PageControl[];
};

/* ------------------------------------------------------------------ *
 * Actions (server -> side panel -> content script)
 * ------------------------------------------------------------------ */

export type ActionType =
  | 'fill'
  | 'select'
  | 'check'
  | 'uncheck'
  | 'clear'
  | 'click'
  | 'scroll_to'
  /** @deprecated Use `open_tab`; kept so existing plans continue to work. */
  | 'open_url'
  | 'navigate'
  | 'open_tab'
  | 'switch_tab'
  | 'close_tab'
  | 'go_back'
  | 'go_forward'
  | 'wait_for_page';

export type Action = {
  fieldId: string;
  action: ActionType;
  /**
   * For `fill`: the literal text. For `select`/`check`/`uncheck`: the option
   * `value` to act on. For `clear`: ignored.
   */
  value: string;
  /** Short human-readable justification, shown in the preview UI. */
  reasoning?: string;
};

export type ActionResult = {
  fieldId: string;
  ok: boolean;
  error?: string;
  /** The exact target disappeared, but one unique semantic match was recovered. */
  healed?: boolean;
  /** Deterministic target-match score in the inclusive range 0..1. */
  healingConfidence?: number;
  /**
   * Browser state verified after a navigation action. Optional so older
   * server responses and DOM-only actions retain their existing wire shape.
   */
  verification?: {
    tabId?: number;
    url?: string;
    title?: string;
    ready?: boolean;
    navigated?: boolean;
  };
};

/* ------------------------------------------------------------------ *
 * Memory classification — the product's differentiator
 * ------------------------------------------------------------------ */

/**
 * `fact`        — a durable truth about the user ("I worked at HyperVerge")
 * `correction`  — supersedes an existing fact ("2026, not 2025")
 * `preference`  — how they want output written ("keep it concise")
 * `instruction` — a constraint on this task only ("don't mention my startup")
 */
export type MemoryType = 'fact' | 'correction' | 'preference' | 'instruction';

export type MemoryScope = 'persistent' | 'session' | 'task';

export type MemoryUpdate = {
  type: MemoryType;
  key: string;
  value: string;
  /** Set on corrections: what this replaces. */
  oldValue?: string;
  scope: MemoryScope;
  /** Why the classifier chose this type/scope. Surfaced in the UI. */
  reason: string;
};

/* ------------------------------------------------------------------ *
 * Planning
 * ------------------------------------------------------------------ */

/** A context item the planner considered, for transparency in the UI. */
export type ContextUsage = {
  key: string;
  summary: string;
  /** Why it was used, or why it was ruled out. */
  reason: string;
};

export type PlanRequest = {
  sessionId: string;
  page: PageContext;
  /** The user's instruction, whether typed or transcribed from speech. */
  instruction: string;
};

/**
 * Sent once the user accepts a plan. Memory is committed on confirmation, not
 * at plan time — the preview promises what will be remembered, so nothing is
 * written until the user agrees.
 */
export type MemoryApplyRequest = {
  sessionId: string;
  memoryUpdates: MemoryUpdate[];
};

export type PlanResponse = {
  status: 'ready' | 'needs_clarification';
  actions: Action[];
  clarifications: string[];
  memoryUpdates: MemoryUpdate[];
  /** Fields the planner deliberately left alone, with a reason. */
  unresolved: string[];
  relevantContext: ContextUsage[];
  excludedContext: ContextUsage[];
  /** One or two sentences suitable for reading aloud over TTS. */
  spokenSummary: string;
};

/* ------------------------------------------------------------------ *
 * Voice
 * ------------------------------------------------------------------ */

/** Sarvam language codes. "unknown" lets Saarika auto-detect code-switching. */
export type SarvamLanguage =
  | 'unknown'
  | 'en-IN'
  | 'hi-IN'
  | 'ta-IN'
  | 'te-IN'
  | 'kn-IN'
  | 'ml-IN'
  | 'mr-IN'
  | 'bn-IN'
  | 'gu-IN'
  | 'pa-IN'
  | 'od-IN';

export type TranscriptResponse = {
  transcript: string;
  /** What Saarika reported detecting, when it says. */
  language?: string;
};

export type SpeechRequest = {
  text: string;
  /** Always send one explicitly — leaving it unset skews pronunciation. */
  language: SarvamLanguage;
};

export type SpeechResponse = {
  /** base64-encoded audio, ready for a data: URL. */
  audioBase64: string;
  mimeType: string;
};

/* ------------------------------------------------------------------ *
 * Extension-internal messaging
 * ------------------------------------------------------------------ */

export type SwaraPingMessage = { type: 'SWARA_PING' };
export type SwaraPongMessage = {
  type: 'SWARA_PONG';
  url: string;
  title: string;
};
export type SwaraExtractMessage = { type: 'SWARA_EXTRACT' };
export type SwaraExtractResultMessage = {
  type: 'SWARA_EXTRACT_RESULT';
  page: PageContext;
};
export type SwaraExecuteMessage = {
  type: 'SWARA_EXECUTE';
  actions: Action[];
};
export type SwaraExecuteResultMessage = {
  type: 'SWARA_EXECUTE_RESULT';
  results: ActionResult[];
};
/**
 * A visual-only instruction for the content script. Browser actions use this
 * to keep their progress visible in the tab without exposing page controls.
 */
export type SwaraOverlayStatus =
  | 'waiting'
  | 'executing'
  | 'success'
  | 'failure'
  | 'confirmation';
export type SwaraOverlayStep = { current: number; total: number };
export type SwaraOverlayStatusMessage = {
  type: 'SWARA_OVERLAY_STATUS';
  status: SwaraOverlayStatus;
  step?: SwaraOverlayStep;
  title?: string;
  reason?: string;
  /** Optional extracted field/control identifier to draw a target ring for. */
  fieldId?: string;
};

/** Browser-level actions are deliberately handled by the service worker. */
export type SwaraBrowserActionMessage = {
  type: 'SWARA_BROWSER_ACTION';
  /** Isolates a run's controlled tabs from every other Swara session. */
  sessionId: string;
  /** The user-visible tab from which this run began. */
  sourceTabId: number;
  action: Action;
};
export type SwaraBrowserActionResultMessage = {
  type: 'SWARA_BROWSER_ACTION_RESULT';
  result: ActionResult;
};
export type SwaraBrowserSessionEndMessage = {
  type: 'SWARA_BROWSER_SESSION_END';
  sessionId: string;
};

export type SwaraMessage =
  | SwaraPingMessage
  | SwaraPongMessage
  | SwaraExtractMessage
  | SwaraExtractResultMessage
  | SwaraExecuteMessage
  | SwaraExecuteResultMessage
  | SwaraOverlayStatusMessage
  | SwaraBrowserActionMessage
  | SwaraBrowserActionResultMessage
  | SwaraBrowserSessionEndMessage;
