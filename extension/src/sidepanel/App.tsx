import { type CSSProperties, type ChangeEvent, FormEvent, useEffect, useRef, useState } from 'react';
import {
  ArrowUp,
  BookOpen,
  Check,
  ChevronDown,
  CircleAlert,
  CircleDot,
  Download,
  Loader2,
  Mic,
  MicOff,
  MousePointer2,
  Pause,
  Play,
  ShieldCheck,
  SkipForward,
  Sparkles,
  Square,
  Trash2,
  Upload,
  WandSparkles,
} from 'lucide-react';
import { API_BASE_URL } from './api';
import { executeRoutedActions } from './actionRouting';
import {
  AUDIO_SAMPLE_RATE,
  SESSION_PATH,
  type AgentState,
  type ClientMessage,
  type ServerMessage,
} from '../types/session';
import type {
  Action,
  ActionResult,
  ContextUsage,
  PageContext,
  SwaraExecuteResultMessage,
  SwaraExtractResultMessage,
  SwaraBrowserActionResultMessage,
  SwaraMessage,
} from '../types';
import {
  WorkflowRecorder,
  createPageFingerprint,
  executeReplayStep,
  useLocalWorkflowLibrary,
  type LocalWorkflow,
  type WorkflowValues,
} from '../workflows';

/**
 * The panel shows only what Swara changed on the page. The conversation itself
 * is spoken, so transcribing it here would just be noise beside the voice; what
 * the user cannot verify by ear is which fields moved.
 */
type ConversationItem = {
  id: string;
  kind: 'actions';
  actions: Action[];
  results?: ActionResult[];
};

type ContextPanel = { relevant: ContextUsage[]; excluded: ContextUsage[] };
type PlaybackChunk = { data: string; mimeType: string };
type AgentActionBatch = Extract<ServerMessage, { type: 'agent.actions' }>;
type RunCommand = 'pause' | 'cancel' | 'skip';
type ActiveActionRun = {
  command: RunCommand | null;
  completion: Promise<void>;
  complete: () => void;
  freshPage?: PageContext;
};

function createActiveActionRun(): ActiveActionRun {
  let complete: () => void = () => {};
  const completion = new Promise<void>((resolve) => { complete = resolve; });
  return { command: null, completion, complete };
}

const MP3_MIME = 'audio/mpeg';
const PCM_MIME = 'audio/pcm';
/** Fallback when the server doesn't state a rate. */
const TTS_SAMPLE_RATE = 24_000;

/**
 * Plays raw 16 kHz PCM chunks gaplessly through Web Audio.
 *
 * Pipecat emits raw PCM rather than MP3, which MediaSource cannot accept. Each
 * chunk is scheduled against a running cursor rather than played on arrival,
 * so consecutive chunks butt up against each other instead of leaving audible
 * seams between them.
 */
class PcmPlayer {
  private ctx: AudioContext | null = null;
  private cursor = 0;
  private sources = new Set<AudioBufferSourceNode>();

  push(bytes: Uint8Array, rate: number) {
    // The agent speaks at a different rate than we capture at, so the context
    // follows the incoming audio rather than assuming the capture rate.
    if (!this.ctx) this.ctx = new AudioContext({ sampleRate: rate });
    const ctx = this.ctx;
    const samples = new Int16Array(
      bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
    );
    if (!samples.length) return;

    const buffer = ctx.createBuffer(1, samples.length, rate);
    const channel = buffer.getChannelData(0);
    for (let i = 0; i < samples.length; i += 1) channel[i] = samples[i] / 0x8000;

    const source = ctx.createBufferSource();
    source.buffer = buffer;
    source.connect(ctx.destination);
    // A small lead keeps scheduling ahead of playback when chunks arrive late.
    const startAt = Math.max(ctx.currentTime + 0.02, this.cursor);
    source.start(startAt);
    this.cursor = startAt + buffer.duration;
    this.sources.add(source);
    source.onended = () => this.sources.delete(source);
  }

  stop() {
    for (const source of this.sources) {
      try { source.stop(); } catch { /* already ended */ }
    }
    this.sources.clear();
    this.cursor = 0;
  }
}

/** Swallow the DOM exceptions MediaSource throws on races we can't prevent. */
function with_suppress(fn: () => void) {
  try { fn(); } catch { /* stream already torn down */ }
}

const makeSessionId = () =>
  typeof crypto.randomUUID === 'function'
    ? crypto.randomUUID()
    : `swara-${Date.now()}-${Math.random().toString(36).slice(2)}`;

const sessionUrl = () => `${API_BASE_URL.replace(/^http/, 'ws')}${SESSION_PATH}`;

function isPageContext(value: unknown): value is PageContext {
  return (
    typeof value === 'object' &&
    value !== null &&
    Array.isArray((value as PageContext).fields) &&
    typeof (value as PageContext).title === 'string'
  );
}

function extractPage(value: unknown): PageContext | null {
  if (isPageContext(value)) return value;
  const result = value as Partial<SwaraExtractResultMessage> | null;
  return result?.type === 'SWARA_EXTRACT_RESULT' && isPageContext(result.page) ? result.page : null;
}

function extractResults(value: unknown): ActionResult[] | null {
  if (Array.isArray(value)) return value as ActionResult[];
  const result = value as Partial<SwaraExecuteResultMessage> | null;
  return result?.type === 'SWARA_EXECUTE_RESULT' && Array.isArray(result.results) ? result.results : null;
}

function contentScriptError(message?: string): string {
  if (message?.toLowerCase().includes('receiving end')) {
    return 'Could not reach this page. Reload the tab, then try Swara again.';
  }
  return message ?? 'Could not reach this page. Reload the tab, then try Swara again.';
}

async function sendToTab(tabId: number, message: SwaraMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    chrome.tabs.sendMessage(tabId, message, (response: unknown) => {
      const lastError = chrome.runtime.lastError;
      if (lastError) {
        reject(new Error(contentScriptError(lastError.message)));
        return;
      }
      resolve(response);
    });
  });
}

async function browserAction(
  sessionId: string,
  sourceTabId: number,
  action: Action,
): Promise<ActionResult> {
  return new Promise((resolve, reject) => {
    chrome.runtime.sendMessage(
      { type: 'SWARA_BROWSER_ACTION', sessionId, sourceTabId, action } satisfies SwaraMessage,
      (response: unknown) => {
        const lastError = chrome.runtime.lastError;
        if (lastError) {
          reject(new Error(lastError.message));
          return;
        }
        const result = response as Partial<SwaraBrowserActionResultMessage> | null;
        if (result?.type !== 'SWARA_BROWSER_ACTION_RESULT' || !result.result) {
          reject(new Error('The browser returned an invalid navigation result.'));
          return;
        }
        resolve(result.result);
      },
    );
  });
}

async function openPermissionPage(): Promise<string | null> {
  const url = chrome.runtime.getURL('src/permission/index.html');
  try {
    await chrome.tabs.create({ url });
    return null;
  } catch (error) {
    return error instanceof Error ? error.message : `Could not open ${url}.`;
  }
}

async function openVaultPage(): Promise<string | null> {
  const url = chrome.runtime.getURL('src/vault/index.html');
  try {
    await chrome.tabs.create({ url });
    return null;
  } catch (error) {
    return error instanceof Error ? error.message : `Could not open ${url}.`;
  }
}

function toBase64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  const parts: string[] = [];
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    parts.push(String.fromCharCode(...bytes.subarray(offset, offset + 0x8000)));
  }
  return btoa(parts.join(''));
}

function fromBase64(value: string): Uint8Array {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

function actionSummary(actions: Action[], results?: ActionResult[]): string {
  const hasBrowserAction = actions.some((action) => [
    'open_url', 'navigate', 'open_tab', 'switch_tab', 'close_tab',
    'go_back', 'go_forward', 'wait_for_page',
  ].includes(action.action));
  const noun = hasBrowserAction ? 'action' : 'field';
  if (!results) return `Working on ${actions.length} ${actions.length === 1 ? noun : `${noun}s`}…`;
  const completed = results.filter((result) => result.ok).length;
  const verb = hasBrowserAction ? 'Completed' : 'Filled';
  return `${verb} ${completed} of ${results.length} ${results.length === 1 ? noun : `${noun}s`}`;
}

function browserActionTitle(action: Action): string {
  const titles: Partial<Record<Action['action'], string>> = {
    open_url: 'Opening a new page',
    open_tab: 'Opening a new tab',
    navigate: 'Navigating this tab',
    switch_tab: 'Switching tabs',
    close_tab: 'Closing the Swara tab',
    go_back: 'Going back',
    go_forward: 'Going forward',
    wait_for_page: 'Waiting for the page',
  };
  return titles[action.action] ?? 'Working in the browser';
}

function App() {
  const [sessionId] = useState(makeSessionId);
  const [agentState, setAgentState] = useState<AgentState>('idle');
  const [conversation, setConversation] = useState<ConversationItem[]>([]);
  const [partialTranscript, setPartialTranscript] = useState('');
  const [typedText, setTypedText] = useState('');
  const [context, setContext] = useState<ContextPanel>({ relevant: [], excluded: [] });
  const [audioLevel, setAudioLevel] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [needsMicPermission, setNeedsMicPermission] = useState(false);
  const [sessionOpen, setSessionOpen] = useState(false);
  const [agentRunActive, setAgentRunActive] = useState(false);
  const [runPaused, setRunPaused] = useState(false);
  const [activeBatchPresent, setActiveBatchPresent] = useState(false);
  const [isRecordingWorkflow, setIsRecordingWorkflow] = useState(false);
  const [workflowBusyId, setWorkflowBusyId] = useState<string | null>(null);
  const [workflowNotice, setWorkflowNotice] = useState<string | null>(null);
  const workflowLibrary = useLocalWorkflowLibrary(chrome.storage.local);

  const socketRef = useRef<WebSocket | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const audioContextRef = useRef<AudioContext | null>(null);
  const workletRef = useRef<AudioWorkletNode | null>(null);
  const silentGainRef = useRef<GainNode | null>(null);
  const playbackRef = useRef<HTMLAudioElement | null>(null);
  const playbackUrlRef = useRef<string | null>(null);
  const playbackQueueRef = useRef<PlaybackChunk[]>([]);
  const mediaSourceRef = useRef<MediaSource | null>(null);
  const sourceBufferRef = useRef<SourceBuffer | null>(null);
  const audioCompleteRef = useRef(false);
  const pcmPlayerRef = useRef<PcmPlayer>(new PcmPlayer());
  const activeActionRef = useRef<string | null>(null);
  const activeRunRef = useRef<ActiveActionRun | null>(null);
  const lastRunCompletionRef = useRef<Promise<void>>(Promise.resolve());
  const runPausedRef = useRef(false);
  const workflowRecorderRef = useRef<WorkflowRecorder | null>(null);
  const replayingWorkflowRef = useRef(false);
  const pageRef = useRef<PageContext | null>(null);
  /** Original user tab for this whole session; never follows an agent-opened tab. */
  const sessionSourceTabRef = useRef<number | null>(null);
  /** Current controlled tab, which may be a session-created tab after navigation. */
  const sessionActiveTabRef = useRef<number | null>(null);
  const startingRef = useRef(false);
  const agentStateRef = useRef<AgentState>('idle');
  const mountedRef = useRef(true);
  const transcriptEndRef = useRef<HTMLDivElement | null>(null);

  const send = (message: ClientMessage) => {
    const socket = socketRef.current;
    if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
  };

  const stopPlayback = () => {
    pcmPlayerRef.current.stop();
    playbackQueueRef.current = [];
    sourceBufferRef.current = null;
    mediaSourceRef.current = null;
    audioCompleteRef.current = false;
    const audio = playbackRef.current;
    if (audio) {
      audio.onended = null;
      audio.onerror = null;
      audio.pause();
      audio.removeAttribute('src');
      audio.load();
      playbackRef.current = null;
    }
    if (playbackUrlRef.current) {
      URL.revokeObjectURL(playbackUrlRef.current);
      playbackUrlRef.current = null;
    }
  };

  /**
   * Streams the agent's speech as it arrives.
   *
   * Two approaches were wrong before this one. An Audio element per chunk
   * stutters, because Sarvam sends MP3 frames rather than standalone files and
   * each element pays play() startup latency. Buffering the whole turn plays
   * smoothly but adds a dead pause before every reply, which is worse in
   * conversation than a little roughness.
   *
   * MediaSource gives both: append frames to one buffer as they land, so audio
   * starts on the first chunk and plays continuously.
   */
  const ensurePlaybackStream = () => {
    if (mediaSourceRef.current) return;
    if (typeof MediaSource === 'undefined' || !MediaSource.isTypeSupported(MP3_MIME)) {
      return; // falls back to buffered playback below
    }

    const mediaSource = new MediaSource();
    const url = URL.createObjectURL(mediaSource);
    const audio = new Audio(url);
    audio.autoplay = true;
    mediaSourceRef.current = mediaSource;
    playbackRef.current = audio;
    playbackUrlRef.current = url;

    mediaSource.addEventListener('sourceopen', () => {
      if (mediaSourceRef.current !== mediaSource) return;
      try {
        const buffer = mediaSource.addSourceBuffer(MP3_MIME);
        sourceBufferRef.current = buffer;
        buffer.addEventListener('updateend', drainPlaybackQueue);
        drainPlaybackQueue();
      } catch {
        teardownPlaybackStream();
      }
    }, { once: true });

    audio.onended = () => {
      if (playbackRef.current !== audio) return;
      teardownPlaybackStream();
    };

    void audio.play().catch(() => undefined);
  };

  const drainPlaybackQueue = () => {
    const buffer = sourceBufferRef.current;
    if (!buffer || buffer.updating) return;
    const chunk = playbackQueueRef.current.shift();
    if (!chunk) {
      // Only close the stream once every queued frame has been appended.
      if (audioCompleteRef.current && mediaSourceRef.current?.readyState === 'open') {
        with_suppress(() => mediaSourceRef.current!.endOfStream());
      }
      return;
    }
    const bytes = fromBase64(chunk.data);
    with_suppress(() =>
      buffer.appendBuffer(
        bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer,
      ),
    );
  };

  const teardownPlaybackStream = () => {
    sourceBufferRef.current = null;
    mediaSourceRef.current = null;
    audioCompleteRef.current = false;
  };

  const stopCapture = () => {
    workletRef.current?.disconnect();
    workletRef.current = null;
    silentGainRef.current?.disconnect();
    silentGainRef.current = null;
    streamRef.current?.getTracks().forEach((track) => track.stop());
    streamRef.current = null;
    const audioContext = audioContextRef.current;
    audioContextRef.current = null;
    if (audioContext && audioContext.state !== 'closed') void audioContext.close();
    if (mountedRef.current) setAudioLevel(0);
  };

  const endBrowserNavigationSession = () => {
    // Best-effort teardown; the worker removes the persisted tab allowlist so
    // a later Chrome tab-ID reuse can never inherit this session's authority.
    void chrome.runtime.sendMessage(
      { type: 'SWARA_BROWSER_SESSION_END', sessionId } satisfies SwaraMessage,
    ).catch(() => undefined);
    sessionSourceTabRef.current = null;
    sessionActiveTabRef.current = null;
  };

  const closeSession = (tellServer: boolean) => {
    startingRef.current = false;
    if (tellServer) send({ type: 'session.stop' });
    endBrowserNavigationSession();
    socketRef.current?.close();
    socketRef.current = null;
    stopCapture();
    stopPlayback();
    activeActionRef.current = null;
    if (activeRunRef.current) activeRunRef.current.command = 'cancel';
    activeRunRef.current = null;
    runPausedRef.current = false;
    if (mountedRef.current) {
      setSessionOpen(false);
      setAgentState('idle');
      setAgentRunActive(false);
      setRunPaused(false);
      setActiveBatchPresent(false);
      setPartialTranscript('');
    }
  };

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      closeSession(true);
    };
  }, []);

  useEffect(() => {
    agentStateRef.current = agentState;
  }, [agentState]);

  useEffect(() => {
    transcriptEndRef.current?.scrollIntoView({ block: 'end', behavior: 'smooth' });
  }, [conversation, partialTranscript]);

  const updateActionResults = (id: string, results: ActionResult[]) => {
    setConversation((items) =>
      items.map((item) => (item.kind === 'actions' && item.id === id ? { ...item, results } : item)),
    );
  };

  const routedActions = async (
    actions: Action[],
    options: {
      initialTabId: number;
      sourceTabId: number;
      navigationSessionId: string;
      step: { current: number; total: number };
      shouldContinue?: () => boolean;
      interruptionReason?: () => string;
    },
  ) => executeRoutedActions(actions, {
    initialTabId: options.initialTabId,
    allowBrowserNavigation: pageRef.current?.capabilities?.includes('browserNavigation') === true,
    shouldContinue: options.shouldContinue,
    interruptionReason: options.interruptionReason,
    executeDomActions: async (tabId, domActions) => {
      const response = await sendToTab(tabId, { type: 'SWARA_EXECUTE', actions: domActions });
      const domResults = extractResults(response);
      if (!domResults) throw new Error('The page returned an invalid action result. Try reloading the tab.');
      return domResults;
    },
    executeBrowserAction: async (action) => {
      const beforeTabId = sessionActiveTabRef.current ?? options.initialTabId;
      const title = browserActionTitle(action);
      await sendToTab(beforeTabId, {
        type: 'SWARA_OVERLAY_STATUS',
        status: 'executing',
        step: options.step,
        title,
        reason: action.reasoning,
      }).catch(() => undefined);
      try {
        const result = await browserAction(
          options.navigationSessionId,
          options.sourceTabId,
          action,
        );
        const resultTabId = result.verification?.tabId ?? beforeTabId;
        await sendToTab(resultTabId, {
          type: 'SWARA_OVERLAY_STATUS',
          status: result.ok ? 'success' : 'failure',
          step: options.step,
          title: result.ok ? 'Browser action completed' : 'Browser action failed',
          reason: result.error ?? action.reasoning,
        }).catch(() => undefined);
        return result;
      } catch (cause) {
        await sendToTab(beforeTabId, {
          type: 'SWARA_OVERLAY_STATUS',
          status: 'failure',
          step: options.step,
          title: 'Browser action failed',
          reason: cause instanceof Error ? cause.message : 'Could not control the browser.',
        }).catch(() => undefined);
        throw cause;
      }
    },
  });

  const executeActions = async (batch: AgentActionBatch) => {
    const { actions } = batch;
    const id = `actions-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const run = createActiveActionRun();
    activeRunRef.current = run;
    lastRunCompletionRef.current = run.completion;
    activeActionRef.current = id;
    setAgentRunActive(true);
    setActiveBatchPresent(true);
    setConversation((items) => [...items, { id, kind: 'actions', actions }]);
    setAgentState('acting');
    try {
      const sourceTabId = sessionSourceTabRef.current;
      if (sourceTabId === null) throw new Error('The original session tab is no longer available. Start a new session.');
      const activeTabId = sessionActiveTabRef.current;
      if (activeTabId === null) throw new Error('The current session tab is no longer available. Start a new session.');
      const pageBeforeActions = pageRef.current;
      const routed = await routedActions(actions, {
        initialTabId: activeTabId,
        sourceTabId,
        navigationSessionId: sessionId,
        step: { current: batch.step, total: batch.maxSteps },
        shouldContinue: () => run.command === null,
        interruptionReason: () => ({
          pause: 'Paused before this action started.',
          cancel: 'Cancelled before this action started.',
          skip: 'Skipped before this action started.',
        }[run.command ?? 'pause']),
      });
      const results = routed.results;
      sessionActiveTabRef.current = routed.activeTabId;
      updateActionResults(id, results);

      if (workflowRecorderRef.current && !replayingWorkflowRef.current && pageBeforeActions) {
        actions.forEach((action, index) => {
          const result = results[index];
          if (!result?.ok) return;
          try {
            workflowRecorderRef.current?.record({
              action,
              result,
              precondition: createPageFingerprint(pageBeforeActions),
              target: pageBeforeActions.controls.find((control) => control.controlId === action.fieldId),
            });
          } catch {
            // Unsafe, secret-bearing, or unverified actions are deliberately
            // omitted; the live action result remains visible to the user.
          }
        });
      }

      if (run.command === 'cancel') return;
      // Advancing is conditional on fresh context from the exact tab resolved
      // by routing. Never substitute pageRef here: it may describe the tab
      // before navigation and would let the agent act on stale state.
      let page: PageContext | null;
      try {
        const response = await sendToTab(routed.activeTabId, { type: 'SWARA_EXTRACT' });
        page = extractPage(response);
      } catch (error) {
        closeSession(true);
        throw error;
      }
      if (!page) {
        closeSession(true);
        throw new Error('Could not verify the updated page. Reload the tab, then start a new session.');
      }
      pageRef.current = page;
      run.freshPage = page;
      // Cancel and skip invalidate the pending server batch. Pause is
      // different: report every finished/not-started action as evidence, then
      // let the server hold the run until an explicit resume.
      if (run.command !== 'skip') {
        send({ type: 'agent.observation', batchId: batch.batchId, results, page });
      }
    } catch (actionError) {
      const failed = actions.map((action) => ({
        fieldId: action.fieldId,
        ok: false,
        error: actionError instanceof Error ? actionError.message : 'Could not complete this action.',
      }));
      updateActionResults(id, failed);
      setError(actionError instanceof Error ? actionError.message : 'Unable to act on this page.');
      setAgentState('error');
    } finally {
      activeActionRef.current = null;
      run.complete();
      if (activeRunRef.current === run) activeRunRef.current = null;
      setActiveBatchPresent(false);
    }
  };

  const extractControlledPage = async (): Promise<PageContext> => {
    const tabId = sessionActiveTabRef.current;
    if (tabId === null) throw new Error('The current session tab is no longer available.');
    const response = await sendToTab(tabId, { type: 'SWARA_EXTRACT' });
    const page = extractPage(response);
    if (!page) throw new Error('Could not verify the current page. Reload the tab, then try again.');
    pageRef.current = page;
    return page;
  };

  const pauseRun = () => {
    if (!agentRunActive || runPausedRef.current) return;
    const active = activeRunRef.current;
    if (active && active.command === null) active.command = 'pause';
    runPausedRef.current = true;
    setRunPaused(true);
    stopPlayback();
    send({ type: 'agent.pause' });
  };

  const resumeRun = async () => {
    if (!runPausedRef.current) return;
    setError(null);
    try {
      // If pause landed during an action, let that one action finish and its
      // atomic evidence reach the server before supplying the resume snapshot.
      await lastRunCompletionRef.current;
      const page = await extractControlledPage();
      runPausedRef.current = false;
      setRunPaused(false);
      setAgentRunActive(true);
      send({ type: 'agent.resume', page });
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not resume this run.');
    }
  };

  const cancelRun = () => {
    const active = activeRunRef.current;
    if (active && active.command === null) active.command = 'cancel';
    runPausedRef.current = false;
    setRunPaused(false);
    setAgentRunActive(false);
    setActiveBatchPresent(false);
    stopPlayback();
    send({ type: 'agent.cancel' });
  };

  const skipCurrentBatch = async () => {
    const active = activeRunRef.current;
    if (!active || active.command !== null) return;
    active.command = 'skip';
    setError(null);
    try {
      // Wait for a currently executing reversible action to settle; every
      // later action is suppressed by the cooperative router boundary.
      await active.completion;
      const page = active.freshPage ?? await extractControlledPage();
      send({ type: 'agent.skip', page });
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not skip this step safely.');
    }
  };

  const startWorkflowRecording = () => {
    const id = `workflow_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
    const name = `Workflow ${new Date().toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' })}`;
    workflowRecorderRef.current = new WorkflowRecorder(id, name);
    setIsRecordingWorkflow(true);
    setWorkflowNotice('Recording verified actions. Secrets and unsafe clicks are excluded.');
  };

  const stopWorkflowRecording = async () => {
    const recorder = workflowRecorderRef.current;
    workflowRecorderRef.current = null;
    setIsRecordingWorkflow(false);
    if (!recorder) return;
    const workflow = recorder.finish();
    if (workflow.actions.length === 0) {
      setWorkflowNotice('Nothing was saved because no safe action completed while recording.');
      return;
    }
    try {
      await workflowLibrary.save(workflow);
      setWorkflowNotice(`Saved “${workflow.name}” locally.`);
    } catch (cause) {
      setWorkflowNotice(cause instanceof Error ? cause.message : 'Could not save this workflow.');
    }
  };

  const replayWorkflow = async (workflow: LocalWorkflow) => {
    if (sessionOpen || agentRunActive || workflowBusyId) return;
    setWorkflowBusyId(workflow.id);
    setWorkflowNotice(null);
    replayingWorkflowRef.current = true;
    const navigationSessionId = `workflow-run-${makeSessionId()}`;
    try {
      const values: WorkflowValues = {};
      for (const variable of workflow.variables) {
        const value = window.prompt(
          variable.sensitive ? `${variable.label} (used once; not saved)` : variable.label,
          variable.defaultValue ?? '',
        );
        if (value === null) {
          setWorkflowNotice('Workflow replay cancelled.');
          return;
        }
        (values as Record<string, string>)[variable.key] = value;
      }

      const [sourceTab] = await chrome.tabs.query({ active: true, currentWindow: true });
      if (sourceTab?.id === undefined) throw new Error('No active tab is available.');
      let activeTabId = sourceTab.id;
      sessionSourceTabRef.current = sourceTab.id;
      sessionActiveTabRef.current = activeTabId;
      let page = await extractControlledPage();

      for (const [index] of workflow.actions.entries()) {
        pageRef.current = page;
        const routed = await executeReplayStep({
          workflow,
          index,
          page,
          values,
          userInitiated: true,
          routing: {
            initialTabId: activeTabId,
            allowBrowserNavigation: page.capabilities?.includes('browserNavigation') === true,
            executeDomActions: async (tabId, domActions) => {
              const response = await sendToTab(tabId, { type: 'SWARA_EXECUTE', actions: domActions });
              const results = extractResults(response);
              if (!results) throw new Error('The page returned an invalid action result.');
              return results;
            },
            executeBrowserAction: (action) => browserAction(
              navigationSessionId,
              sourceTab.id!,
              action,
            ),
          },
        });
        const result = routed.results[0];
        if (!result?.ok) throw new Error(result?.error ?? `Workflow step ${index + 1} failed.`);
        activeTabId = routed.activeTabId;
        sessionActiveTabRef.current = activeTabId;
        page = await extractControlledPage();
      }
      setWorkflowNotice(`Finished “${workflow.name}” and verified every step.`);
    } catch (cause) {
      setWorkflowNotice(cause instanceof Error ? cause.message : 'Workflow replay failed.');
    } finally {
      replayingWorkflowRef.current = false;
      setWorkflowBusyId(null);
      void chrome.runtime.sendMessage(
        { type: 'SWARA_BROWSER_SESSION_END', sessionId: navigationSessionId } satisfies SwaraMessage,
      ).catch(() => undefined);
      if (!sessionOpen) {
        sessionSourceTabRef.current = null;
        sessionActiveTabRef.current = null;
      }
    }
  };

  const exportLocalWorkflow = (workflow: LocalWorkflow) => {
    try {
      const serialized = workflowLibrary.exportJson(workflow.id);
      const url = URL.createObjectURL(new Blob([serialized], { type: 'application/json' }));
      const link = document.createElement('a');
      link.href = url;
      link.download = `${workflow.id}.swara-workflow.json`;
      link.click();
      URL.revokeObjectURL(url);
    } catch (cause) {
      setWorkflowNotice(cause instanceof Error ? cause.message : 'Could not export this workflow.');
    }
  };

  const importLocalWorkflow = async (event: ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    event.target.value = '';
    if (!file) return;
    try {
      const workflow = await workflowLibrary.importJson(await file.text());
      setWorkflowNotice(`Imported “${workflow.name}” locally.`);
    } catch (cause) {
      setWorkflowNotice(cause instanceof Error ? cause.message : 'Could not import this workflow.');
    }
  };

  const deleteLocalWorkflow = async (workflow: LocalWorkflow) => {
    if (!window.confirm(`Delete “${workflow.name}” from this browser?`)) return;
    try {
      await workflowLibrary.remove(workflow.id);
      setWorkflowNotice(`Deleted “${workflow.name}” from local storage.`);
    } catch (cause) {
      setWorkflowNotice(cause instanceof Error ? cause.message : 'Could not delete this workflow.');
    }
  };

  const handleServerMessage = (message: ServerMessage) => {
    switch (message.type) {
      case 'state':
        setAgentState(message.state);
        if (message.state === 'acting') setAgentRunActive(true);
        if (
          (message.state === 'idle' || message.state === 'listening')
          && !runPausedRef.current
        ) {
          setAgentRunActive(false);
        }
        return;
      case 'speech.start':
        stopPlayback();
        send({ type: 'agent.interrupt' });
        return;
      case 'agent.audio.end':
        audioCompleteRef.current = true;
        drainPlaybackQueue();
        return;
      case 'speech.end':
        return;
      case 'transcript.partial':
        return;
      case 'transcript.final':
        setPartialTranscript('');
        runPausedRef.current = false;
        setRunPaused(false);
        setAgentRunActive(false);
        return;
      case 'agent.text':
        // Spoken, not written. The panel is for verifying page changes.
        return;
      case 'agent.question':
        // The question is already inside the spoken text; rendering it again
        // showed every question twice.
        return;
      case 'agent.audio':
        if (message.mimeType.startsWith(PCM_MIME)) {
          const rate = Number(/rate=(\d+)/.exec(message.mimeType)?.[1]) || TTS_SAMPLE_RATE;
          pcmPlayerRef.current.push(fromBase64(message.data), rate);
          return;
        }
        playbackQueueRef.current.push({ data: message.data, mimeType: message.mimeType });
        ensurePlaybackStream();
        drainPlaybackQueue();
        return;
      case 'agent.actions':
        void executeActions(message);
        return;
      case 'memory.learned':
        return;
      case 'context.used':
        setContext({ relevant: message.relevant, excluded: message.excluded });
        return;
      case 'error':
        setError(message.message);
        setAgentState('error');
        setAgentRunActive(false);
        if (message.fatal) closeSession(false);
        return;
    }
  };

  const startCapture = async () => {
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        // Without echo cancellation the microphone hears the agent's own
        // speech and transcribes it as the user talking, so the agent
        // interrupts and answers itself. The other two keep room noise and
        // distance from being heard as words.
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true,
        channelCount: 1,
        sampleRate: AUDIO_SAMPLE_RATE,
      },
    });
    if (!mountedRef.current) {
      stream.getTracks().forEach((track) => track.stop());
      return;
    }

    // Ask the browser for 16 kHz directly. Chrome resamples the microphone with
    // a proper anti-aliasing filter; doing it ourselves by interpolating
    // between samples folds everything above 8 kHz back into the speech band as
    // noise, which is heard by the recogniser as garbled consonants and
    // phantom words.
    const audioContext = new AudioContext({ sampleRate: AUDIO_SAMPLE_RATE });
    try {
      // Served verbatim from public/ at a stable, unhashed path. Vite's
      // `new URL('./worklet.ts', import.meta.url)` emits a content-hashed
      // asset, which MV3 then gates behind web_accessible_resources and which
      // changes name every build — a fragile dependency for something whose
      // failure silently disables the microphone.
      await audioContext.audioWorklet.addModule(chrome.runtime.getURL('worklet.js'));
      const source = audioContext.createMediaStreamSource(stream);
      const worklet = new AudioWorkletNode(audioContext, 'swara-pcm-capture', {
        processorOptions: { targetSampleRate: AUDIO_SAMPLE_RATE },
      });
      const silentGain = audioContext.createGain();
      silentGain.gain.value = 0;
      source.connect(worklet);
      worklet.connect(silentGain);
      silentGain.connect(audioContext.destination);
      worklet.port.onmessage = (event: MessageEvent<{ type: 'chunk' | 'level'; data: ArrayBuffer | number }>) => {
        if (event.data.type === 'chunk' && event.data.data instanceof ArrayBuffer) {
          send({ type: 'audio.chunk', data: toBase64(event.data.data) });
        }
        if (event.data.type === 'level' && typeof event.data.data === 'number') setAudioLevel(event.data.data);
      };
      streamRef.current = stream;
      audioContextRef.current = audioContext;
      workletRef.current = worklet;
      silentGainRef.current = silentGain;
      await audioContext.resume();
    } catch (captureError) {
      stream.getTracks().forEach((track) => track.stop());
      await audioContext.close();
      throw new Error(
        `Microphone capture could not start because the AudioWorklet failed to load. ${
          captureError instanceof Error ? captureError.message : ''
        }`.trim(),
      );
    }
  };

  const startSession = async () => {
    if (sessionOpen || startingRef.current) {
      startingRef.current = false;
      closeSession(true);
      return;
    }
    startingRef.current = true;
    setError(null);
    setNeedsMicPermission(false);
    setAgentState('connecting');
    try {
      await startCapture();
      if (!startingRef.current) return;
      const [sourceTab] = await chrome.tabs.query({ active: true, currentWindow: true });
      if (sourceTab?.id === undefined) throw new Error('No active tab is available.');
      sessionSourceTabRef.current = sourceTab.id;
      sessionActiveTabRef.current = sourceTab.id;
      const response = await sendToTab(sourceTab.id, { type: 'SWARA_EXTRACT' });
      if (!startingRef.current) return;
      const page = extractPage(response);
      if (!page) throw new Error('The page returned an invalid scan result. Reload the tab, then try again.');
      pageRef.current = page;

      const socket = new WebSocket(sessionUrl());
      socketRef.current = socket;
      socket.onopen = () => {
        startingRef.current = false;
        socket.send(JSON.stringify({ type: 'session.start', sessionId, page } satisfies ClientMessage));
        if (mountedRef.current) setSessionOpen(true);
      };
      socket.onmessage = (event: MessageEvent<string>) => {
        try {
          handleServerMessage(JSON.parse(event.data) as ServerMessage);
        } catch {
          setError('The session sent an unreadable response. Please start a new session.');
          setAgentState('error');
        }
      };
      socket.onerror = () => {
        startingRef.current = false;
        setError('Could not connect to the Swara session server.');
        setAgentState('error');
      };
      socket.onclose = () => {
        startingRef.current = false;
        endBrowserNavigationSession();
        if (!mountedRef.current) return;
        setSessionOpen(false);
        if (agentStateRef.current !== 'error') setAgentState('idle');
      };
    } catch (startError) {
      startingRef.current = false;
      stopCapture();
      const name = startError instanceof DOMException ? startError.name : '';
      const blocked = name === 'NotAllowedError' || name === 'SecurityError';
      setNeedsMicPermission(blocked);
      setError(
        blocked
          ? 'Chrome will not ask for microphone access from inside a side panel.'
          : startError instanceof Error
            ? startError.message
            : 'Unable to start Swara.',
      );
      setAgentState('error');
    }
  };

  const submitTypedTurn = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const text = typedText.trim();
    if (!text || !sessionOpen) return;
    runPausedRef.current = false;
    setRunPaused(false);
    setAgentRunActive(false);
    send({ type: 'text.turn', text });
    setTypedText('');
  };

  return (
    <main className={`app app--${agentState}`}>
      <section className="workspace-hero">
        <header className="app-header">
          <div className="brand-lockup">
            <span className="brand-mark" aria-hidden="true"><Sparkles size={16} strokeWidth={2.1} /></span>
            <div>
              <p className="brand-eyebrow">Voice workspace</p>
              <h1>Swara</h1>
            </div>
          </div>
          <button className="vault-link" type="button" onClick={() => void openVaultPage()}>
            <BookOpen size={14} aria-hidden="true" />
            <span>Vault</span>
          </button>
        </header>

        <div className="voice-stage">
          <div className={`agent-state agent-state--${agentState}`} aria-live="polite">
            <span className="state-dot" aria-hidden="true" />
            <span>{stateLabel(agentState)}</span>
          </div>

          <div className="voice-orb" aria-hidden="true">
            <span className="orb-halo orb-halo--outer" />
            <span className="orb-halo orb-halo--inner" />
            <span className="orb-core">
              {agentState === 'connecting' || agentState === 'thinking' || agentState === 'acting'
                ? <Loader2 size={25} className="orb-spinner" />
                : sessionOpen ? <Mic size={25} /> : <Sparkles size={25} />}
            </span>
          </div>

          <div className="voice-copy">
            <h2>{stateHeading(agentState, sessionOpen)}</h2>
            <p>{stateDescription(agentState, sessionOpen)}</p>
          </div>

          {agentState === 'listening' && (
            <div className="listening-feedback" aria-label="Swara is listening">
              <span className="level-bars" style={{ '--level': Math.max(0.06, audioLevel).toString() } as CSSProperties}>
                <i /><i /><i /><i /><i />
              </span>
            </div>
          )}

          <button
            className={`mic-button${sessionOpen ? ' mic-button--active' : ''}`}
            type="button"
            onClick={() => void startSession()}
            aria-pressed={sessionOpen}
          >
            {sessionOpen ? <MicOff size={16} aria-hidden="true" /> : <Mic size={16} aria-hidden="true" />}
            <span>{sessionOpen ? 'End session' : 'Start voice session'}</span>
          </button>

          {sessionOpen && agentRunActive && (
            <div className="run-controls" aria-label="Agent run controls">
              <button
                type="button"
                className="run-control run-control--primary"
                onClick={runPaused ? () => void resumeRun() : pauseRun}
              >
                {runPaused ? <Play size={13} aria-hidden="true" /> : <Pause size={13} aria-hidden="true" />}
                <span>{runPaused ? 'Resume' : 'Pause'}</span>
              </button>
              <button
                type="button"
                className="run-control"
                onClick={() => void skipCurrentBatch()}
                disabled={!activeBatchPresent || runPaused}
                title={activeBatchPresent ? 'Skip the current action batch' : 'No action batch to skip'}
              >
                <SkipForward size={13} aria-hidden="true" />
                <span>Skip</span>
              </button>
              <button type="button" className="run-control run-control--danger" onClick={cancelRun}>
                <Square size={12} aria-hidden="true" />
                <span>Cancel</span>
              </button>
            </div>
          )}

          <div className="trust-note">
            <ShieldCheck size={13} aria-hidden="true" />
            <span>Swara never submits, sends, pays, or deletes for you</span>
          </div>
        </div>
      </section>

      {error && (
        <div className="error" role="alert">
          <CircleAlert size={16} aria-hidden="true" />
          <div>
            <p>{error}</p>
            {needsMicPermission && (
              <button type="button" className="permission-button" onClick={() => void openPermissionPage()}>
                Grant microphone access
              </button>
            )}
          </div>
        </div>
      )}

      <section className="activity-section" aria-label="Changes Swara made to this page">
        <div className="section-heading">
          <div>
            <p className="section-eyebrow">Current page</p>
            <h2>Page changes</h2>
          </div>
          {conversation.length > 0 && <span className="change-count">{conversation.length}</span>}
        </div>

        <div className="conversation">
          {conversation.length === 0 && (
            <div className="conversation-empty">
              <span className="empty-icon" aria-hidden="true"><MousePointer2 size={18} /></span>
              <div>
                <h3>No changes yet</h3>
                <p>Ask Swara to fill, select, or open something. Each page action will appear here.</p>
              </div>
            </div>
          )}
          {conversation.map((item) => <ConversationItemView key={item.id} item={item} />)}
          <div ref={transcriptEndRef} />
        </div>
      </section>

      <details className="workflow-sidecar">
        <summary>
          <span><Play size={14} aria-hidden="true" />Local workflows</span>
          <span className="workflow-summary-meta">
            {workflowLibrary.workflows.length || ''}
            <ChevronDown size={14} aria-hidden="true" />
          </span>
        </summary>
        <div className="workflow-toolbar">
          <button
            type="button"
            className={isRecordingWorkflow ? 'workflow-record workflow-record--active' : 'workflow-record'}
            onClick={isRecordingWorkflow ? () => void stopWorkflowRecording() : startWorkflowRecording}
          >
            {isRecordingWorkflow ? <Square size={12} aria-hidden="true" /> : <CircleDot size={13} aria-hidden="true" />}
            {isRecordingWorkflow ? 'Stop & save' : 'Record actions'}
          </button>
          <label className="workflow-import">
            <Upload size={12} aria-hidden="true" />Import
            <input type="file" accept="application/json,.json" onChange={(event) => void importLocalWorkflow(event)} />
          </label>
        </div>
        {workflowNotice && <p className="workflow-notice" role="status">{workflowNotice}</p>}
        {workflowLibrary.error && <p className="workflow-notice workflow-notice--error">{workflowLibrary.error}</p>}
        {!workflowLibrary.loading && workflowLibrary.workflows.length === 0 && (
          <p className="workflow-empty">Record a safe browser task once, then replay it locally without using the Vault or server storage.</p>
        )}
        <div className="workflow-list">
          {workflowLibrary.workflows.map((workflow) => (
            <article className="workflow-item" key={workflow.id}>
              <div>
                <strong>{workflow.name}</strong>
                <span>{workflow.actions.length} {workflow.actions.length === 1 ? 'step' : 'steps'} · local only</span>
              </div>
              <div className="workflow-actions">
                <button
                  type="button"
                  onClick={() => void replayWorkflow(workflow)}
                  disabled={Boolean(workflowBusyId) || agentRunActive || sessionOpen}
                  title={sessionOpen ? 'End the voice session before replaying a workflow' : 'Run workflow'}
                  aria-label={`Run ${workflow.name}`}
                >
                  {workflowBusyId === workflow.id ? <Loader2 size={12} className="artifact-spinner" /> : <Play size={12} />}
                </button>
                <button type="button" onClick={() => exportLocalWorkflow(workflow)} aria-label={`Export ${workflow.name}`}>
                  <Download size={12} />
                </button>
                <button type="button" onClick={() => void deleteLocalWorkflow(workflow)} aria-label={`Delete ${workflow.name}`}>
                  <Trash2 size={12} />
                </button>
              </div>
            </article>
          ))}
        </div>
      </details>

      <form className="text-turn" onSubmit={submitTypedTurn}>
        <div className="composer-shell">
          <WandSparkles size={16} aria-hidden="true" />
          <label className="sr-only" htmlFor="typed-turn">Send a typed message</label>
          <input
            id="typed-turn"
            value={typedText}
            onChange={(event) => setTypedText(event.target.value)}
            disabled={!sessionOpen}
            placeholder={sessionOpen ? 'Or type a request…' : 'Start a session to type'}
          />
          <button type="submit" disabled={!sessionOpen || !typedText.trim()} aria-label="Send request">
            <ArrowUp size={15} aria-hidden="true" />
          </button>
        </div>
      </form>

      {(context.relevant.length > 0 || context.excluded.length > 0) && (
        <details className="reasoning-sidecar">
          <summary><span><ShieldCheck size={14} aria-hidden="true" />Context used</span><ChevronDown size={14} aria-hidden="true" /></summary>
          <ContextList title="Relevant" items={context.relevant} />
          <ContextList title="Excluded" items={context.excluded} excluded />
        </details>
      )}
    </main>
  );
}

function stateLabel(state: AgentState): string {
  return {
    connecting: 'Connecting',
    idle: 'Ready',
    listening: 'Listening',
    thinking: 'Thinking',
    speaking: 'Speaking',
    acting: 'Acting',
    error: 'Needs attention',
  }[state];
}

function stateHeading(state: AgentState, sessionOpen: boolean): string {
  if (!sessionOpen && state === 'idle') return 'Ready when you are';
  return {
    connecting: 'Opening your workspace',
    idle: 'Session is ready',
    listening: 'I’m listening',
    thinking: 'Working it out',
    speaking: 'Here’s what I found',
    acting: 'Making the change',
    error: 'Let’s fix that',
  }[state];
}

function stateDescription(state: AgentState, sessionOpen: boolean): string {
  if (!sessionOpen && state === 'idle') return 'Speak naturally. Swara understands the page and uses your Vault when it helps.';
  return {
    connecting: 'Reading the current page and preparing a private voice session.',
    idle: 'Say what you want to do, or type a request below.',
    listening: 'Tell me what you want to change on this page.',
    thinking: 'Matching your request with this page and your Vault.',
    speaking: 'You can interrupt at any time and keep the conversation moving.',
    acting: 'Applying the requested action and checking the result.',
    error: 'Review the message below, then try the session again.',
  }[state];
}

function ConversationItemView({ item }: { item: ConversationItem }) {
  const done = Boolean(item.results);
  return (
    <article className={`turn-artifact action-artifact${done ? ' action-artifact--done' : ''}`}>
      <span className="artifact-icon" aria-hidden="true">
        {done ? <Check size={14} /> : <Loader2 size={14} className="artifact-spinner" />}
      </span>
      <div>
        <p>{actionSummary(item.actions, item.results)}</p>
        <span className="artifact-meta">{done ? 'Checked on the page' : 'In progress'}</span>
        {item.results && <ActionResults results={item.results} />}
      </div>
    </article>
  );
}

function ActionResults({ results }: { results: ActionResult[] }) {
  const failures = results.filter((result) => !result.ok);
  const healed = results.filter((result) => result.ok && result.healed);
  if (failures.length === 0 && healed.length === 0) return null;
  const notes = [
    ...failures.map((result) => result.error || `${result.fieldId} could not be filled`),
    ...healed.map((result) => `Recovered ${result.fieldId} after the page changed${
      result.healingConfidence === undefined ? '' : ` (${Math.round(result.healingConfidence * 100)}% match)`
    }`),
  ];
  return <small className={failures.length ? undefined : 'action-evidence'}>{notes.join(' · ')}</small>;
}

function ContextList({ title, items, excluded = false }: { title: string; items: ContextUsage[]; excluded?: boolean }) {
  if (!items.length) return null;
  return (
    <section className={excluded ? 'context-list context-list--excluded' : 'context-list'}>
      <h2>{title}</h2>
      {items.map((item) => <p key={`${item.key}-${item.reason}`}><strong>{item.key}</strong><span>{item.summary} · {item.reason}</span></p>)}
    </section>
  );
}

export default App;
