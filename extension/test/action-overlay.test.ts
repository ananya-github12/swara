import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';

const dom = new JSDOM('<!doctype html><html><body><button id="target">Save</button></body></html>', {
  url: 'https://example.test/',
  pretendToBeVisual: true,
});
const g = globalThis as Record<string, unknown>;
g.window = dom.window;
g.document = dom.window.document;
g.HTMLElement = dom.window.HTMLElement;
g.Element = dom.window.Element;
g.DOMRect = dom.window.DOMRect;

const { ActionOverlay } = await import('../src/content/actionOverlay.ts');
const target = dom.window.document.querySelector<HTMLElement>('#target')!;
let rect = { left: 20, top: 30, width: 100, height: 40, right: 120, bottom: 70 };
Object.defineProperty(target, 'getClientRects', { value: () => [rect] });
Object.defineProperty(target, 'getBoundingClientRect', { value: () => rect });

const overlay = new ActionOverlay(dom.window.document);
overlay.show({
  target,
  status: 'waiting',
  step: { current: 1, total: 3 },
  title: 'Reviewing the form',
  reason: 'This is the name field.',
});

const host = dom.window.document.querySelector<HTMLElement>('#swara-action-overlay')!;
const shadow = host.shadowRoot!;
const ring = shadow.querySelector<HTMLElement>('.ring')!;
const card = shadow.querySelector<HTMLElement>('.card')!;

assert.equal(host.style.pointerEvents, 'none');
assert.equal(host.getAttribute('aria-hidden'), 'true');
assert.equal(target.getAttribute('style'), null, 'target styles stay untouched');
assert.match(shadow.textContent ?? '', /Waiting · Step 1 of 3/);
assert.match(shadow.textContent ?? '', /Reviewing the form/);
assert.equal(ring.style.left, '16px');
assert.equal(ring.style.top, '26px');
assert.equal(ring.style.width, '108px');
assert.equal(ring.style.height, '48px');
assert.equal(card.style.opacity, '1');

rect = { left: 50, top: 80, width: 20, height: 20, right: 70, bottom: 100 };
dom.window.dispatchEvent(new dom.window.Event('scroll'));
assert.equal(ring.style.left, '46px', 'repositions during scrolling');
assert.equal(ring.style.top, '76px', 'repositions during scrolling');

overlay.show({ target, status: 'confirmation', reason: 'Sending is left to you.' });
assert.equal(host.dataset.status, 'confirmation');
assert.match(shadow.textContent ?? '', /Your confirmation needed/);

overlay.show({ target, status: 'failure', title: 'Could not find the next page' });
assert.equal(host.dataset.status, 'failure');
assert.match(shadow.textContent ?? '', /Could not complete/);

overlay.show({ target, status: 'success' });
assert.equal(host.dataset.status, 'success');
assert.match(shadow.textContent ?? '', /Done/);

overlay.hideAfter(0);
await new Promise((resolve) => dom.window.setTimeout(resolve, 0));
assert.equal(ring.style.opacity, '0', 'terminal feedback automatically clears');
assert.equal(card.style.opacity, '0', 'terminal card automatically clears');

overlay.hide();
assert.equal(ring.style.opacity, '0');
assert.equal(card.style.opacity, '0');
overlay.destroy();
assert.equal(dom.window.document.querySelector('#swara-action-overlay'), null);

console.log('action overlay');
console.log('  ok   isolates visual state from the page and cleans up');
