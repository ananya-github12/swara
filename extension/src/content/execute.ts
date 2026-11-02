import type { Action, ActionResult } from '../types';
import { ASSISTANT_FEATURES } from '../features';
import { getActionOverlay } from './actionOverlay';
import {
  ariaOptionLabel,
  ariaOptionValue,
  collectExtractableControlTargets,
  collectExtractableFieldTargets,
  controlLabel,
  fieldFromTarget,
  isExtractableControl,
  type ExtractableFieldElement,
  type ExtractableControlTarget,
  type FormControlElement,
} from './extract';
import {
  expectedControlFingerprint,
  expectedFieldFingerprint,
  findHealingMatch,
  fingerprintControl,
  fingerprintField,
} from './targetFingerprint';

type HighlightState = {
  outline: string;
  outlineOffset: string;
  timer: number;
};

const activeHighlights = new WeakMap<HTMLElement, HighlightState>();
const IRREVERSIBLE_CONTROL_LABEL =
  /\b(?:submit|apply|send|pay|purchase|buy|delete|remove|confirm|cancel)\b/i;

type HealingMetadata = {
  healed: true;
  healingConfidence: number;
};

type ContentActionResult = ActionResult & Partial<HealingMetadata>;

function isContentEditableElement(element: Element): element is HTMLElement {
  if (!(element instanceof HTMLElement)) {
    return false;
  }

  const editable = element.getAttribute('contenteditable');
  const hasEditableRole =
    element.getAttribute('role') === 'textbox' &&
    editable !== null &&
    editable.toLocaleLowerCase() !== 'false';
  const enabled =
    element.getAttribute('aria-disabled')?.toLocaleLowerCase() !== 'true';
  const rendered =
    element.offsetParent !== null ||
    window.getComputedStyle(element).position === 'fixed';

  return (
    (editable?.toLocaleLowerCase() === 'true' || hasEditableRole) &&
    enabled &&
    rendered
  );
}

function contentEditableWithIdentifier(
  fieldId: string,
): HTMLElement | undefined {
  if (!ASSISTANT_FEATURES.contentEditableFill) return undefined;
  const matches = Array.from(
    document.querySelectorAll(
      '[contenteditable="true"], [role="textbox"][contenteditable]',
    ),
  )
    .filter(isContentEditableElement)
    .filter(
      (element) =>
        element.getAttribute('name') === fieldId ||
        element.getAttribute('aria-label') === fieldId ||
        element.getAttribute('aria-labelledby') === fieldId,
    );
  return matches.length === 1 ? matches[0] : undefined;
}

function controlsWithName(name: string): FormControlElement[] {
  return Array.from(
    document.querySelectorAll('input, textarea, select'),
  ).filter(
    (element): element is FormControlElement =>
      isExtractableControl(element) &&
      element.getAttribute('name') === name,
  );
}

function resolveControls(fieldId: string): ExtractableFieldElement[] {
  const byId = document.getElementById(fieldId);
  if (
    byId &&
    (isExtractableControl(byId) ||
      (ASSISTANT_FEATURES.contentEditableFill &&
        isContentEditableElement(byId)))
  ) {
    return [byId];
  }

  const byName = controlsWithName(fieldId);
  if (byName.length > 0) {
    return byName;
  }

  const editable = contentEditableWithIdentifier(fieldId);
  if (editable) {
    return [editable];
  }

  const positional = collectExtractableFieldTargets().find(
    (target) => target.fieldId === fieldId,
  );
  return positional?.elements ?? [];
}

function resolvePageControl(controlId: string): ExtractableControlTarget | undefined {
  const controls = collectExtractableControlTargets();
  const byId = document.getElementById(controlId);
  if (byId) {
    const target = controls.find(({ element }) => element === byId);
    if (target) {
      return target;
    }
  }

  const byName = controls.find(
    ({ element }) => element.getAttribute('name') === controlId,
  );
  if (byName) {
    return byName;
  }

  return controls.find((target) => target.controlId === controlId);
}

function healedControls(
  fieldId: string,
): { controls: ExtractableFieldElement[]; healing: HealingMetadata } | undefined {
  const match = findHealingMatch(
    expectedFieldFingerprint(fieldId),
    collectExtractableFieldTargets().map((target) => ({
      target,
      fingerprint: fingerprintField(fieldFromTarget(target), target),
    })),
  );
  if (!match) return undefined;
  return {
    controls: match.target.elements,
    healing: { healed: true, healingConfidence: match.confidence },
  };
}

function healedPageControl(
  controlId: string,
): { control: ExtractableControlTarget; healing: HealingMetadata } | undefined {
  const expected = expectedControlFingerprint(controlId);
  // Submit/irreversible controls are never eligible for recovery. This guard
  // applies to both the original fingerprint and every live candidate.
  if (
    !expected ||
    expected.role === 'submit' ||
    IRREVERSIBLE_CONTROL_LABEL.test(expected.label)
  ) {
    return undefined;
  }
  const match = findHealingMatch(
    expected,
    collectExtractableControlTargets()
      .filter(
        (target) =>
          target.role !== 'submit' &&
          !IRREVERSIBLE_CONTROL_LABEL.test(controlLabel(target.element)),
      )
      .map((target) => ({
        target,
        fingerprint: fingerprintControl(
          {
            controlId: target.controlId,
            label: controlLabel(target.element),
            role: target.role,
            disabled: target.disabled,
          },
          target,
        ),
      })),
  );
  if (!match) return undefined;
  return {
    control: match.target,
    healing: { healed: true, healingConfidence: match.confidence },
  };
}

/** Resolve a visible extracted page target without changing it. */
export function resolveActionTarget(fieldId: string): HTMLElement | undefined {
  return resolvePageControl(fieldId)?.element ?? resolveControls(fieldId)[0];
}

function scrollIntoView(element: HTMLElement): void {
  element.scrollIntoView({ behavior: 'smooth', block: 'center' });
}

function focusAndBlur(
  element: HTMLElement,
  update: () => void,
): void {
  element.focus();
  try {
    update();
  } finally {
    element.blur();
  }
}

function dispatchValueEvents(element: HTMLElement): void {
  element.dispatchEvent(new Event('input', { bubbles: true }));
  element.dispatchEvent(new Event('change', { bubbles: true }));
}

function editableInputEvent(
  type: 'beforeinput' | 'input',
  value: string,
  inputType: 'insertText' | 'deleteContentBackward',
): Event {
  if (typeof window.InputEvent === 'function') {
    return new window.InputEvent(type, {
      bubbles: true,
      cancelable: type === 'beforeinput',
      composed: true,
      data: value || null,
      inputType,
    });
  }

  return new Event(type, {
    bubbles: true,
    cancelable: type === 'beforeinput',
    composed: true,
  });
}

function replaceContentEditableContents(
  element: HTMLElement,
  value: string,
): void {
  const inputType = value ? 'insertText' : 'deleteContentBackward';
  if (!element.dispatchEvent(editableInputEvent('beforeinput', value, inputType))) {
    throw new Error('The page cancelled the edit');
  }

  const selection = window.getSelection();
  if (!selection) {
    throw new Error('The browser selection API is unavailable');
  }

  const range = document.createRange();
  range.selectNodeContents(element);
  selection.removeAllRanges();
  selection.addRange(range);

  const execCommand = document.execCommand?.bind(document);
  const inserted =
    typeof execCommand === 'function' &&
    execCommand(value ? 'insertText' : 'delete', false, value);

  // jsdom and some isolated editors do not implement execCommand. The Range
  // fallback preserves the same select-all-and-replace semantics.
  if (!inserted) {
    range.deleteContents();
    if (value) {
      const text = document.createTextNode(value);
      range.insertNode(text);
      range.setStartAfter(text);
      range.collapse(true);
      selection.removeAllRanges();
      selection.addRange(range);
    }
  }

  element.dispatchEvent(editableInputEvent('input', value, inputType));
  element.dispatchEvent(new Event('change', { bubbles: true }));
}

function setContentEditableValue(element: HTMLElement, value: string): void {
  focusAndBlur(element, () => {
    replaceContentEditableContents(element, value);
  });
}

function setTextValue(
  element: HTMLInputElement | HTMLTextAreaElement,
  value: string,
): void {
  const prototype =
    element instanceof HTMLTextAreaElement
      ? HTMLTextAreaElement.prototype
      : HTMLInputElement.prototype;
  const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
  if (!setter) {
    throw new Error('Native value setter is unavailable');
  }

  focusAndBlur(element, () => {
    setter.call(element, value);
    dispatchValueEvents(element);
  });
}

function setSelectValue(element: HTMLSelectElement, value: string): void {
  const setter = Object.getOwnPropertyDescriptor(
    HTMLSelectElement.prototype,
    'value',
  )?.set;
  if (!setter) {
    throw new Error('Native select value setter is unavailable');
  }

  focusAndBlur(element, () => {
    setter.call(element, value);
    dispatchValueEvents(element);
  });
}

function setChecked(element: HTMLInputElement, checked: boolean): void {
  const setter = Object.getOwnPropertyDescriptor(
    HTMLInputElement.prototype,
    'checked',
  )?.set;
  if (!setter) {
    throw new Error('Native checked setter is unavailable');
  }

  focusAndBlur(element, () => {
    // Clicking from the opposite state gives controlled frameworks their
    // expected click/input/change sequence while ending deterministically.
    setter.call(element, !checked);
    element.click();
    if (element.checked !== checked) {
      setter.call(element, checked);
      dispatchValueEvents(element);
    }
  });
}

function highlight(element: HTMLElement): void {
  const existing = activeHighlights.get(element);
  if (existing) {
    window.clearTimeout(existing.timer);
  }
  const outline = existing?.outline ?? element.style.outline;
  const outlineOffset = existing?.outlineOffset ?? element.style.outlineOffset;

  element.style.outline = '2px solid #7c3aed';
  element.style.outlineOffset = '2px';
  const timer = window.setTimeout(() => {
    element.style.outline = outline;
    element.style.outlineOffset = outlineOffset;
    activeHighlights.delete(element);
  }, 1200);
  activeHighlights.set(element, { outline, outlineOffset, timer });
}

function textControl(
  controls: ExtractableFieldElement[],
): HTMLInputElement | HTMLTextAreaElement | undefined {
  return controls.find(
    (control): control is HTMLInputElement | HTMLTextAreaElement =>
      control instanceof HTMLTextAreaElement ||
      (control instanceof HTMLInputElement &&
        control.type !== 'radio' &&
        control.type !== 'checkbox'),
  );
}

function contentEditableControl(
  controls: ExtractableFieldElement[],
): HTMLElement | undefined {
  return controls.find(isContentEditableElement);
}

function matchingInput(
  controls: ExtractableFieldElement[],
  type: 'radio' | 'checkbox',
  value: string,
): HTMLInputElement | undefined {
  return controls.find(
    (control): control is HTMLInputElement =>
      control instanceof HTMLInputElement &&
      control.type === type &&
      control.value === value,
  );
}

function normalizedOptionLabel(value: string): string {
  return value.replace(/\s+/g, ' ').trim().toLocaleLowerCase();
}

function isAriaOption(
  element: ExtractableFieldElement,
  role: 'radio' | 'checkbox' | 'option',
): element is HTMLElement {
  return (
    !(element instanceof HTMLInputElement) &&
    !(element instanceof HTMLTextAreaElement) &&
    !(element instanceof HTMLSelectElement) &&
    element.getAttribute('role') === role
  );
}

function matchingAriaOption(
  controls: ExtractableFieldElement[],
  role: 'radio' | 'checkbox' | 'option',
  value: string,
): HTMLElement | undefined {
  const normalized = normalizedOptionLabel(value);
  return controls
    .filter((element) => isAriaOption(element, role))
    .find(
      (element) =>
        normalizedOptionLabel(ariaOptionValue(element)) === normalized ||
        normalizedOptionLabel(ariaOptionLabel(element)) === normalized,
    );
}

function ariaOptionState(element: HTMLElement): boolean {
  return (
    element.getAttribute('aria-checked')?.toLocaleLowerCase() === 'true' ||
    element.getAttribute('aria-selected')?.toLocaleLowerCase() === 'true'
  );
}

function clickAriaOption(element: HTMLElement): void {
  scrollIntoView(element);
  element.click();
}

function refreshedAriaSelectControls(
  fieldId: string,
  controls: ExtractableFieldElement[],
): ExtractableFieldElement[] {
  const group = controls.find(
    (element) =>
      element.getAttribute('role') === 'combobox' ||
      element.getAttribute('role') === 'listbox',
  );
  if (group?.getAttribute('role') === 'combobox') {
    scrollIntoView(group);
    group.click();
  }

  return (
    collectExtractableFieldTargets().find(
      (target) => target.fieldId === fieldId,
    )?.elements ?? controls
  );
}

function executeAction(
  controls: ExtractableFieldElement[],
  action: Action,
): HTMLElement {
  switch (action.action) {
    case 'fill':
    case 'clear': {
      const control = textControl(controls);
      const value = action.action === 'clear' ? '' : action.value;
      if (control) {
        setTextValue(control, value);
        return control;
      }

      const editable = contentEditableControl(controls);
      if (editable && ASSISTANT_FEATURES.contentEditableFill) {
        setContentEditableValue(editable, value);
        return editable;
      }

      throw new Error(
        `${action.action} requires a text input, textarea, or contenteditable`,
      );
    }

    case 'select': {
      const select = controls.find(
        (control): control is HTMLSelectElement =>
          control instanceof HTMLSelectElement,
      );
      if (select) {
        const availableOptions = Array.from(select.options).filter(
          (option) => !(option.disabled && option.value === ''),
        );
        const option =
          availableOptions.find((candidate) => candidate.value === action.value) ??
          availableOptions.find(
            (candidate) =>
              normalizedOptionLabel(
                candidate.textContent ?? candidate.label,
              ) === normalizedOptionLabel(action.value),
          );
        if (!option) {
          throw new Error(`Select option "${action.value}" was not found`);
        }
        setSelectValue(select, option.value);
        return select;
      }

      const ariaRadio = matchingAriaOption(controls, 'radio', action.value);
      if (ariaRadio) {
        clickAriaOption(ariaRadio);
        return ariaRadio;
      }

      const refreshedControls = refreshedAriaSelectControls(
        action.fieldId,
        controls,
      );
      const ariaListboxOption = matchingAriaOption(
        refreshedControls,
        'option',
        action.value,
      );
      if (ariaListboxOption) {
        clickAriaOption(ariaListboxOption);
        return ariaListboxOption;
      }

      if (
        controls.some(
          (control) =>
            control.getAttribute('role') === 'combobox' ||
            control.getAttribute('role') === 'listbox' ||
            control.getAttribute('role') === 'option',
        )
      ) {
        throw new Error(`ARIA select option "${action.value}" was not found`);
      }

      const radio = matchingInput(controls, 'radio', action.value);
      if (!radio) {
        throw new Error(`Radio option "${action.value}" was not found`);
      }
      setChecked(radio, true);
      return radio;
    }

    case 'check':
    case 'uncheck': {
      const ariaCheckbox = matchingAriaOption(
        controls,
        'checkbox',
        action.value,
      );
      if (ariaCheckbox) {
        const desired = action.action === 'check';
        if (ariaOptionState(ariaCheckbox) !== desired) {
          clickAriaOption(ariaCheckbox);
        }
        return ariaCheckbox;
      }

      const checkbox = matchingInput(controls, 'checkbox', action.value);
      if (!checkbox) {
        throw new Error(`Checkbox option "${action.value}" was not found`);
      }
      setChecked(checkbox, action.action === 'check');
      return checkbox;
    }

    case 'click':
    case 'scroll_to':
    case 'open_url':
    case 'navigate':
    case 'open_tab':
    case 'switch_tab':
    case 'close_tab':
    case 'go_back':
    case 'go_forward':
    case 'wait_for_page':
      throw new Error(`${action.action} is not a field action`);
  }
}

export function executeActions(actions: Action[]): ActionResult[] {
  return actions.map((action, index) => {
    const overlay = getActionOverlay();
    const step = { current: index + 1, total: actions.length };
    const title = action.reasoning ?? `Preparing to ${action.action.replace('_', ' ')}`;
    // This is visual-only: it has no event handlers and never affects the
    // page's form controls. The existing synchronous executor API remains
    // unchanged for callers that do not care about the presentation layer.
    overlay.show({ status: 'waiting', step, title, reason: action.reasoning });
    try {
      if (action.action === 'click') {
        const exactControl = resolvePageControl(action.fieldId);
        const recoveredControl = exactControl
          ? undefined
          : healedPageControl(action.fieldId);
        const control = exactControl ?? recoveredControl?.control;
        if (!control) {
          throw new Error(`Control "${action.fieldId}" was not found`);
        }
        if (control.role === 'submit') {
          overlay.show({
            target: control.element,
            status: 'confirmation',
            step,
            title: 'Final submission needs your confirmation',
            reason: 'Swara will not submit forms for you.',
          });
          return {
            fieldId: action.fieldId,
            ok: false,
            error: 'Refused: submitting is left to you.',
          };
        }
        overlay.show({
          target: control.element,
          status: 'executing',
          step,
          title,
          reason: action.reasoning,
        });
        scrollIntoView(control.element);
        control.element.click();
        highlight(control.element);
        overlay.show({
          target: control.element,
          status: 'success',
          step,
          title: 'Action completed',
          reason: action.reasoning,
        });
        if (index === actions.length - 1) overlay.hideAfter();
        return {
          fieldId: action.fieldId,
          ok: true,
          ...recoveredControl?.healing,
        } satisfies ContentActionResult;
      }

      if (action.action === 'scroll_to') {
        const exactControl = resolvePageControl(action.fieldId);
        const exactField = exactControl ? [] : resolveControls(action.fieldId);
        const recoveredControl = exactControl
          ? undefined
          : exactField.length > 0
            ? undefined
            : healedPageControl(action.fieldId);
        const recoveredField = exactControl || exactField.length > 0 || recoveredControl
          ? undefined
          : healedControls(action.fieldId);
        const target =
          exactControl?.element ??
          exactField[0] ??
          recoveredControl?.control.element ??
          recoveredField?.controls[0];
        if (!target) {
          throw new Error(`Target "${action.fieldId}" was not found`);
        }
        overlay.show({
          target,
          status: 'executing',
          step,
          title,
          reason: action.reasoning,
        });
        scrollIntoView(target);
        highlight(target);
        overlay.show({
          target,
          status: 'success',
          step,
          title: 'Target located',
          reason: action.reasoning,
        });
        if (index === actions.length - 1) overlay.hideAfter();
        return {
          fieldId: action.fieldId,
          ok: true,
          ...recoveredControl?.healing,
          ...recoveredField?.healing,
        } satisfies ContentActionResult;
      }

      const exactControls = resolveControls(action.fieldId);
      const recoveredField = exactControls.length > 0
        ? undefined
        : healedControls(action.fieldId);
      const controls = exactControls.length > 0
        ? exactControls
        : recoveredField?.controls ?? [];
      if (controls.length === 0) {
        throw new Error(`Field "${action.fieldId}" was not found`);
      }
      overlay.show({
        target: controls[0],
        status: 'executing',
        step,
        title,
        reason: action.reasoning,
      });
      const changedElement = executeAction(controls, action);
      highlight(changedElement);
      overlay.show({
        target: changedElement,
        status: 'success',
        step,
        title: 'Action completed',
        reason: action.reasoning,
      });
      if (index === actions.length - 1) overlay.hideAfter();
      return {
        fieldId: action.fieldId,
        ok: true,
        ...recoveredField?.healing,
      } satisfies ContentActionResult;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      overlay.show({
        status: 'failure',
        step,
        title: 'Action could not be completed',
        reason: message,
      });
      if (index === actions.length - 1) overlay.hideAfter();
      return {
        fieldId: action.fieldId,
        ok: false,
        error: message,
      };
    }
  });
}
