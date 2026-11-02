/**
 * Microphone permission page.
 *
 * Chrome will not surface the getUserMedia prompt inside a side panel, so the
 * panel sends the user here. Granting it once on this page persists for the
 * whole extension origin, and the panel's mic works from then on.
 */

const root = document.getElementById('root')!;

function render(state: 'idle' | 'granted' | 'denied' | 'error', detail = '') {
  const copy = {
    idle: {
      title: 'Microphone access',
      body: 'Swara needs your microphone to hear spoken instructions. Audio is sent to Sarvam for transcription and is not stored.',
      action: 'Allow microphone',
    },
    granted: {
      title: 'Microphone enabled',
      body: 'You can close this tab and use the mic button in the Swara panel.',
      action: '',
    },
    denied: {
      title: 'Access blocked',
      body:
        'Chrome is blocking the microphone for this extension. Open chrome://settings/content/microphone and remove any block for Swara, then reload this page. On macOS, also check System Settings → Privacy & Security → Microphone and confirm Chrome is enabled.',
      action: 'Try again',
    },
    error: {
      title: 'Could not access the microphone',
      body: detail || 'Something went wrong reaching the microphone.',
      action: 'Try again',
    },
  }[state];

  root.innerHTML = `
    <main class="card">
      <h1>${copy.title}</h1>
      <p>${copy.body}</p>
      ${copy.action ? `<button id="grant" type="button">${copy.action}</button>` : ''}
    </main>
  `;

  document.getElementById('grant')?.addEventListener('click', () => void request());
}

async function request() {
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    // Permission is what we came for; holding the mic open would leave the
    // recording indicator lit.
    stream.getTracks().forEach((track) => track.stop());
    render('granted');
  } catch (error) {
    const name = error instanceof DOMException ? error.name : '';
    if (name === 'NotAllowedError' || name === 'SecurityError') {
      render('denied');
      return;
    }
    render('error', error instanceof Error ? error.message : String(error));
  }
}

render('idle');

const style = document.createElement('style');
style.textContent = `
  :root { color-scheme: light dark; }
  body {
    margin: 0; min-height: 100vh; display: grid; place-items: center;
    font: 15px/1.6 -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
    background: #fafafa; color: #18181b; padding: 24px;
  }
  .card {
    max-width: 460px; background: #fff; padding: 32px;
    border: 1px solid #e4e4e7; border-radius: 12px;
  }
  h1 { margin: 0 0 12px; font-size: 20px; letter-spacing: -0.01em; }
  p { margin: 0 0 20px; color: #52525b; }
  button {
    font: inherit; font-weight: 500; padding: 9px 16px; cursor: pointer;
    color: #fff; background: #6d28d9; border: 0; border-radius: 8px;
  }
  button:hover { background: #5b21b6; }
  @media (prefers-color-scheme: dark) {
    body { background: #09090b; color: #fafafa; }
    .card { background: #18181b; border-color: #27272a; }
    p { color: #a1a1aa; }
  }
`;
document.head.append(style);
