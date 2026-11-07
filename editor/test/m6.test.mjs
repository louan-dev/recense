import test from 'node:test';
import assert from 'node:assert/strict';

import { PAGE_JOINER } from '../src/pages.js';
import { hiddenRanges, pageModeField, setPageIndex, setPageMode, currentPage } from '../src/pagemode.js';
import { parseEmbedLine, embedSource, findEmbeds } from '../src/embeds.js';
import { urlAt, openURL } from '../src/links.js';
import { countMatches } from '../src/search.js';
import { SearchQuery } from '@codemirror/search';
import { createEditorState } from '../src/index.js';

const doc = ['Friday, November 6, 2026\n\nnewest', 'Monday, November 2, 2026\n\nmiddle', 'Thursday, October 8, 2026\n\nold']
  .join(PAGE_JOINER);

test('M6 pages: hidden ranges leave exactly one page visible, on whole lines', () => {
  for (let i = 0; i < 3; i++) {
    const hidden = hiddenRanges(doc, i);
    let shown = '';
    let pos = 0;
    for (const r of hidden) { shown += doc.slice(pos, r.from); pos = r.to; }
    shown += doc.slice(pos);
    const want = doc.split(PAGE_JOINER)[i];
    assert.equal(shown.replace(/^\n+|\n+$/g, ''), want, `page ${i}`);
    for (const r of hidden) {
      assert.ok(r.from === 0 || doc[r.from - 1] === '\n', 'starts at a line start');
      assert.ok(r.to === doc.length || doc[r.to] === '\n', 'ends at a line end');
    }
  }
  assert.deepEqual(hiddenRanges('one page only', 0), []);
});

test('M6 pages: page mode is on by default, page 0 is the top, and the cursor pulls the page along', () => {
  const { state } = createEditorState(doc);
  assert.equal(state.field(pageModeField).on, true);
  assert.equal(currentPage(state), 0);
  const deeper = state.update({ effects: setPageIndex.of(2) }).state;
  assert.equal(currentPage(deeper), 2);
  const back = deeper.update({ selection: { anchor: 3 } }).state;
  assert.equal(currentPage(back), 0, 'a cursor on page 0 shows page 0');
  const off = state.update({ effects: setPageMode.of(false) }).state;
  assert.equal(off.field(pageModeField).on, false);
  assert.equal(off.doc.toString(), doc, 'paging never changes the text');
});

test('M6 embeds: only a line holding just ![](…pdf|image) embeds', () => {
  assert.deepEqual(parseEmbedLine('![paper](https://x.org/a.pdf)'), { kind: 'pdf', target: 'https://x.org/a.pdf', caption: 'paper' });
  assert.equal(parseEmbedLine('![](ink/2026-11-06.png)').kind, 'image');
  assert.equal(parseEmbedLine('see ![](a.pdf) inline'), null);
  assert.equal(parseEmbedLine('![](notes.md)'), null);
  assert.equal(findEmbeds('a\n![](b.pdf)\nc')[0].end, 'a\n![](b.pdf)'.length);
});

test('M6 embeds: inside Recense, targets go through recense-file:', () => {
  assert.equal(embedSource('https://x.org/a b.pdf', true), 'recense-file://remote/https%3A%2F%2Fx.org%2Fa%20b.pdf');
  assert.equal(embedSource('Draftpad ink/a b.png', true), 'recense-file://vault/Draftpad%20ink/a%20b.png');
  assert.equal(embedSource('https://x.org/a.pdf', false), 'https://x.org/a.pdf');
});

test('M6 links: the URL under the cursor; Markdown links give their target', () => {
  const line = '- read [the paper](https://doi.org/10.1/x) and https://arxiv.org/pdf/2408.06449.';
  assert.equal(urlAt(line, 10), 'https://doi.org/10.1/x');
  assert.equal(urlAt(line, line.length - 5), 'https://arxiv.org/pdf/2408.06449');
  assert.equal(urlAt(line, 2), null);
  const posted = [];
  assert.equal(openURL('https://a.b', { webkit: { messageHandlers: { link: { postMessage: u => posted.push(u) } } } }), true);
  assert.deepEqual(posted, ['https://a.b']);
});

test('M6 find: counts matches case-insensitively', () => {
  const { state } = createEditorState('Patent patent PATENT pat');
  assert.equal(countMatches(state, new SearchQuery({ search: 'patent' })), 3);
  assert.equal(countMatches(state, new SearchQuery({ search: '' })), 0);
});

test('M6 insertBlock: the line lands under the cursor line and posts like typing', () => {
  const { state } = createEditorState('one\ntwo');
  const line = state.doc.lineAt(1);
  const next = state.update({ changes: { from: line.to, insert: '\n![](<Draftpad ink/a.png>)' } }).state;
  assert.equal(next.doc.toString(), 'one\n![](<Draftpad ink/a.png>)\ntwo');
  assert.equal(findEmbeds(next.doc.toString())[0].target, 'Draftpad ink/a.png');
  assert.equal(findEmbeds(next.doc.toString())[0].kind, 'image');
});
