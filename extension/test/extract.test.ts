/**
 * Runs the real extractor against the demo fixtures in jsdom.
 *
 * The extractor is pure DOM code with no Chrome APIs, so it can be exercised
 * outside the browser. Run with: npm test
 */

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { JSDOM } from 'jsdom';

const here = dirname(fileURLToPath(import.meta.url));
const demoDir = resolve(here, '../../demo');

async function loadFixture(name: string) {
  const html = readFileSync(resolve(demoDir, name), 'utf8');
  return loadHtml(html, name);
}

async function loadHtml(html: string, cacheKey: string) {
  const dom = new JSDOM(html, {
    url: `https://example.test/${cacheKey}`,
  });

  // jsdom does no layout, so offsetParent is always null and the extractor's
  // visibility guard would reject every control. Emulate layout: an element is
  // "rendered" unless it or an ancestor is display:none / hidden.
  Object.defineProperty(dom.window.HTMLElement.prototype, 'offsetParent', {
    configurable: true,
    get(this: HTMLElement) {
      for (let node: HTMLElement | null = this; node; node = node.parentElement) {
        const style = dom.window.getComputedStyle(node);
        if (style.display === 'none' || node.hasAttribute('hidden')) return null;
      }
      return dom.window.document.body;
    },
  });

  // The extractor reads these as globals, exactly as it would in a content script.
  const g = globalThis as Record<string, unknown>;
  g.window = dom.window;
  g.document = dom.window.document;
  g.location = dom.window.location;
  for (const ctor of [
    'HTMLInputElement',
    'HTMLTextAreaElement',
    'HTMLSelectElement',
    'HTMLAnchorElement',
    'HTMLLabelElement',
    'HTMLLegendElement',
    'HTMLElement',
    'Element',
  ]) {
    g[ctor] = (dom.window as unknown as Record<string, unknown>)[ctor];
  }

  // Imported fresh per fixture so it binds the globals set above.
  const { extractPage } = await import(
    `../src/content/extract.ts?${cacheKey}`
  );
  return extractPage();
}

const failures: string[] = [];
function check(label: string, fn: () => void) {
  try {
    fn();
    console.log(`  ok   ${label}`);
  } catch (error) {
    failures.push(label);
    console.log(`  FAIL ${label}\n       ${(error as Error).message}`);
  }
}

console.log('\njob-application.html');
const job = await loadFixture('job-application.html');
const jobById = new Map(job.fields.map((f: any) => [f.fieldId, f]));

check('extracts 13 logical fields', () => {
  assert.equal(job.fields.length, 13, `got ${job.fields.length}: ${job.fields.map((f: any) => f.fieldId).join(', ')}`);
});

check('groups the radio set into one field', () => {
  const counts = job.fields.reduce((acc: any, f: any) => ({ ...acc, [f.type]: (acc[f.type] ?? 0) + 1 }), {});
  assert.deepEqual(counts, { text: 5, textarea: 4, select: 2, radio: 1, checkbox: 1 }, JSON.stringify(counts));
});

check('strips the aria-hidden asterisk from labels', () => {
  const f = jobById.get('about_yourself');
  assert.ok(f, 'about_yourself missing');
  assert.equal(f.question, 'Tell us about yourself.');
  assert.ok(!f.question.includes('*'), 'asterisk leaked into the question');
});

check('drops the parenthetical hint from the phone label', () => {
  const f = jobById.get('phone');
  assert.ok(!/country code/i.test(f.question), `hint leaked: ${f.question}`);
});

check('uses the fieldset legend as the radio group question', () => {
  const f = jobById.get('work_authorization');
  assert.ok(f, 'work_authorization missing');
  assert.match(f.question, /legally authorized/i);
  assert.equal(f.options.length, 2);
});

check('uses the fieldset legend as the checkbox group question', () => {
  const f = jobById.get('areas_of_interest');
  assert.ok(f, 'areas_of_interest missing');
  assert.match(f.question, /areas of interest/i);
  assert.equal(f.options.length, 6, `got ${f.options.length} options`);
});

check('skips the placeholder option in selects', () => {
  const f = jobById.get('years_of_experience');
  assert.ok(f.options.length > 0);
  assert.ok(!f.options.some((o: any) => o.value === ''), 'empty placeholder option retained');
});

check('marks required fields', () => {
  assert.equal(jobById.get('full_name').required, true);
  assert.equal(jobById.get('linkedin_url').required, false);
});

check('omits maxLength when the attribute is unset', () => {
  const bogus = job.fields.filter((f: any) => f.maxLength === 524288);
  assert.equal(bogus.length, 0, 'leaked the DOM default maxLength');
});

check('captures the page heading', () => {
  assert.match(job.heading ?? '', /Senior AI Product Manager/i);
});

check('extracts labelled job controls and flags submission', () => {
  assert.deepEqual(
    job.controls.map((control: any) => [control.label, control.role]),
    [
      ['Careers', 'link'],
      ['About', 'link'],
      ['Save as draft', 'button'],
      ['Submit Application →', 'submit'],
    ],
  );
});

console.log('\nevent-registration.html');
const evt = await loadFixture('event-registration.html');
const evtById = new Map(evt.fields.map((f: any) => [f.fieldId, f]));

check('extracts 7 fields', () => {
  assert.equal(evt.fields.length, 7, `got ${evt.fields.length}: ${evt.fields.map((f: any) => f.fieldId).join(', ')}`);
});

check('treats the lone speaker checkbox as a checkbox field', () => {
  const f = evtById.get('speaker_interest');
  assert.ok(f, `speaker_interest missing; ids: ${[...evtById.keys()].join(', ')}`);
  assert.equal(f.type, 'checkbox');
});

check('every field has a non-empty question', () => {
  const blank = [...job.fields, ...evt.fields].filter((f: any) => !f.question.trim());
  assert.equal(blank.length, 0, `blank questions: ${blank.map((f: any) => f.fieldId).join(', ')}`);
});

check('extracts and flags the event registration control', () => {
  assert.deepEqual(
    evt.controls.map((control: any) => [control.label, control.role]),
    [['Confirm Registration →', 'submit']],
  );
});

const { hasPageChanged } = await import('../src/content/extract.ts?page-change');

check('detects changed field ids but not an identical page', () => {
  assert.equal(hasPageChanged(job, { ...job, fields: [...job.fields] }), false);
  assert.equal(
    hasPageChanged(job, {
      ...job,
      fields: [{ ...job.fields[0], fieldId: 'different_field' }],
    }),
    true,
  );
});

console.log('\ngoogle-form-clone.html');
const googleForm = await loadFixture('google-form-clone.html');
const googleById = new Map(googleForm.fields.map((f: any) => [f.fieldId, f]));

check('extracts mixed native and ARIA fields without double-counting', () => {
  assert.equal(
    googleForm.fields.length,
    4,
    googleForm.fields.map((f: any) => `${f.fieldId}:${f.type}`).join(', '),
  );
  assert.deepEqual(
    googleForm.fields.map((f: any) => f.type),
    ['text', 'radio', 'checkbox', 'select'],
  );
});

check('uses the listitem heading as the ARIA radio question', () => {
  const field = googleById.get('commute');
  assert.ok(field, 'commute radio group missing');
  assert.equal(field.question, 'Preferred commute');
  assert.equal(field.required, true);
});

check('extracts ARIA radio option values and labels', () => {
  assert.deepEqual(googleById.get('commute').options, [
    { value: 'public', label: 'Public transport' },
    { value: 'drive', label: 'Drive' },
  ]);
});

check('groups ARIA checkboxes and captures their selected value', () => {
  const field = googleById.get('skills');
  assert.ok(field, 'skills checkbox group missing');
  assert.equal(field.question, 'Skills');
  assert.deepEqual(
    field.options.map((option: any) => option.value),
    ['typescript', 'python'],
  );
  assert.equal(field.currentValue, 'typescript');
});

check('treats an ARIA listbox as a select', () => {
  const field = googleById.get('office-location');
  assert.ok(field, 'office-location listbox missing');
  assert.equal(field.question, 'Office location');
  assert.deepEqual(field.options, [
    { value: 'blr', label: 'Bengaluru' },
    { value: 'Pune', label: 'Pune' },
  ]);
});

console.log('\nreadable-page.html');
const readable = await loadFixture('readable-page.html');
const editable = readable.fields.find(
  (field: any) => field.type === 'contenteditable',
);

check('extracts readable headings and paragraphs with boundaries', () => {
  assert.equal(
    readable.readableText,
    [
      'Research fellowship',
      'The fellowship supports independent research in trustworthy AI.',
      'What you will do',
      'Fellows publish their findings and present them to the community.',
    ].join('\n\n'),
  );
});

check('excludes navigation, hidden UI, forms, drafts, and password values', () => {
  assert.doesNotMatch(
    readable.readableText ?? '',
    /Account|hidden deadline|invisible salary|noisy text|Password|never-extract|Existing draft|Privacy/,
  );
});

check('advertises independently gated assistant capabilities', () => {
  assert.deepEqual(readable.capabilities, [
    'readablePageText',
    'contentEditableFill',
    'openUrl',
    'browserNavigation',
  ]);
});

check('extracts a labelled contenteditable field with its current value', () => {
  assert.ok(editable, 'contenteditable field missing');
  assert.equal(editable.fieldId, 'Reply body');
  assert.equal(editable.question, 'Reply body');
  assert.equal(editable.currentValue, 'Existing draft');
});

const { ASSISTANT_FEATURES } = await import('../src/features.ts');
const mutableFeatures = ASSISTANT_FEATURES as unknown as Record<string, boolean>;
mutableFeatures.readablePageText = false;
mutableFeatures.contentEditableFill = false;
const gated = await loadFixture('readable-page.html');
mutableFeatures.readablePageText = true;
mutableFeatures.contentEditableFill = true;

check('feature switches remove readable text and contenteditable extraction', () => {
  assert.equal(gated.readableText, undefined);
  assert.equal(
    gated.fields.some((field: any) => field.type === 'contenteditable'),
    false,
  );
  assert.deepEqual(gated.capabilities, ['openUrl', 'browserNavigation']);
});

const duplicateEditors = await loadHtml(
  `<main>
    <div role="textbox" contenteditable="true" aria-label="Message Body">First</div>
    <div role="textbox" contenteditable="true" aria-label="Message Body">Second</div>
  </main>`,
  'duplicate-editors',
);

check('gives duplicate rich editors distinct deterministic ids', () => {
  assert.deepEqual(
    duplicateEditors.fields.map((field: any) => field.fieldId),
    ['Message Body:1', 'Message Body:2'],
  );
});

const longReadable = await loadHtml(
  `<main><h1>Long page</h1><p>${'deterministic text '.repeat(2_000)}</p></main>`,
  'long-readable',
);
const longReadableAgain = await loadHtml(
  `<main><h1>Long page</h1><p>${'deterministic text '.repeat(2_000)}</p></main>`,
  'long-readable-again',
);

check('truncates long readable text deterministically at 16k', () => {
  assert.equal(longReadable.readableText?.length, 16_000);
  assert.equal(longReadable.readableText, longReadableAgain.readableText);
});

console.log(
  failures.length === 0
    ? '\nAll extractor checks passed.\n'
    : `\n${failures.length} check(s) failed.\n`,
);
process.exit(failures.length === 0 ? 0 : 1);
