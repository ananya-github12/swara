/**
 * Live voice-session protocol.
 *
 * Mirrored by `server/session_schemas.py` — change both together.
 *
 * The session is a single WebSocket carrying JSON control messages in both
 * directions plus base64 audio. Audio is base64 inside JSON rather than binary
 * frames so one ordered stream carries everything and a chunk can never
 * overtake the state change that explains it.
 *
 * ## Audio format (this is not negotiable)
 *
 * Sarvam's streaming STT accepts wav / pcm_s16le / pcm_l16 / pcm_raw at 16 kHz.
 * It does NOT accept webm/opus, so `MediaRecorder` cannot be used here — the
 * client must capture raw PCM via an AudioWorklet, downsample from the
 * browser's native rate (typically 48 kHz) to 16 kHz, convert Float32 to
 * Int16, and base64 it. Getting this wrong is silent: the socket connects and
 * simply never transcribes.
 */

import type { Action, ActionResult, ContextUsage, MemoryUpdate, PageContext } from './index';

/** Where the agent is in the turn cycle. Drives the whole UI. */
export type AgentState =
  | 'connecting'
  | 'idle'
  | 'listening'
  | 'thinking'
  | 'speaking'
  | 'acting'
  | 'error';

export const AUDIO_SAMPLE_RATE = 16_000;

/**
 * The session endpoint, kept here rather than in either half's code — stating
 * it separately in two places is how the client ends up dialling a path the
 * server never mounted.
 */
export const SESSION_PATH = '/session/live';

/* ---------------------------- client -> server ---------------------------- */

export type ClientMessage =
  /** Opens the session. The page is sent up front so the agent can speak first. */
  | { type: 'session.start'; sessionId: string; page: PageContext }
  /** Base64 Int16 PCM at 16 kHz, ~20-100ms per chunk. */
  | { type: 'audio.chunk'; data: string }
  /** Typed input; bypasses STT but takes the same turn path. */
  | { type: 'text.turn'; text: string }
  /** Results of actions the agent asked for, so it can confirm honestly. */
  | { type: 'action.result'; results: ActionResult[] }
  /** Page changed (navigation, multi-step advance) — replaces the agent's view. */
  | { type: 'page.update'; page: PageContext }
  /** Atomic evidence for one specific agent action batch. */
  | { type: 'agent.observation'; batchId: string; results: ActionResult[]; page: PageContext }
  /** Explicit run controls. These are never inferred from a voice turn. */
  | { type: 'agent.pause' }
  | { type: 'agent.resume'; page: PageContext }
  | { type: 'agent.cancel' }
  | { type: 'agent.skip'; page: PageContext }
  /** User pressed stop while the agent was speaking. */
  | { type: 'agent.interrupt' }
  | { type: 'session.stop' };

/* ---------------------------- server -> client ---------------------------- */

export type ServerMessage =
  | { type: 'state'; state: AgentState }
  /** Sarvam VAD boundaries. `speech.start` should duck any playing audio. */
  | { type: 'speech.start' }
  | { type: 'speech.end' }
  /** Interim transcript, replaced as it firms up. */
  | { type: 'transcript.partial'; text: string }
  | { type: 'transcript.final'; text: string; language?: string }
  /** What the agent is saying, emitted before its audio so text leads voice. */
  | { type: 'agent.text'; text: string }
  /** Base64 WAV/PCM chunk of the agent's speech. */
  | { type: 'agent.audio'; data: string; mimeType: string }
  | { type: 'agent.audio.end' }
  /**
   * One bounded action batch. The panel must reply with one matching atomic
   * observation containing freshly extracted page context.
   */
  | { type: 'agent.actions'; batchId: string; step: number; maxSteps: number; actions: Action[] }
  /** The agent asked something and is waiting. Purely informational for the UI. */
  | { type: 'agent.question'; text: string }
  /** Memory the agent committed this turn. */
  | { type: 'memory.learned'; updates: MemoryUpdate[] }
  /** Reasoning transparency, for the sidecar panel. */
  | { type: 'context.used'; relevant: ContextUsage[]; excluded: ContextUsage[] }
  | { type: 'error'; message: string; fatal: boolean };
