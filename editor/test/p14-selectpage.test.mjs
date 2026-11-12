import test from 'node:test';
import assert from 'node:assert/strict';
import { EditorState, EditorSelection } from '@codemirror/state';
import { pageModeExtension, setPageMode, setPageIndex, selectPage } from '../src/pagemode.js';
import { PAGE_JOINER, inspectDraftpadPages } from '../src/pages.js';

const text = ['Friday, November 6, 2026\n\nTopic A', 'Monday, November 2, 2026\n\nTopic B'].join(PAGE_JOINER);
function fakeView(state) { return { get state() { return state; }, dispatch(s) { state = state.update(s).state; } }; }
function onPage(i) {
  const s = EditorState.create({ doc: text, extensions: pageModeExtension() });
  return s.update({ effects: [setPageMode.of(true), setPageIndex.of(i)] }).state;
}

test('Cmd+A selects only the shown page', () => {
  const pages = inspectDraftpadPages(text);
  for (const i of [0, 1]) {
    const v = fakeView(onPage(i));
    selectPage(v);
    const m = v.state.selection.main;
    assert.deepEqual([m.from, m.to], [pages[i].from, pages[i].to]);
    assert.ok(v.state.sliceDoc(m.from, m.to).includes(i ? 'Topic B' : 'Topic A'));
    assert.ok(!v.state.sliceDoc(m.from, m.to).includes(i ? 'Topic A' : 'Topic B'));
  }
});

test('menu Select All (whole-file selection) narrows to the shown page', () => {
  const pages = inspectDraftpadPages(text);
  const s = onPage(1).update({ selection: EditorSelection.single(0, text.length) }).state;
  assert.deepEqual([s.selection.main.from, s.selection.main.to], [pages[1].from, pages[1].to]);
});
