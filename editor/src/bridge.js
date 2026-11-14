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
    const state = getState();
    return state ? state.doc.toString() : '';
  }

  // Derived from Spec: BUG-04
  function setText(nextText) {
    const s = typeof nextText === 'string' ? nextText : String(nextText ?? '');
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
    clearPendingPost
  };
}
