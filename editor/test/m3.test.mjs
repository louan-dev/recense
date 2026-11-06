import test from 'node:test';
import assert from 'node:assert/strict';

import {
  toRoman,
  fromRoman,
  toAlpha,
  fromAlpha,
  parseLegalItem,
  renumberLegalLists,
  continueLegalOnEnter,
  shiftLegalLevelAtCursor,
  isSectionHeadingLine
} from '../src/legal.js';
import { createEditorState } from '../src/index.js';

test('M3: Roman and alpha helpers convert accurately', () => {
  assert.equal(toRoman(1), 'i');
  assert.equal(toRoman(4), 'iv');
  assert.equal(toRoman(9), 'ix');
  assert.equal(fromRoman('iv'), 4);
  assert.equal(fromRoman('ix'), 9);
  assert.equal(toAlpha(1), 'a');
  assert.equal(toAlpha(26), 'z');
  assert.equal(fromAlpha('a'), 1);
  assert.equal(fromAlpha('z'), 26);
});

test('M3: Enter continues numbered items in the same style (1. / 1.1 / (a) / (i))', () => {
  const step1 = continueLegalOnEnter('1. Offer', '1. Offer'.length);
  assert.equal(step1.text, '1. Offer\n2. ');

  const step2 = continueLegalOnEnter('1. Offer\n   1.1 Intent', '1. Offer\n   1.1 Intent'.length);
  assert.equal(step2.text, '1. Offer\n   1.1 Intent\n   1.2 ');

  const step3 = continueLegalOnEnter(
    '1. Offer\n   1.1 Intent\n      (a) Objective test',
    '1. Offer\n   1.1 Intent\n      (a) Objective test'.length
  );
  assert.equal(
    step3.text,
    '1. Offer\n   1.1 Intent\n      (a) Objective test\n      (b) '
  );

  const step4 = continueLegalOnEnter(
    '1. Offer\n   1.1 Intent\n      (a) Objective test\n         (i) Reasonable person',
    '1. Offer\n   1.1 Intent\n      (a) Objective test\n         (i) Reasonable person'.length
  );
  assert.equal(
    step4.text,
    '1. Offer\n   1.1 Intent\n      (a) Objective test\n         (i) Reasonable person\n         (ii) '
  );
});

test('M3: Tab demotes and Shift-Tab promotes through 1. -> 1.1 -> (a) -> (i)', () => {
  let doc = '1. First point\n2. Second point';
  const cursor = doc.indexOf('Second');

  // Demote 2. -> 1.1
  let res = shiftLegalLevelAtCursor(doc, cursor, +1);
  assert.equal(res.text, '1. First point\n   1.1 Second point');

  // Demote 1.1 -> (a)
  res = shiftLegalLevelAtCursor(res.text, res.cursor, +1);
  assert.equal(res.text, '1. First point\n      (a) Second point');

  // Demote (a) -> (i)
  res = shiftLegalLevelAtCursor(res.text, res.cursor, +1);
  assert.equal(res.text, '1. First point\n         (i) Second point');

  // Promote (i) -> (a)
  res = shiftLegalLevelAtCursor(res.text, res.cursor, -1);
  assert.equal(res.text, '1. First point\n      (a) Second point');

  // Promote (a) -> 1.1
  res = shiftLegalLevelAtCursor(res.text, res.cursor, -1);
  assert.equal(res.text, '1. First point\n   1.1 Second point');

  // Promote 1.1 -> 2.
  res = shiftLegalLevelAtCursor(res.text, res.cursor, -1);
  assert.equal(res.text, '1. First point\n2. Second point');
});

test('M3: Items renumber automatically after a move or a delete', () => {
  const initial = [
    '1. Duty',
    '   1.1 Foreseeability',
    '   1.2 Special relationships',
    '2. Breach',
    '3. Causation'
  ].join('\n');

  // Simulate deleting "2. Breach\n" inside CodeMirror transaction
  const { state } = createEditorState(initial);
  const breachStart = initial.indexOf('2. Breach');
  const causationStart = initial.indexOf('3. Causation');
  const tr = state.update({
    changes: { from: breachStart, to: causationStart, insert: '' }
  });

  assert.equal(
    tr.state.doc.toString(),
    [
      '1. Duty',
      '   1.1 Foreseeability',
      '   1.2 Special relationships',
      '2. Causation'
    ].join('\n')
  );

  // Simulate moving "   1.2 Special relationships" above "   1.1 Foreseeability"
  const moved = renumberLegalLists([
    '1. Duty',
    '   1.2 Special relationships',
    '   1.1 Foreseeability',
    '2. Causation'
  ].join('\n'));
  assert.equal(
    moved,
    [
      '1. Duty',
      '   1.1 Special relationships',
      '   1.2 Foreseeability',
      '2. Causation'
    ].join('\n')
  );
});

test('M3: Lines starting with § are recognized as section headings and reset list numbering', () => {
  assert.equal(isSectionHeadingLine('§ Consideration'), true);
  assert.equal(isSectionHeadingLine('Normal line'), false);

  const doc = [
    '§ Offer',
    '1. First',
    '2. Second',
    '§ Acceptance',
    '5. Starts fresh at one'
  ].join('\n');
  assert.equal(
    renumberLegalLists(doc),
    [
      '§ Offer',
      '1. First',
      '2. Second',
      '§ Acceptance',
      '1. Starts fresh at one'
    ].join('\n')
  );
});
