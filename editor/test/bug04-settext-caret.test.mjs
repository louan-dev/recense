// Regression guard: BUG-04
// T-0001: Enter inserts the line break correctly (confirmed in-page), but the native host's
// window.recenseEditor.setText(s) — called after every autosave/merge round-trip — put the
// caret back at its OLD raw character offset, only clamped to the new text's length. Any
// round-trip that changes content BEFORE the caret (a merge, a normalization pass, anything)
// left the caret pointing at an earlier line than before: "new text floats on top, doesn't
// indent below."
import test from 'node:test';
import assert from 'node:assert/strict';
import { EditorState } from '@codemirror/state';
import { createEditorBridge } from '../src/bridge.js';

function makeHarness(doc, selHead) {
  let state = EditorState.create({ doc });
  state = state.update({ selection: { anchor: selHead, head: selHead } }).state;
  const bridge = createEditorBridge({
    getState: () => state,
    dispatch: spec => { state = state.update(spec).state; },
    focusView: () => {},
    getScroll: () => null,
    setScroll: () => {},
    setTheme: () => {},
    setFontSize: () => {},
    globalObj: {}
  });
  return { bridge, getState: () => state };
}

test('BUG-04: setText keeps the caret anchored to its line when a round-trip inserts text earlier in the doc', () => {
  // Caret sits right before "BBB" (after the break Enter just inserted), as if the user is
  // about to type on the new line.
  const { bridge, getState } = makeHarness('AAA\nBBB', 4);
  assert.equal(getState().sliceDoc(getState().selection.main.head), 'BBB');

  // The native host's save/merge round-trip comes back with a line inserted BEFORE the caret's
  // line (e.g. an adopted edit, a merge, a normalization) but otherwise leaves "AAA\nBBB" intact.
  bridge.api.setText('ZZZ\nAAA\nBBB');

  const state = getState();
  assert.equal(state.doc.toString(), 'ZZZ\nAAA\nBBB');
  // The caret must still sit right before "BBB" — mapped forward through the insertion —
  // not at its old raw offset (which now falls inside "AAA").
  assert.equal(state.sliceDoc(state.selection.main.head), 'BBB');
});

test('BUG-04: setText is a no-op when the native text matches the live doc byte-for-byte', () => {
  const { bridge, getState } = makeHarness('AAA\nBBB', 4);
  const before = getState();
  bridge.api.setText('AAA\nBBB');
  const after = getState();
  assert.equal(after.doc.toString(), before.doc.toString());
  assert.equal(after.selection.main.head, before.selection.main.head);
});
