import { Annotation, Transaction } from '@codemirror/state';
import { computeMinimalTextChange } from './legal.js';

export const DEBOUNCE_MS = 300;

/**
 * Marks transactions originating from `window.recenseEditor.setText(s)` so they:
 * 1. Never echo a `postMessage` back to the native host.
 * 2. Preserve the host's incoming file text byte-for-byte without auto-renumbering.
 */
export const externalSetTextAnnotation = Annotation.define();

/**
 * Posts `{ haptic: kind }` (`'snap' | 'edge' | 'open'`) to `window.webkit.messageHandlers.ui`.
 */
export function postHaptic(kind, globalObj = typeof window !== 'undefined' ? window : null) {
  if (!kind) return false;
  const h =
    globalObj &&
    globalObj.webkit &&
    globalObj.webkit.messageHandlers &&
    globalObj.webkit.messageHandlers.ui;
  if (h && typeof h.postMessage === 'function') {
    h.postMessage({ haptic: String(kind) });
    return true;
  }
  return false;
}

/**
 * Creates the debounced native bridge (`window.recenseEditor`) and change notifier
 * (`window.webkit.messageHandlers.editor.postMessage(fullText)`).
 */
export function createEditorBridge({
  getState,
  dispatch,
  focusView,
  getScroll,
  setScroll,
  setTheme,
  setFontSize,
  getRemoved = () => [],
  // Derived from Spec: BUG-08 — true while the owner is dragging a selection (pointer down in the text).
  isSelecting = () => false,
  // Derived from Spec: FEAT-23 rule 2 — while a media note is shown: its saves go to the note (true = taken), the
  // host's flush still reads draftpad.md, and the host's draftpad text waits beside the note.
  routeText = null,
  hostText = null,
  absorbText = null,
  extra = {},
  globalObj = typeof window !== 'undefined' ? window : {},
  debounceMs = DEBOUNCE_MS
}) {
  let debounceTimer = null;

  function clearPendingPost() {
    if (debounceTimer !== null) {
      clearTimeout(debounceTimer);
      debounceTimer = null;
    }
  }

  function postToNative(text) {
    if (typeof routeText === 'function' && routeText(text)) return;
    const handler =
      globalObj &&
      globalObj.webkit &&
      globalObj.webkit.messageHandlers &&
      globalObj.webkit.messageHandlers.editor;
    if (handler && typeof handler.postMessage === 'function') {
      handler.postMessage(text);
    }
  }

  function notifyDocChanged(transactions = []) {
    const isExternal = transactions.some(tr => Boolean(tr.annotation(externalSetTextAnnotation)));
    if (isExternal) {
      return;
    }
    clearPendingPost();
    debounceTimer = setTimeout(() => {
      debounceTimer = null;
      const state = getState();
      if (state) {
        postToNative(state.doc.toString());
      }
    }, debounceMs);
  }

  function flushPendingPost() {
    if (debounceTimer !== null) {
      clearTimeout(debounceTimer);
      debounceTimer = null;
      const state = getState();
      if (state) {
        postToNative(state.doc.toString());
      }
    }
  }

  function getText() {
    if (typeof hostText === 'function') return hostText();
    const state = getState();
    return state ? state.doc.toString() : '';
  }

  // Derived from Spec: BUG-08. The host's round-trips (autosave, a merge from another device) arrive whenever they
  // are ready, including while the owner is holding the pointer down over text. CodeMirror maps the stored selection
  // through a change, but a drag in progress keeps extending from the anchor the gesture started with, so the
  // document moving mid-drag leaves a highlight that is not what was dragged over, and a caret on another line after
  // Delete. Nothing may move under the owner's hand (PLAYBOOK §2.5): the newest text waits here and is applied once,
  // by applyDeferredText(), as soon as the pointer comes up. Nothing is dropped — only delayed.
  let deferredText = null;

  function applyDeferredText() {
    if (deferredText === null) return false;
    const text = deferredText;
    deferredText = null;
    return applyText(text);
  }

  // Derived from Spec: BUG-04
  function setText(nextText) {
    const s = typeof nextText === 'string' ? nextText : String(nextText ?? '');
    if (typeof absorbText === 'function' && absorbText(s)) return;
    if (typeof isSelecting === 'function' && isSelecting()) {
      deferredText = s;          // the newest round-trip wins; it lands when the drag ends
      return;
    }
    return applyText(s);
  }

  function applyText(s) {
    flushPendingPost();
    const state = getState();
    if (!state) return;
    const current = state.doc.toString();
    if (s === current) return;

    const scroll = typeof getScroll === 'function' ? getScroll() : null;

    // BUG-04 (T-0001): this used to replace the whole document (`from: 0, to: current.length`)
    // and then force the selection back to its OLD raw offset, only clamped to the new text's
    // length. Any round-trip that changed content before the caret (a merge, a save-path
    // normalization) left the caret pointing at stale content — one line earlier than before.
    // Dispatching only the minimal changed region, with no explicit `selection`, lets CodeMirror
    // map the existing selection through that change automatically, keeping the caret anchored
    // to the same unchanged content on either side of the edit.
    const change = computeMinimalTextChange(current, s);

    dispatch({
      changes: change,
      annotations: [
        externalSetTextAnnotation.of(true),
        Transaction.addToHistory.of(false)
      ]
    });

    if (scroll && typeof setScroll === 'function') {
      setScroll(scroll);
    }
  }

  function focus() {
    if (typeof focusView === 'function') {
      focusView();
    }
  }

  const api = {
    ...extra,
    setText,
    getText,
    focus,
    setTheme(mode) {
      if (typeof setTheme === 'function') setTheme(mode);
    },
    setFontSize(px) {
      if (typeof setFontSize === 'function') setFontSize(px);
    },
    getRemoved() {
      return typeof getRemoved === 'function' ? getRemoved() : [];
    }
  };

  if (globalObj) {
    globalObj.recenseEditor = api;
  }

  return {
    api,
    notifyDocChanged,
    clearPendingPost,
    flushPendingPost,
    // Derived from Spec: BUG-08 — the host called while the owner was dragging; this lands it once, after.
    applyDeferredText
  };
}
