import test from 'node:test';
import assert from 'node:assert/strict';

import { PAGE_JOINER } from '../src/pages.js';
import {
  parseHeadingLine,
  extractHeadings,
  computeHeadingFoldRange,
  orderPagesForOutline
} from '../src/outline.js';
import { isFindReplaceOpen } from '../src/search.js';
import { createEditorState } from '../src/index.js';

test('M2: parseHeadingLine recognizes Markdown ATX and § section headings', () => {
  assert.deepEqual(parseHeadingLine('# Contracts'), {
    kind: 'atx',
    level: 1,
    marker: '#',
    title: 'Contracts'
  });
  assert.deepEqual(parseHeadingLine('### Offer & Acceptance  '), {
    kind: 'atx',
    level: 3,
    marker: '###',
    title: 'Offer & Acceptance'
  });
  assert.deepEqual(parseHeadingLine('§ Negligence Per Se'), {
    kind: 'section',
    level: 1,
    marker: '§',
    title: 'Negligence Per Se'
  });
  assert.equal(parseHeadingLine('Plain paragraph text'), null);
});

test('M2: extractHeadings and computeHeadingFoldRange fold up to next peer heading or page marker', () => {
  const doc = [
    'Monday, November 2, 2026\n\n# Torts\nLine 1\n## Duty\nDuty body\n# Remedies\nRemedy body',
    'Friday, November 6, 2026\n\n§ Jurisdiction\nDiversity rules'
  ].join(PAGE_JOINER);

  const headings = extractHeadings(doc);
  assert.equal(headings.length, 4);
  assert.equal(headings[0].title, 'Torts');
  assert.equal(headings[0].pageIndex, 0);
  assert.equal(headings[1].title, 'Duty');
  assert.equal(headings[1].level, 2);
  assert.equal(headings[2].title, 'Remedies');
  assert.equal(headings[2].level, 1);
  assert.equal(headings[3].title, 'Jurisdiction');
  assert.equal(headings[3].kind, 'section');
  assert.equal(headings[3].pageIndex, 1);

  // "# Torts" fold stops before "# Remedies"
  const tortsFold = computeHeadingFoldRange(doc, headings[0].from);
  assert.ok(tortsFold);
  assert.equal(doc.slice(tortsFold.from, tortsFold.to), '\nLine 1\n## Duty\nDuty body');

  // "# Remedies" fold stops before "<!-- page -->"
  const remediesFold = computeHeadingFoldRange(doc, headings[2].from);
  assert.ok(remediesFold);
  assert.equal(doc.slice(remediesFold.from, remediesFold.to), '\nRemedy body');
});

test('M2: Outline "Newest first" orders pages by date line without reordering the document', () => {
  const olderPage = 'Monday, November 2, 2026\n\n# Older Topic\nBody A';
  const newestPage = 'Friday, November 6, 2026\n\n§ Newest Topic\nBody B';
  const middlePage = 'Wednesday, November 4, 2026\n\n# Middle Topic\nBody C';
  const undatedPage = 'Scratch notes without a date line';

  const doc = [olderPage, newestPage, middlePage, undatedPage].join(PAGE_JOINER);
  const { state } = createEditorState(doc);

  const naturalOrder = orderPagesForOutline(state.doc.toString(), { newestFirst: false });
  assert.deepEqual(
    naturalOrder.map(p => p.dateLine),
    [
      'Monday, November 2, 2026',
      'Friday, November 6, 2026',
      'Wednesday, November 4, 2026',
      null
    ]
  );

  const newestFirstOrder = orderPagesForOutline(state.doc.toString(), { newestFirst: true });
  assert.deepEqual(
    newestFirstOrder.map(p => p.dateLine),
    [
      'Friday, November 6, 2026',
      'Wednesday, November 4, 2026',
      'Monday, November 2, 2026',
      null
    ]
  );
  assert.equal(newestFirstOrder[0].headings[0].title, 'Newest Topic');

  // View-only: underlying document is byte-for-byte unchanged
  assert.equal(state.doc.toString(), doc);
});

test('M2: Search extension initializes cleanly in EditorState', () => {
  const { state } = createEditorState('Searchable text');
  assert.equal(isFindReplaceOpen(state), false);
});
