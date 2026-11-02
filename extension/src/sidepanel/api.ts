import type { MemoryApplyRequest, PlanRequest, PlanResponse, SpeechRequest, SpeechResponse, TranscriptResponse } from '../types';
import { createChromePkceAuth, supabaseExtensionConfig } from '../auth';

// 8000 is a common default and was already taken on the dev machine; 8787 keeps
// Swara out of the way of whatever else is running locally.
export const API_BASE_URL = 'http://localhost:8787';

let authClient: ReturnType<typeof createChromePkceAuth> | undefined;

export function extensionAuth() {
  if (!authClient) authClient = createChromePkceAuth(supabaseExtensionConfig());
  return authClient;
}

/** Authenticated requests to the local server never carry a service key. */
export async function authenticatedServerRequest(path: string, options: RequestInit = {}): Promise<Response> {
  const token = await extensionAuth().getAccessToken();
  if (!token) throw new Error('Sign in to use Swara.');
  const headers = new Headers(options.headers);
  headers.set('Authorization', `Bearer ${token}`);
  headers.set('X-Client-Info', 'swara-extension');
  return fetch(`${API_BASE_URL}${path}`, { ...options, headers });
}

async function serverError(response: Response): Promise<Error> {
  let message = `Server request failed (${response.status}).`;

  try {
    const body: unknown = await response.json();
    if (typeof body === 'object' && body !== null) {
      const detail = (body as Record<string, unknown>).detail;
      const bodyMessage = (body as Record<string, unknown>).message;
      if (typeof detail === 'string') message = detail;
      if (typeof bodyMessage === 'string') message = bodyMessage;
    }
  } catch {
    const text = await response.text().catch(() => '');
    if (text) message = text;
  }

  return new Error(message);
}

export async function getHealth(): Promise<void> {
  const response = await fetch(`${API_BASE_URL}/health`);
  if (!response.ok) throw await serverError(response);
}

export async function postPlan(request: PlanRequest): Promise<PlanResponse> {
  void request;
  throw new Error('The legacy planner route has been retired; use the authenticated session flow.');
}

export async function postSpeechToText(blob: Blob, language = 'unknown'): Promise<TranscriptResponse> {
  const formData = new FormData();
  formData.append('file', blob, 'recording.webm');
  formData.append('language', language);

  const response = await fetch(`${API_BASE_URL}/voice/stt`, {
    method: 'POST',
    body: formData,
  });

  if (!response.ok) throw await serverError(response);
  return (await response.json()) as TranscriptResponse;
}

export async function postTextToSpeech(request: SpeechRequest): Promise<SpeechResponse> {
  const response = await fetch(`${API_BASE_URL}/voice/tts`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(request),
  });

  if (!response.ok) throw await serverError(response);
  return (await response.json()) as SpeechResponse;
}

export async function postMemoryApply(request: MemoryApplyRequest): Promise<unknown> {
  void request;
  throw new Error('The legacy memory route has been retired; use authenticated Vault corrections.');
}
