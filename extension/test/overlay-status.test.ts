import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';

const dom = new JSDOM('<!doctype html><html><body><input id="search" /></body></html>', {
  url: 'https://example.test/',
  pretendToBeVisual: true,
});
Object.defineProperty(dom.window.HTMLElement.prototype, 'offsetParent', {
  configurable: true,
  get() { return dom.window.document.body; },
});
const g = globalThis as Record<string, unknown>;
g.window = dom.window;
g.document = dom.window.document;
for (const constructor of [
  'HTMLInputElement', 'HTMLTextAreaElement', 'HTMLSelectElement',
  'HTMLAnchorElement', 'HTMLLabelElement', 'HTMLLegendElement',
  'HTMLElement', 'Element',
]) {
  g[constructor] = (dom.window as unknown as Record<string, unknown>)[constructor];
}

const { showOverlayStatus } = await import('../src/content/overlayStatus.ts');
const { destroyActionOverlay } = await import('../src/content/actionOverlay.ts');
const target = dom.window.document.querySelector<HTMLElement>('#search')!;
const rect = { left: 10, top: 20, width: 140, height: 32, right: 150, bottom: 52 };
Object.defineProperty(target, 'getClientRects', { value: () => [rect] });
Object.defineProperty(target, 'getBoundingClientRect', { value: () => rect });

showOverlayStatus({
  type: 'SWARA_OVERLAY_STATUS',
  status: 'executing',
  step: { current: 2, total: 4 },
  title: 'Opening the next result',
  reason: 'It matches your request.',
  fieldId: 'search',
});

const host = dom.window.document.querySelector<HTMLElement>('#swara-action-overlay')!;
const shadow = host.shadowRoot!;
assert.equal(host.dataset.status, 'executing');
assert.match(shadow.textContent ?? '', /Working · Step 2 of 4/);
assert.match(shadow.textContent ?? '', /Opening the next result/);
assert.equal(shadow.querySelector<HTMLElement>('.ring')!.style.opacity, '1');
assert.equal(host.style.pointerEvents, 'none');

showOverlayStatus({ type: 'SWARA_OVERLAY_STATUS', status: 'confirmation' });
assert.equal(host.dataset.status, 'confirmation');
assert.match(shadow.textContent ?? '', /Your confirmation needed/);

destroyActionOverlay();
assert.equal(dom.window.document.querySelector('#swara-action-overlay'), null);
console.log('overlay status message');
console.log('  ok   renders content-script status messages without page interaction');
