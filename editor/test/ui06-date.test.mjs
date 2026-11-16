// Derived from Spec: UI-06 (D1–D3)
import test from 'node:test';
import assert from 'node:assert/strict';
import { PAGE_JOINER, formatDateLine, parseDateLine, discreetDate, isWindowEmpty, inspectDraftpadPages } from '../src/pages.js';
import { newPage, openNewWindowOnLeft } from '../src/pagemode.js';
import { createEditorState } from '../src/index.js';

const NOW = new Date(2026, 10, 15, 9, 30).getTime(); // Sunday 15 Nov 2026, local time

function makeFakeView(doc) {
  let { state } = createEditorState(doc);
  return {
    get state() { return state; },
    scrollDOM: { scrollTop: 0, scrollTo() {} },
    dispatch(spec) { state = state.update(spec).state; }
  };
}

test('D1: the date line keeps its machine form and parses back', () => {
  assert.equal(formatDateLine(NOW), 'Sunday, November 15, 2026');
  assert.equal(new Date(parseDateLine(formatDateLine(NOW))).getDate(), 15);
});

test('D2: the label is short, in the device language, with Today / Yesterday', () => {
  assert.equal(discreetDate(NOW, NOW, 'en'), 'Today');
  assert.equal(discreetDate(NOW - 864e5, NOW, 'en'), 'Yesterday');
  const older = new Date(2026, 10, 12).getTime();
  assert.equal(discreetDate(older, NOW, 'en-GB'), 'Thu 12 Nov');
  assert.ok(!/2026/.test(discreetDate(older, NOW, 'fr')), 'this year: no year');
  assert.ok(/2025/.test(discreetDate(new Date(2025, 0, 3).getTime(), NOW, 'en-GB')), 'another year: with year');
});

test('D3: a new page gets today\'s date line; the caret lands under it; it still counts as empty', () => {
  const view = makeFakeView('Older text');
  assert.equal(openNewWindowOnLeft(view, { now: NOW }), true);
  const text = view.state.doc.toString();
  assert.ok(text.startsWith('Sunday, November 15, 2026\n\n' + PAGE_JOINER.trimStart()) || text.startsWith('Sunday, November 15, 2026\n\n'));
  const p0 = inspectDraftpadPages(text)[0];
  assert.equal(p0.dateLine, 'Sunday, November 15, 2026');
  assert.equal(isWindowEmpty(p0.rawContent), true);
  assert.equal(view.state.selection.main.head, 'Sunday, November 15, 2026\n\n'.length);
  assert.equal(newPage(view, { now: NOW }), false, 'front page is already empty');
});

test('D2: the date label is styled small, muted, top right, not selectable', async () => {
  const { readFileSync } = await import('node:fs');
  const css = readFileSync(new URL('../src/styles.css', import.meta.url), 'utf8');
  const rule = /\.cm-page-date-label \{([^}]*)\}/.exec(css);
  assert.ok(rule, 'label is styled');
  for (const want of ['text-align: right', 'font-size: 11px', 'var(--rc-muted)', 'opacity: 0.6', 'user-select: none']) {
    assert.ok(rule[1].includes(want), want);
  }
});
