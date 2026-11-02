import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';

import { initSync, toMarkdownBytes } from '@firecrawl/anydoc-wasm';

const wasmPath = path.resolve(
  process.cwd(),
  'node_modules/@firecrawl/anydoc-wasm/anydoc_wasm_bg.wasm',
);
initSync({ module: new WebAssembly.Module(readFileSync(wasmPath)) });

const csv = new TextEncoder().encode(
  'Name,Role,Location\nVasu,Product Builder,Bengaluru\nSwara,Voice Assistant,Web\n',
);
const markdown = toMarkdownBytes(csv, 'csv');

assert.match(markdown, /Vasu/);
assert.match(markdown, /Product Builder/);
assert.match(markdown, /Bengaluru/);
assert.match(markdown, /Swara/);

console.log('AnyDoc converted a real CSV fixture locally.');
