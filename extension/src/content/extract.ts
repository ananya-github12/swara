import type {
  FieldOption,
  FieldType,
  FormField,
  PageControl,
  PageContext,
} from '../types';
import {
  ASSISTANT_FEATURES,
  enabledAssistantCapabilities,
} from '../features';
import { rememberExtractedTargets } from './targetFingerprint';

export type FormControlElement =
  | HTMLInputElement
  | HTMLTextAreaElement
  | HTMLSelectElement;

export type AriaWidgetElement = HTMLElement & {
  dataset: DOMStringMap;
};

export type ExtractableFieldElement =
  | FormControlElement
  | AriaWidgetElement;

export type ExtractableFieldTarget = {
  fieldId: string;
  type: FieldType;
  elements: ExtractableFieldElement[];
  groupElement?: HTMLElement;
  ariaWidget?: boolean;
};

export type ExtractableControlTarget = {
  controlId: string;
  element: HTMLElement;
  role: PageControl['role'];
  disabled: boolean;
};

const TEXT_INPUT_TYPES = new Set([
  'text',
  'email',
  'tel',
  'url',
  'search',
  'number',
  'password',
]);

const DESTRUCTIVE_CONTROL_LABEL = /submit|apply|send|pay|delete|remove|confirm/i;
const READABLE_TEXT_LIMIT = 16_000;
const READABLE_BLOCK_SELECTOR = [
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'p',
  'li',
  'blockquote',
  'pre',
  'dt',
  'dd',
  'figcaption',
  'td',
  'th',
  'section',
  'div',
].join(',');
const READABLE_EXCLUDED_SELECTOR = [
  'script',
  'style',
  'template',
  'noscript',
  'nav',
  'aside',
  'footer',
  'form',
  'button',
  'input',
  'textarea',
  'select',
  'option',
  '[contenteditable]',
  '[role="navigation"]',
  '[role="menu"]',
  '[role="dialog"]',
  '[hidden]',
  '[aria-hidden="true"]',
].join(',');

function isRendered(element: HTMLElement): boolean {
  return (
    element.offsetParent !== null ||
    window.getComputedStyle(element).position === 'fixed'
  );
}

export function isExtractableControl(
  element: Element,
): element is FormControlElement {
  if (
    !(
      element instanceof HTMLInputElement ||
      element instanceof HTMLTextAreaElement ||
      element instanceof HTMLSelectElement
    ) ||
    element.disabled ||
    !isRendered(element)
  ) {
    return false;
  }

  return (
    !(element instanceof HTMLInputElement) ||
    TEXT_INPUT_TYPES.has(element.type) ||
    element.type === 'radio' ||
    element.type === 'checkbox'
  );
}

function isDisabledControl(element: HTMLElement): boolean {
  return (
    element.hasAttribute('disabled') ||
    element.getAttribute('aria-disabled')?.toLocaleLowerCase() === 'true'
  );
}

export function isExtractablePageControl(
  element: Element,
): element is HTMLElement {
  return element instanceof HTMLElement && !isDisabledControl(element) && isRendered(element);
}

function controlType(element: FormControlElement): FieldType {
  if (element instanceof HTMLTextAreaElement) {
    return 'textarea';
  }
  if (element instanceof HTMLSelectElement) {
    return 'select';
  }
  if (element.type === 'radio') {
    return 'radio';
  }
  if (element.type === 'checkbox') {
    return 'checkbox';
  }
  return 'text';
}

function isNativeFormControl(element: Element): boolean {
  return (
    element instanceof HTMLInputElement ||
    element instanceof HTMLTextAreaElement ||
    element instanceof HTMLSelectElement
  );
}

function isExtractableAriaWidget(element: Element): element is AriaWidgetElement {
  return (
    element instanceof HTMLElement &&
    !isNativeFormControl(element) &&
    !isDisabledControl(element) &&
    isRendered(element)
  );
}

function slugify(value: string): string {
  return value
    .toLocaleLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
}

function labelledByText(element: Element): string {
  return (element.getAttribute('aria-labelledby') ?? '')
    .split(/\s+/)
    .map((id) => document.getElementById(id))
    .filter((candidate): candidate is HTMLElement => candidate !== null)
    .map(cleanElementText)
    .filter(Boolean)
    .join(' ');
}

function nearestPrecedingHeading(element: Element): HTMLElement | undefined {
  const headings = Array.from(
    document.querySelectorAll<HTMLElement>(
      'h1, h2, h3, h4, h5, h6, [role="heading"]',
    ),
  );
  const preceding = headings.filter(
    (heading) =>
      !element.contains(heading) &&
      Boolean(heading.compareDocumentPosition(element) & 4),
  );
  return preceding[preceding.length - 1];
}

function ariaGroupQuestion(group: HTMLElement): string {
  const labelledBy = labelledByText(group);
  if (labelledBy) {
    return collapseText(labelledBy);
  }

  const ariaLabel = group.getAttribute('aria-label');
  if (ariaLabel) {
    return collapseText(ariaLabel);
  }

  const listItem = group.closest<HTMLElement>('[role="listitem"]');
  const listItemHeading = listItem?.querySelector<HTMLElement>('[role="heading"]');
  if (listItemHeading) {
    const text = cleanElementText(listItemHeading);
    if (text) {
      return text;
    }
  }

  const precedingHeading = nearestPrecedingHeading(group);
  return precedingHeading ? cleanElementText(precedingHeading) : '';
}

function ariaGroupId(
  group: HTMLElement,
  question: string,
  index: number,
): string {
  return (
    group.id ||
    group.getAttribute('aria-labelledby') ||
    slugify(question) ||
    `${group.tagName.toLowerCase()}:${index}`
  );
}

function ariaRoleElements(
  group: HTMLElement,
  role: 'radio' | 'checkbox' | 'option',
): AriaWidgetElement[] {
  return Array.from(group.querySelectorAll(`[role="${role}"]`)).filter(
    isExtractableAriaWidget,
  );
}

function ariaTargets(startIndex: number): ExtractableFieldTarget[] {
  const targets: ExtractableFieldTarget[] = [];
  const seenOptions = new Set<HTMLElement>();
  const seenGroups = new Set<HTMLElement>();

  const addTarget = (
    group: HTMLElement,
    type: 'radio' | 'checkbox' | 'select',
    elements: AriaWidgetElement[],
  ) => {
    if (seenGroups.has(group) || elements.length === 0) {
      return;
    }
    seenGroups.add(group);
    elements.forEach((element) => seenOptions.add(element));
    const index = startIndex + targets.length;
    const question = ariaGroupQuestion(group);
    targets.push({
      fieldId: ariaGroupId(group, question, index),
      type,
      elements: [group, ...elements.filter((element) => element !== group)],
      groupElement: group,
      ariaWidget: true,
    });
  };

  Array.from(document.querySelectorAll<HTMLElement>('[role="radiogroup"]'))
    .filter(isExtractableAriaWidget)
    .forEach((group) => addTarget(group, 'radio', ariaRoleElements(group, 'radio')));

  Array.from(document.querySelectorAll<HTMLElement>('[role="radio"]'))
    .filter(isExtractableAriaWidget)
    .forEach((radio) => {
      if (seenOptions.has(radio)) {
        return;
      }
      if (radio.closest('[role="radiogroup"]')) {
        return;
      }
      const group =
        radio.closest<HTMLElement>('[role="listitem"]') ??
        radio.parentElement ??
        radio;
      const radios = Array.from(
        group.querySelectorAll<HTMLElement>('[role="radio"]'),
      ).filter(
        (candidate): candidate is AriaWidgetElement =>
          !candidate.closest('[role="radiogroup"]') &&
          isExtractableAriaWidget(candidate),
      );
      addTarget(group, 'radio', radios.length > 0 ? radios : [radio]);
    });

  Array.from(document.querySelectorAll<HTMLElement>('[role="checkbox"]'))
    .filter(isExtractableAriaWidget)
    .forEach((checkbox) => {
      if (seenOptions.has(checkbox)) {
        return;
      }
      const group =
        checkbox.closest<HTMLElement>('[role="listitem"]') ??
        checkbox.parentElement ??
        checkbox;
      const checkboxes = ariaRoleElements(group, 'checkbox');
      addTarget(
        group,
        'checkbox',
        checkboxes.length > 0 ? checkboxes : [checkbox],
      );
    });

  const listboxes = Array.from(
    document.querySelectorAll<HTMLElement>('[role="listbox"]'),
  ).filter(isExtractableAriaWidget);
  const consumedListboxes = new Set<HTMLElement>();
  Array.from(document.querySelectorAll<HTMLElement>('[role="combobox"]'))
    .filter(isExtractableAriaWidget)
    .forEach((combobox) => {
      const ownedIds = (
        combobox.getAttribute('aria-controls') ??
        combobox.getAttribute('aria-owns') ??
        ''
      ).split(/\s+/);
      const listbox =
        listboxes.find(
          (candidate) =>
            combobox.contains(candidate) ||
            (candidate.id && ownedIds.includes(candidate.id)),
        );
      if (listbox) {
        consumedListboxes.add(listbox);
      }
      const options = listbox
        ? ariaRoleElements(listbox, 'option')
        : ariaRoleElements(combobox, 'option');
      addTarget(combobox, 'select', options.length > 0 ? options : [combobox]);
    });
  listboxes
    .filter((listbox) => !consumedListboxes.has(listbox))
    .forEach((listbox) =>
      addTarget(listbox, 'select', ariaRoleElements(listbox, 'option')),
    );

  return targets;
}

export function isExtractableContentEditable(
  element: Element,
): element is HTMLElement {
  if (
    !(element instanceof HTMLElement) ||
    isDisabledControl(element) ||
    !isRendered(element)
  ) {
    return false;
  }

  const contentEditable = element.getAttribute('contenteditable');
  return (
    contentEditable !== null &&
    contentEditable.toLocaleLowerCase() !== 'false'
  );
}

function contentEditableTargets(
  startIndex: number,
): ExtractableFieldTarget[] {
  if (!ASSISTANT_FEATURES.contentEditableFill) {
    return [];
  }

  const elements = Array.from(
    document.querySelectorAll<HTMLElement>(
      '[contenteditable="true"], [role="textbox"][contenteditable]',
    ),
  ).filter(isExtractableContentEditable);
  const bases = elements.map(
    (element, index) =>
      element.id ||
      element.getAttribute('name') ||
      element.getAttribute('aria-label') ||
      element.getAttribute('aria-labelledby') ||
      `contenteditable:${startIndex + index}`,
  );
  const counts = new Map<string, number>();
  for (const base of bases) counts.set(base, (counts.get(base) ?? 0) + 1);
  const occurrences = new Map<string, number>();

  return elements.map((element, index) => {
    const base = bases[index];
    const occurrence = (occurrences.get(base) ?? 0) + 1;
    occurrences.set(base, occurrence);
    return {
      fieldId: counts.get(base) === 1 ? base : `${base}:${occurrence}`,
      type: 'contenteditable' as const,
      elements: [element],
    };
  });
}

export function collectExtractableFieldTargets(): ExtractableFieldTarget[] {
  const controls = Array.from(
    document.querySelectorAll('input, textarea, select'),
  ).filter(isExtractableControl);
  const targets: ExtractableFieldTarget[] = [];
  const seenGroups = new Set<string>();

  for (const control of controls) {
    const type = controlType(control);
    if (
      control instanceof HTMLInputElement &&
      (type === 'radio' || type === 'checkbox')
    ) {
      const name = control.name;
      const groupKey = name ? `${type}:${name}` : '';
      if (groupKey && seenGroups.has(groupKey)) {
        continue;
      }
      if (groupKey) {
        seenGroups.add(groupKey);
      }

      const elements = name
        ? controls.filter(
            (candidate): candidate is HTMLInputElement =>
              candidate instanceof HTMLInputElement &&
              candidate.type === type &&
              candidate.name === name,
          )
        : [control];
      const index = targets.length;
      targets.push({
        fieldId: name || `input:${index}`,
        type,
        elements,
      });
      continue;
    }

    const index = targets.length;
    targets.push({
      fieldId:
        control.id ||
        control.getAttribute('name') ||
        `${control.tagName.toLowerCase()}:${index}`,
      type,
      elements: [control],
    });
  }

  const contentEditables = contentEditableTargets(targets.length);
  return [
    ...targets,
    ...contentEditables,
    ...ariaTargets(targets.length + contentEditables.length),
  ];
}

function collapseText(value: string): string {
  return value.replace(/\s+/g, ' ').trim().replace(/[\s*:]+$/, '');
}

function cleanElementText(element: Element): string {
  const clone = element.cloneNode(true) as Element;
  clone
    .querySelectorAll('[aria-hidden="true"], span.hint')
    .forEach((node) => node.remove());
  clone.querySelectorAll('span').forEach((span) => {
    if (/^\s*\([^)]*\)\s*$/.test(span.textContent ?? '')) {
      span.remove();
    }
  });
  return collapseText(clone.textContent ?? '');
}

export function controlLabel(element: HTMLElement): string {
  const visibleText = cleanElementText(element);
  if (visibleText) {
    return visibleText;
  }

  return collapseText(
    element.getAttribute('aria-label') ??
      element.getAttribute('title') ??
      element.getAttribute('value') ??
      '',
  );
}

function controlRole(
  element: HTMLElement,
  label: string,
): PageControl['role'] {
  if (
    DESTRUCTIVE_CONTROL_LABEL.test(label) ||
    (element.tagName === 'BUTTON' &&
      (element as HTMLButtonElement).type === 'submit') ||
    (element instanceof HTMLInputElement && element.type === 'submit')
  ) {
    return 'submit';
  }
  if (element.getAttribute('role') === 'tab') {
    return 'tab';
  }
  if (element instanceof HTMLAnchorElement) {
    return 'link';
  }
  return 'button';
}

export function collectExtractableControlTargets(): ExtractableControlTarget[] {
  const controls = Array.from(
    document.querySelectorAll(
      'button, a[href], [role="button"], [role="tab"], input[type="submit"], input[type="button"]',
    ),
  ).filter(isExtractablePageControl);

  return controls.map((element, index) => {
    const label = controlLabel(element);
    return {
      controlId:
        element.id || element.getAttribute('name') || `control:${index}`,
      element,
      role: controlRole(element, label),
      disabled: isDisabledControl(element),
    };
  });
}

function labelForId(id: string): HTMLLabelElement | undefined {
  if (!id) {
    return undefined;
  }
  return Array.from(
    document.querySelectorAll<HTMLLabelElement>('label[for]'),
  ).find(
    (label) => label.htmlFor === id,
  );
}

function resolveLabel(control: ExtractableFieldElement): string {
  const explicitLabel = labelForId(control.id);
  if (explicitLabel) {
    return cleanElementText(explicitLabel);
  }

  const wrappingLabel = control.closest('label');
  if (wrappingLabel) {
    return cleanElementText(wrappingLabel);
  }

  const ariaLabel = control.getAttribute('aria-label');
  if (ariaLabel) {
    return collapseText(ariaLabel);
  }

  const labelledBy = control.getAttribute('aria-labelledby');
  if (labelledBy) {
    const text = labelledBy
      .split(/\s+/)
      .map((id) => document.getElementById(id))
      .filter((element): element is HTMLElement => element !== null)
      .map(cleanElementText)
      .filter(Boolean)
      .join(' ');
    if (text) {
      return collapseText(text);
    }
  }

  return collapseText(control.getAttribute('placeholder') ?? '');
}

function directLegend(control: HTMLInputElement): HTMLLegendElement | undefined {
  const fieldset = control.closest('fieldset');
  return Array.from(fieldset?.children ?? []).find(
    (child): child is HTMLLegendElement =>
      child instanceof HTMLLegendElement,
  );
}

function humanizeName(name: string): string {
  const text = collapseText(name.replace(/[_-]+/g, ' '));
  return text ? `${text[0].toUpperCase()}${text.slice(1)}` : 'Selection';
}

function sharedLabelPrefix(options: FieldOption[]): string {
  if (options.length === 0) {
    return '';
  }
  if (options.length === 1) {
    return options[0].label;
  }

  const wordLists = options.map((option) => option.label.split(/\s+/));
  const prefix: string[] = [];
  for (let index = 0; index < wordLists[0].length; index += 1) {
    const word = wordLists[0][index];
    if (
      wordLists.every(
        (words) => words[index]?.toLocaleLowerCase() === word.toLocaleLowerCase(),
      )
    ) {
      prefix.push(word);
    } else {
      break;
    }
  }
  return collapseText(prefix.join(' ').replace(/[-–—,]+$/, ''));
}

function groupQuestion(
  control: HTMLInputElement,
  options: FieldOption[],
): string {
  const legend = directLegend(control);
  if (legend) {
    const text = cleanElementText(legend);
    if (text) {
      return text;
    }
  }
  return sharedLabelPrefix(options) || humanizeName(control.name);
}

function selectOptions(select: HTMLSelectElement): FieldOption[] {
  return Array.from(select.options)
    .filter((option) => !(option.disabled && option.value === ''))
    .map((option) => ({
      value: option.value,
      label: collapseText(option.textContent ?? option.label),
    }));
}

function optionalAttributes(
  control: FormControlElement,
): Pick<FormField, 'placeholder' | 'maxLength'> {
  const attributes: Pick<FormField, 'placeholder' | 'maxLength'> = {};
  if (
    (control instanceof HTMLInputElement ||
      control instanceof HTMLTextAreaElement) &&
    control.hasAttribute('placeholder')
  ) {
    attributes.placeholder = control.placeholder;
  }

  if (
    (control instanceof HTMLInputElement ||
      control instanceof HTMLTextAreaElement) &&
    control.hasAttribute('maxlength')
  ) {
    const maxLength = Number(control.getAttribute('maxlength'));
    if (Number.isFinite(maxLength)) {
      attributes.maxLength = maxLength;
    }
  }
  return attributes;
}

function isRequired(control: ExtractableFieldElement): boolean {
  return (
    ('required' in control && Boolean(control.required)) ||
    control.getAttribute('aria-required')?.toLocaleLowerCase() === 'true'
  );
}

export function ariaOptionValue(element: HTMLElement): string {
  return collapseText(
    element.getAttribute('data-value') ??
      element.getAttribute('data-answer-value') ??
      element.getAttribute('aria-label') ??
      cleanElementText(element),
  );
}

export function ariaOptionLabel(element: HTMLElement): string {
  return collapseText(
    element.getAttribute('aria-label') ?? cleanElementText(element),
  );
}

export function fieldFromTarget(target: ExtractableFieldTarget): FormField {
  const first = target.elements[0];
  if (target.type === 'contenteditable') {
    const label = resolveLabel(first);
    return {
      fieldId: target.fieldId,
      label,
      question: label,
      type: target.type,
      required: isRequired(first),
      options: [],
      currentValue: first.textContent ?? '',
    };
  }

  if (target.ariaWidget) {
    const group = target.groupElement ?? first;
    const optionElements = target.elements.filter(
      (element) =>
        element.getAttribute('role') === 'radio' ||
        element.getAttribute('role') === 'checkbox' ||
        element.getAttribute('role') === 'option',
    );
    const options = optionElements.map((element) => ({
      value: ariaOptionValue(element),
      label: ariaOptionLabel(element),
    }));
    const question =
      ariaGroupQuestion(group) ||
      sharedLabelPrefix(options) ||
      humanizeName(target.fieldId);
    return {
      fieldId: target.fieldId,
      label: question,
      question,
      type: target.type,
      required:
        group.getAttribute('aria-required')?.toLocaleLowerCase() === 'true' ||
        optionElements.some(
          (element) =>
            element.getAttribute('aria-required')?.toLocaleLowerCase() ===
            'true',
        ),
      options,
      currentValue: optionElements
        .filter(
          (element) =>
            element.getAttribute('aria-checked')?.toLocaleLowerCase() ===
              'true' ||
            element.getAttribute('aria-selected')?.toLocaleLowerCase() ===
              'true',
        )
        .map(ariaOptionValue)
        .join(', '),
    };
  }

  if (
    (target.type === 'radio' || target.type === 'checkbox') &&
    first instanceof HTMLInputElement
  ) {
    const inputs = target.elements.filter(
      (element): element is HTMLInputElement =>
        element instanceof HTMLInputElement,
    );
    const options = inputs.map((input) => ({
      value: input.value,
      label: resolveLabel(input),
    }));
    const question = groupQuestion(first, options);
    return {
      fieldId: target.fieldId,
      label: question,
      question,
      type: target.type,
      required: inputs.some(isRequired),
      options,
      currentValue: inputs
        .filter((input) => input.checked)
        .map((input) => input.value)
        .join(', '),
    };
  }

  const nativeFirst = first as FormControlElement;
  const label = resolveLabel(nativeFirst);
  return {
    fieldId: target.fieldId,
    label,
    question: label,
    type: target.type,
    required: isRequired(nativeFirst),
    options:
      nativeFirst instanceof HTMLSelectElement ? selectOptions(nativeFirst) : [],
    ...optionalAttributes(nativeFirst),
    currentValue: nativeFirst.value,
  };
}

function normalizeReadableText(value: string): string {
  return value.replace(/\s+/g, ' ').trim();
}

function isReadableElement(
  element: HTMLElement,
  root: Element,
  visibility: WeakMap<HTMLElement, boolean>,
): boolean {
  const trail: HTMLElement[] = [];
  for (
    let current: HTMLElement | null = element;
    current && root.contains(current);
    current = current.parentElement
  ) {
    const cached = visibility.get(current);
    if (cached !== undefined) {
      for (const item of trail) visibility.set(item, cached);
      return cached && isRendered(element);
    }
    trail.push(current);
    if (
      current.matches(READABLE_EXCLUDED_SELECTOR) ||
      current.hasAttribute('inert')
    ) {
      for (const item of trail) visibility.set(item, false);
      return false;
    }

    const style = window.getComputedStyle(current);
    if (
      style.display === 'none' ||
      style.visibility === 'hidden' ||
      style.visibility === 'collapse' ||
      style.opacity === '0'
    ) {
      for (const item of trail) visibility.set(item, false);
      return false;
    }
  }
  for (const item of trail) visibility.set(item, true);
  return isRendered(element);
}

/**
 * Extracts visible prose without disturbing the existing form/control
 * contract. Text nodes are grouped by their nearest block to retain useful
 * heading and paragraph boundaries without duplicating container text.
 */
export function extractReadableText(
  maxLength = READABLE_TEXT_LIMIT,
): string {
  const root =
    document.querySelector<HTMLElement>('main, [role="main"]') ??
    document.querySelector<HTMLElement>('article') ??
    document.body;
  if (!root || maxLength <= 0) {
    return '';
  }

  const blocks = new Map<Element, string>();
  const visibility = new WeakMap<HTMLElement, boolean>();
  let collectedLength = 0;
  const walker = document.createTreeWalker(
    root,
    window.NodeFilter.SHOW_TEXT,
  );
  for (
    let node = walker.nextNode();
    node;
    node = walker.nextNode()
  ) {
    const parent = node.parentElement;
    const value = node.nodeValue ?? '';
    if (
      !parent ||
      !/\S/.test(value) ||
      !isReadableElement(parent, root, visibility)
    ) {
      continue;
    }

    const closestBlock = parent.closest(READABLE_BLOCK_SELECTOR);
    const block =
      closestBlock && root.contains(closestBlock) ? closestBlock : root;
    const remaining = maxLength - collectedLength;
    if (remaining <= 0) break;
    const fragment = value.slice(0, remaining);
    blocks.set(block, `${blocks.get(block) ?? ''}${fragment}`);
    collectedLength += fragment.length;
  }

  const seen = new Set<string>();
  const chunks: string[] = [];
  for (const rawText of blocks.values()) {
    const text = normalizeReadableText(rawText);
    if (text && !seen.has(text)) {
      seen.add(text);
      chunks.push(text);
    }
  }

  return chunks.join('\n\n').slice(0, maxLength).trimEnd();
}

export function extractPage(): PageContext {
  const headingElement = document.querySelector('h1');
  const capabilities = enabledAssistantCapabilities();
  const fieldTargets = collectExtractableFieldTargets();
  const controlTargets = collectExtractableControlTargets();
  const fields = fieldTargets.map(fieldFromTarget);
  const controls = controlTargets.map(
    ({ controlId, role, disabled, element }) => ({
      controlId,
      label: controlLabel(element),
      role,
      disabled,
    }),
  );
  // This private cache keeps enough semantic identity to survive an SPA
  // re-render without changing the page/server wire contract.
  rememberExtractedTargets(fields, fieldTargets, controls, controlTargets);
  return {
    url: location.href,
    title: document.title,
    ...(headingElement
      ? { heading: cleanElementText(headingElement) }
      : {}),
    ...(ASSISTANT_FEATURES.readablePageText
      ? { readableText: extractReadableText() }
      : {}),
    capabilities,
    fields,
    controls,
  };
}

export function hasPageChanged(
  previous: PageContext,
  current: PageContext,
): boolean {
  if (previous.url !== current.url || previous.heading !== current.heading) {
    return true;
  }

  const previousFieldIds = new Set(previous.fields.map((field) => field.fieldId));
  const currentFieldIds = new Set(current.fields.map((field) => field.fieldId));
  return (
    previousFieldIds.size !== currentFieldIds.size ||
    [...previousFieldIds].some((fieldId) => !currentFieldIds.has(fieldId))
  );
}
