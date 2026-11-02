# Swara

Swara is a voice-native personal context layer for the web. It combines three inputs — the current webpage's visible structure, a natural-language voice instruction from the user, and a persistent personal context vault — to produce structured browser actions against the fields on the current page. The goal is to let users complete any web form as naturally as speaking aloud, without repeatedly re-entering the same personal details.

Swara is a bounded browser agent rather than an unrestricted autonomous one. It
can continue a task across pages and tabs, but every step is grounded in a fresh
page observation and verified action results. It never submits, sends, pays,
purchases, deletes, cancels, or applies on the user's behalf.

## Architecture

```
Chrome Extension (MV3)
  ├── Side Panel (React)      — voice capture, status display, vault viewer
  ├── Vault (React + WASM)    — personal context and local document parsing
  └── Content Script          — DOM inspection, field extraction, action execution
          ↕ (WebSocket / REST)
FastAPI + Pipecat Server
  ├── Sarvam AI               — speech-to-text, text-to-speech, OCR fallback
  └── Gemini                  — reasoning, field-mapping, intent resolution
          ↕
Supabase
  ├── Alterity Control Plane   — identity, tenants, entitlements, billing, shared KB
  └── Swara Data Plane         — tasks, browser steps, artifacts, context references
```

## Browser execution loop

Each task follows a bounded plan → act → observe cycle. The server emits a
batch-bound action step, the extension performs only reversible operations,
and the next plan is allowed only after the extension returns the matching
results together with a freshly extracted page. Runs stop after eight batches
unless the user explicitly continues.

Users can pause, resume, cancel, or skip an in-flight run from the side panel.
The controls are protocol events rather than model-inferred voice intents:
pause stops at the next action boundary, resume and skip require a fresh page,
and cancel invalidates late results.

The extension supports controlled navigation, new tabs, tab switching,
back/forward, page readiness checks, and run-created tab cleanup. A per-session
allowlist prevents Swara from switching to or closing unrelated tabs. DOM and
browser actions display a non-interactive Shadow DOM overlay so the user can
see the active target, current step, and verified outcome.

When an SPA re-renders a control with a different generated identifier, the
content script can recover one unique compatible target from the previous
semantic fingerprint. Recovery is deterministic, confidence-gated, rejects
ties, and never heals submit or irreversible controls.

Verified safe actions can also be recorded as versioned local workflows in
`chrome.storage.local`, exported/imported as strictly validated JSON, and
replayed through the same action router. Secrets become runtime-only variables;
workflows do not use the Vault, Supabase, server storage, or background schedules.

Swara is designed to ship as an Alterity subproduct without becoming tightly
coupled to the Alterity web application. Alterity remains the control plane and
billing system of record; Swara remains an independently deployable browser and
voice execution plane. See [docs/ALTERITY_SWARA_BRIDGE.md](docs/ALTERITY_SWARA_BRIDGE.md)
for the ownership boundaries, API contract, rollout, and cost-reuse plan.

## Local-first document ingestion

The Vault uses AnyDoc WebAssembly in the extension to convert readable Word,
PowerPoint, Excel, OpenDocument, RTF, EPUB, CSV, PDF, text, and Markdown files
to editable Markdown before upload. PDFs are classified locally first; scanned,
image-based, mixed unreadable, and encoding-damaged PDFs fall back to Sarvam
OCR. PNG, JPEG, and ZIP inputs also use the OCR path. The original file is
stored in Supabase either way, while the document row records whether extraction
was `local` or `ocr`.

## Repo Layout

```
swara/
├── extension/          # Chrome MV3 extension source
│   ├── src/
│   │   ├── background/ # service worker
│   │   ├── content/    # content script (DOM / field extractor)
│   │   ├── sidepanel/  # side-panel React UI
│   │   └── types/      # shared message types
│   ├── manifest.config.ts
│   └── package.json
├── server/             # FastAPI / Pipecat backend
│   ├── app.py
│   ├── requirements.txt
│   └── .env.example
└── demo/               # Self-contained HTML fixture forms for development
    ├── job-application.html
    └── event-registration.html
```

## Setup

### Extension

```bash
cd extension
npm install
npm run build
npm test          # runs the extractor against the demo fixtures in jsdom
```

Then open `chrome://extensions`, enable **Developer mode**, click **Load unpacked**, and select the `extension/dist` directory. To use the fixtures in `demo/`, also enable **Allow access to file URLs** on the extension's details page.

### Server

```bash
cd server
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/uvicorn app:app --reload --port 8787
```

The server runs on `http://localhost:8787`. Port 8000 is deliberately avoided — it collides with too many other local dev servers. The extension's base URL lives in `extension/src/sidepanel/api.ts`.

The server's Vault surface is authenticated. Sign in through the extension's
PKCE flow before opening the Vault; guest/local workflows do not require the
server.

## Configuration

Copy `server/.env.example` to `server/.env` and fill in the values.

| Variable | Purpose |
|---|---|
| `SARVAM_API_KEY` | Sarvam AI — speech-to-text, text-to-speech, and OCR |
| `GOOGLE_API_KEY` | Google Gemini API — reasoning and field-mapping |
| `SUPABASE_URL` | Supabase project URL — server-side integration |
| `SUPABASE_PUBLISHABLE_KEY` | Browser-safe Supabase key used with a verified user JWT |
| `ALTERITY_CONTROL_PLANE_URL` | Alterity-owned Swara bootstrap and metering Edge Function |
| `ALTERITY_SWARA_SERVICE_TOKEN` | Server-only credential for idempotent usage metering |
| `SWARA_PRODUCT_KEY` | Stable entitlement/product key; defaults to `swara` |
