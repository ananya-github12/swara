import type { FieldType, FormField, PageControl } from '../types';
import type {
  ExtractableControlTarget,
  ExtractableFieldTarget,
} from './extract';

/**
 * A semantic, deliberately selector-free description of an extracted target.
 * It is kept in the content-script process only: the planner still receives
 * the established PageContext contract and cannot ask us to target arbitrary
 * DOM nodes with a fingerprint.
 */
export type TargetFingerprint = {
  kind: 'field' | 'control';
  type?: FieldType;
  role?: PageControl['role'];
  label: string;
  question: string;
  nameHints: string[];
  idHints: string[];
  nearbyText: string;
  options: string[];
  /** Stable diagnostic representation; never used as a CSS selector. */
  signature: string;
};

export type HealingMatch<T> = {
  target: T;
  confidence: number;
};

const fieldFingerprints = new Map<string, TargetFingerprint>();
const controlFingerprints = new Map<string, TargetFingerprint>();
const NORMALIZED_TEXT_LIMIT = 480;
const HEALING_THRESHOLD = 0.8;
const TIE_EPSILON = 0.01;

function normalize(value: string | null | undefined): string {
  return (value ?? '')
    .replace(/\s+/g, ' ')
    .trim()
    .toLocaleLowerCase();
}

function uniqueSorted(values: Array<string | null | undefined>): string[] {
  return [...new Set(values.map(normalize).filter(Boolean))].sort();
}

function nearestContext(element: HTMLElement): string {
  const container = element.closest<HTMLElement>(
    'fieldset, [role="group"], [role="radiogroup"], [role="listbox"], [role="listitem"], form, section',
  );
  return normalize((container ?? element.parentElement)?.textContent).slice(
    0,
    NORMALIZED_TEXT_LIMIT,
  );
}

function elementHints(elements: HTMLElement[]): {
  nameHints: string[];
  idHints: string[];
} {
  return {
    nameHints: uniqueSorted(elements.map((element) => element.getAttribute('name'))),
    idHints: uniqueSorted(elements.map((element) => element.id)),
  };
}

function makeFingerprint(
  fingerprint: Omit<TargetFingerprint, 'signature'>,
): TargetFingerprint {
  const normalized = {
    ...fingerprint,
    label: normalize(fingerprint.label),
    question: normalize(fingerprint.question),
    nameHints: uniqueSorted(fingerprint.nameHints),
    idHints: uniqueSorted(fingerprint.idHints),
    nearbyText: normalize(fingerprint.nearbyText).slice(0, NORMALIZED_TEXT_LIMIT),
    options: uniqueSorted(fingerprint.options),
  };
  return {
    ...normalized,
    signature: JSON.stringify(normalized),
  };
}

export function fingerprintField(
  field: FormField,
  target: ExtractableFieldTarget,
): TargetFingerprint {
  const elements = target.elements as HTMLElement[];
  const anchor = target.groupElement ?? elements[0];
  const hints = elementHints(elements);
  return makeFingerprint({
    kind: 'field',
    type: field.type,
    label: field.label,
    question: field.question,
    ...hints,
    nearbyText: anchor ? nearestContext(anchor) : '',
    options: field.options.flatMap((option) => [option.label, option.value]),
  });
}

export function fingerprintControl(
  control: PageControl,
  target: ExtractableControlTarget,
): TargetFingerprint {
  const hints = elementHints([target.element]);
  return makeFingerprint({
    kind: 'control',
    role: control.role,
    label: control.label,
    question: control.label,
    ...hints,
    nearbyText: nearestContext(target.element),
    options: [],
  });
}

/** Save the last extraction's semantic target identities for a later re-render. */
export function rememberExtractedTargets(
  fields: FormField[],
  fieldTargets: ExtractableFieldTarget[],
  controls: PageControl[],
  controlTargets: ExtractableControlTarget[],
): void {
  fieldFingerprints.clear();
  controlFingerprints.clear();
  fields.forEach((field, index) => {
    const target = fieldTargets[index];
    if (target) fieldFingerprints.set(field.fieldId, fingerprintField(field, target));
  });
  controls.forEach((control, index) => {
    const target = controlTargets[index];
    if (target) controlFingerprints.set(control.controlId, fingerprintControl(control, target));
  });
}

export function expectedFieldFingerprint(fieldId: string): TargetFingerprint | undefined {
  return fieldFingerprints.get(fieldId);
}

export function expectedControlFingerprint(controlId: string): TargetFingerprint | undefined {
  return controlFingerprints.get(controlId);
}

function overlapScore(expected: string[], candidate: string[]): number {
  if (expected.length === 0 || candidate.length === 0) return 0;
  const candidates = new Set(candidate);
  return expected.some((value) => candidates.has(value)) ? 1 : 0;
}

function scoreFingerprint(
  expected: TargetFingerprint,
  candidate: TargetFingerprint,
): number | undefined {
  if (expected.kind !== candidate.kind) return undefined;
  // A field is never allowed to become another input family, and a control
  // cannot become a different interactive role during recovery.
  if (expected.kind === 'field' && expected.type !== candidate.type) return undefined;
  if (expected.kind === 'control' && expected.role !== candidate.role) return undefined;

  const label = expected.label && expected.label === candidate.label ? 0.52 : 0;
  const question =
    expected.question && expected.question === candidate.question ? 0.16 : 0;
  const names = overlapScore(expected.nameHints, candidate.nameHints) * 0.14;
  const ids = overlapScore(expected.idHints, candidate.idHints) * 0.08;
  const nearby =
    expected.nearbyText && expected.nearbyText === candidate.nearbyText ? 0.2 : 0;
  const options =
    expected.options.length > 0 &&
    expected.options.length === candidate.options.length &&
    expected.options.every((value) => candidate.options.includes(value))
      ? 0.22
      : 0;
  return Math.min(1, label + question + names + ids + nearby + options);
}

/**
 * Returns one high-confidence candidate only. Equal or near-equal candidates
 * are intentionally rejected rather than guessing.
 */
export function findHealingMatch<T>(
  expected: TargetFingerprint | undefined,
  candidates: Array<{ target: T; fingerprint: TargetFingerprint }>,
): HealingMatch<T> | undefined {
  if (!expected) return undefined;
  const ranked = candidates
    .map(({ target, fingerprint }) => ({
      target,
      confidence: scoreFingerprint(expected, fingerprint),
    }))
    .filter((item): item is HealingMatch<T> => item.confidence !== undefined)
    .sort((left, right) => right.confidence - left.confidence);
  const best = ranked[0];
  if (!best || best.confidence < HEALING_THRESHOLD) return undefined;
  const runnerUp = ranked[1];
  if (runnerUp && best.confidence - runnerUp.confidence <= TIE_EPSILON) {
    return undefined;
  }
  return best;
}
