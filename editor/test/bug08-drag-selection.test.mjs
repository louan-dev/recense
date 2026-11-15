// Regression guard: BUG-08
// T-0028 (owner, Mac, Select tool): "it deletes but the highlight is inaccurate and the cursor placement is all
// mixed up and confusing." Found in real WebKit (reviews/highlight-delete-repro.mjs and repro-mac-drag.mjs): a plain
// drag-select then Backspace is exact, but when the native host's setText round-trip (autosave / merge,
// strip/editorhost.swift) lands WHILE the pointer is still down, the drag's anchor is not remapped with the document.
// The owner drags over three lines and ends up with a shorter, wrong highlight (172 chars → 119), and the caret
// lands on another line after Delete. The document must never move under the owner's hand mid-selection
// (PLAYBOOK §2.5): the host's text waits for the pointer to come up, then applies once.
import test from 'node:test';
import assert from 'node:assert/strict';
import { EditorState } from '@codemirror/state';
import { createEditorBridge } from '../src/bridge.js';

function makeHarness(doc, { selecting = false } = {}) {
  let state = EditorState.create({ doc });
  let dispatches = 0;
  let isSelecting = selecting;
  const bridge = createEditorBridge({
    getState: () => state,
    dispatch: spec => { dispatches += 1; state = state.update(spec).state; },
    focusView: () => {},
    getScroll: () => null,
    setScroll: () => {},
    setTheme: () => {},
    setFontSize: () => {},
    isSelecting: () => isSelecting,
    globalObj: {}
  });
  return {
    bridge,
    getState: () => state,
    get dispatches() { return dispatches; },
    setSelecting: v => { isSelecting = v; }
  };
}

test('BUG-08: the host\'s setText waits while the owner is dragging a selection', () => {
  const h = makeHarness('AAA\nBBB\nCCC', { selecting: true });
  h.bridge.api.setText('ZZZ\nAAA\nBBB\nCCC');
  assert.equal(h.getState().doc.toString(), 'AAA\nBBB\nCCC', 'the document must not move while the pointer is down');
  assert.equal(h.dispatches, 0, 'no transaction while selecting');
});

test('BUG-08: it applies once, with the newest text, when the pointer comes up', () => {
  const h = makeHarness('AAA\nBBB\nCCC', { selecting: true });
  h.bridge.api.setText('ZZZ\nAAA\nBBB\nCCC');
  h.bridge.api.setText('ZZZ\nAAA\nBBB\nCCC\nDDD');   // a second round-trip arrives during the same drag
  h.setSelecting(false);
  h.bridge.applyDeferredText();
  assert.equal(h.getState().doc.toString(), 'ZZZ\nAAA\nBBB\nCCC\nDDD', 'the newest text wins');
  assert.equal(h.dispatches, 1, 'one transaction, not one per deferred round-trip');
});

test('BUG-08: applying twice changes nothing more; nothing is lost', () => {
  const h = makeHarness('AAA\nBBB', { selecting: true });
  h.bridge.api.setText('AAA\nBBB\nCCC');
  h.setSelecting(false);
  h.bridge.applyDeferredText();
  h.bridge.applyDeferredText();
  assert.equal(h.getState().doc.toString(), 'AAA\nBBB\nCCC');
  assert.equal(h.dispatches, 1);
});

test('BUG-08: with no drag in progress, setText still applies at once (BUG-04 behaviour kept)', () => {
  const h = makeHarness('AAA\nBBB');
  h.bridge.api.setText('ZZZ\nAAA\nBBB');
  assert.equal(h.getState().doc.toString(), 'ZZZ\nAAA\nBBB');
  assert.equal(h.dispatches, 1);
});

test('BUG-08: a deferred round-trip that matches what the owner typed meanwhile is dropped, not re-applied', () => {
  const h = makeHarness('AAA\nBBB', { selecting: true });
  h.bridge.api.setText('AAA\nBBB\nCCC');
  // the owner's own typing lands first (the pointer is up by the time this is dispatched by the editor itself)
  h.setSelecting(false);
  h.bridge.api.setText('AAA\nBBB\nCCC');
  const afterOwn = h.dispatches;
  h.bridge.applyDeferredText();
  assert.equal(h.dispatches, afterOwn, 'the deferred text is already in the document: no second transaction');
  assert.equal(h.getState().doc.toString(), 'AAA\nBBB\nCCC');
});
