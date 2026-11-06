import test from 'node:test';
import assert from 'node:assert/strict';

import { createEditorState } from '../src/index.js';
import { createEditorBridge, externalSetTextAnnotation } from '../src/bridge.js';
import { getRemoved } from '../src/removed.js';

test('M5: transaction filter records every user deletion with timestamp and surrounding context, exposed via getRemoved()', () => {
  const initial = 'First sentence stays. This middle clause is cut. Final sentence stays.';
  let { state } = createEditorState(initial);
  const fakeWindow = {};

  function dispatch(spec) {
    const tr = state.update(spec);
    state = tr.state;
  }

  createEditorBridge({
    getState: () => state,
    dispatch,
    getRemoved: () => getRemoved(state),
    globalObj: fakeWindow
  });

  const target = 'This middle clause is cut. ';
  const from = initial.indexOf(target);
  const to = from + target.length;

  dispatch({
    changes: { from, to, insert: '' },
    userEvent: 'delete'
  });

  const removed = fakeWindow.recenseEditor.getRemoved();
  assert.equal(removed.length, 1);
  assert.equal(removed[0].text, target);
  assert.equal(removed[0].from, from);
  assert.equal(removed[0].to, to);
  assert.equal(typeof removed[0].time, 'number');
  assert.ok(removed[0].before.endsWith('First sentence stays. '));
  assert.ok(removed[0].after.startsWith('Final sentence stays.'));
  assert.ok(removed[0].context.includes('First sentence stays.'));
  assert.ok(removed[0].context.includes('Final sentence stays.'));

  // External setText must not be recorded as a user deletion
  dispatch({
    changes: { from: 0, to: state.doc.length, insert: 'Replaced by sync' },
    annotations: externalSetTextAnnotation.of(true)
  });
  assert.equal(fakeWindow.recenseEditor.getRemoved().length, 1);
});
