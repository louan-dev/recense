// Regression guard: FEAT-08
// Each of the 12 crossings alone, from a passage born in its starting state (pencil, keys, voice),
// with what the crossing must do on the page and its exact reverse (docs/law/purpose.md, "The twelve crossings").
import test from 'node:test';
import assert from 'node:assert/strict';

import {
  CROSSINGS,
  createMatter,
  seedInkPassage,
  seedTypePassage,
  seedVoicePassage,
  cross,
  reverseLast,
  checkMatter,
  findQuote,
  wordAt,
  mergeMatter
} from '../src/matter.js';

const T0 = Date.UTC(2026, 10, 14, 9, 0, 0);
const BODY = 'Saturday, November 14, 2026\nSections written apart stay side by side.\n\n<!-- page -->\n\nOlder page.';
const at = (device, input, k = 1) => ({ device, input, time: T0 + k * 60000 });
const SPOKEN = { audio: 'voice/a.m4a', words: [{ w: 'keep', t0: 0, t1: 0.3 }, { w: 'the', t0: 0.3, t1: 0.4 }, { w: 'gap', t0: 0.4, t1: 0.8 }] };

function inkPage() {
  const ink = { version: 1, removed: [], strokes: [
    { id: 's1', tool: 'pen', color: '#38bdf8', points: [[10, 30, 0.5], [60, 34, 0.6]], ocr: { g: 'g1', t: 'the interval' } },
    { id: 's2', tool: 'pen', color: '#38bdf8', points: [[70, 31, 0.5], [140, 35, 0.6]], ocr: { g: 'g1', t: 'is the music' } }
  ] };
  return seedInkPassage(createMatter({ text: BODY, ink }), { id: 'p1', strokeIds: ['s1', 's2'], seed: at('iPad', 'pencil', 0) });
}
function typePage() {
  return seedTypePassage(createMatter({ text: BODY }), { id: 'p1', quote: 'written apart', seed: at('Mac', 'keys', 0) });
}
function markPage() {
  return cross(typePage(), 3, 'p1', { seed: at('Mac', 'keys', 1) });
}
function voicePage() {
  return seedVoicePassage(createMatter({ text: BODY }), { id: 'p1', spoken: SPOKEN, seed: at('iPhone', 'voice', 0) });
}
const START = { ink: inkPage, type: typePage, mark: markPage, voice: voicePage };

function roundTrip(n, opts = {}) {
  const c = CROSSINGS.find(x => x.n === n);
  const before = START[c.from]();
  const after = cross(before, n, 'p1', { seed: at('Mac', 'touch', 5), ...opts });
  const r = checkMatter(after, { before, origin: before });
  assert.deepEqual(r.problems, [], `crossing ${n}: ${r.problems.join('; ')}`);
  assert.equal(after.side.passages.p1.phase, c.to);
  assert.deepEqual(reverseLast(after), before, `crossing ${n} reverses to the same matter`);
  return { before, after };
}

test('FEAT-08 #1 ink → type (melting): the handwriting enters the body under its line, on its page', () => {
  const { after } = roundTrip(1);
  assert.ok(after.text.startsWith('Saturday, November 14, 2026\nSections written apart stay side by side.\nthe interval is the music\n\n<!-- page -->'));
  assert.ok(after.text.endsWith('<!-- page -->\n\nOlder page.'));
  assert.equal(after.ink.strokes.length, 2, 'the strokes stay (nothing lost)');
  assert.equal(after.side.passages.p1.forms.type.quote, 'the interval is the music');
});

test('FEAT-08 #1 refuses to melt ink that has not been read yet (no guess enters the owner\'s text)', () => {
  const m = inkPage();
  for (const s of m.ink.strokes) delete s.ocr;
  assert.throws(() => cross(m, 1, 'p1', { seed: at('Mac', 'touch') }), /not been read/);
});

test('FEAT-08 #2 type → ink (freezing): the passage becomes a surface whose words strokes anchor to', () => {
  const { after } = roundTrip(2);
  const surf = after.side.passages.p1.forms.ink.surface;
  assert.deepEqual(surf.map(w => w.w), ['written', 'apart']);
  assert.deepEqual(surf[1], { w: 'apart', from: 8, to: 13 });
  assert.equal(wordAt(surf, 9).w, 'apart');
  assert.equal(wordAt(surf, 0).w, 'written');
  assert.equal(after.text, BODY, 'the body is untouched');
});

test('FEAT-08 #3 type → mark (vaporizing): a highlight anchored to the words, not to offsets', () => {
  const { after } = roundTrip(3);
  const mk = after.side.passages.p1.forms.mark;
  assert.equal(mk.kind, 'highlight');
  assert.equal(after.text, BODY);
  // the anchor survives an edit above it
  const edited = 'New first line\n' + after.text;
  assert.equal(findQuote(edited, after.side.passages.p1.forms.type), edited.indexOf('written apart'));
});

test('FEAT-08 #4 mark → type (condensing): the highlight becomes a quoted block, a margin note settles inline', () => {
  const { after } = roundTrip(4);
  assert.ok(after.text.includes('\n> Sections written apart stay side by side.\n'));
  // with a spoken note on the mark, the note settles on the next line
  let m = cross(markPage(), 8, 'p1', { seed: at('iPhone', 'voice', 2), spoken: SPOKEN, at: 3 });
  const before = m;
  m = cross(m, 4, 'p1', { seed: at('Mac', 'keys', 3) });
  assert.ok(m.text.includes('> Sections written apart stay side by side.\n> keep the gap\n'));
  assert.deepEqual(reverseLast(m), before);
});

test('FEAT-08 #5 ink → mark (subliming): a circled region becomes a comment, recognition skipped', () => {
  const { after } = roundTrip(5);
  const mk = after.side.passages.p1.forms.mark;
  assert.equal(mk.kind, 'region');
  assert.deepEqual(mk.region, { x: 10, y: 30, w: 130, h: 5 });
  assert.equal(mk.anchor.pageIndex, 0);
  assert.equal(after.text, BODY, 'no text enters the body');
});

test('FEAT-08 #6 mark → ink (deposition): the comment sets down as a stroke beside the passage', () => {
  let m = cross(markPage(), 8, 'p1', { seed: at('iPhone', 'voice', 2), spoken: SPOKEN, at: 3 });
  const before = m;
  m = cross(m, 6, 'p1', { seed: at('iPad', 'pencil', 3) });
  const st = m.ink.strokes.find(s => s.deposit === 'p1');
  assert.ok(st, 'a deposited stroke');
  assert.equal(st.ocr.t, 'keep the gap', 'Find reaches the comment in the ink');
  assert.equal(st.anchor.lineText, 'Sections written apart stay side by side.');
  assert.ok(m.side.passages.p1.forms.ink.strokes.includes(st.id));
  assert.deepEqual(checkMatter(m, { before, origin: before }).problems, []);
  assert.deepEqual(reverseLast(m), before);
  roundTrip(6);
});

test('FEAT-08 #7 mark → voice (ionizing): the marked range is planned for read-aloud with word times', () => {
  const { after } = roundTrip(7);
  const v = after.side.passages.p1.forms.voice;
  assert.equal(v.read.from, 'mark');
  assert.equal(v.read.text, 'written apart');
  assert.deepEqual(v.read.words.map(w => w.w), ['written', 'apart']);
  assert.ok(v.read.words[1].t0 >= v.read.words[0].t1);
});

test('FEAT-08 #8 voice → mark (recombining): a spoken aside lands as a timestamped margin note, not body text', () => {
  const { after } = roundTrip(8, { at: 4.2 });
  const mk = after.side.passages.p1.forms.mark;
  assert.equal(mk.kind, 'note');
  assert.equal(mk.note, 'keep the gap');
  assert.equal(mk.noteAt, 4.2);
  assert.equal(mk.noteAudio, 'voice/a.m4a');
  assert.equal(after.text, BODY);
});

test('FEAT-08 #9 type → voice: the typed passage read aloud, in its language', () => {
  const { after } = roundTrip(9);
  const v = after.side.passages.p1.forms.voice;
  assert.equal(v.read.from, 'type');
  assert.equal(v.read.text, 'written apart');
  const vi = seedTypePassage(createMatter({ text: 'Đoạn văn viết rời nhau.' }), { id: 'p1', quote: 'viết rời nhau', seed: at('Mac', 'keys') });
  assert.equal(cross(vi, 9, 'p1', { seed: at('Mac', 'keys', 2) }).side.passages.p1.forms.voice.read.lang, 'vi');
});

test('FEAT-08 #10 voice → type: speech becomes text once, its words keep their times and point into the body', () => {
  const { after } = roundTrip(10);
  assert.equal(after.text.split('keep the gap').length - 1, 1);
  const e = after.side.passages.p1.forms.voice.spoken[0];
  const off = findQuote(after.text, e.typed);
  assert.equal(after.text.slice(off, off + 12), 'keep the gap');
  // a second dictation of the same audio does not duplicate the words
  const again = cross(after, 10, 'p1', { seed: at('Mac', 'voice', 6) });
  assert.equal(again.text, after.text);
});

test('FEAT-08 #11 ink → voice: handwriting read aloud from its reading, the typed state skipped', () => {
  const { after } = roundTrip(11);
  const v = after.side.passages.p1.forms.voice;
  assert.equal(v.read.from, 'ink');
  assert.equal(v.read.text, 'the interval is the music');
  assert.equal(after.text, BODY);
  assert.equal(after.side.passages.p1.forms.type, undefined);
});

test('FEAT-08 #12 voice → ink: a spoken phrase pinned to a place on the page', () => {
  const { after } = roundTrip(12, { place: { pageIndex: 0, y: 30, x: 200 } });
  const pin = after.side.passages.p1.forms.ink.pins[0];
  assert.equal(pin.audio, 'voice/a.m4a');
  assert.equal(pin.anchor.lineText, 'Sections written apart stay side by side.');
  assert.equal(pin.anchor.relX, 200);
  assert.equal(after.text, BODY);
});

test('FEAT-08: a crossing from a state the passage does not hold is refused', () => {
  assert.throws(() => cross(typePage(), 5, 'p1', { seed: at('Mac', 'keys') }), /no ink/);
  assert.throws(() => cross(typePage(), 99, 'p1', {}), /unknown crossing/);
  assert.throws(() => cross(typePage(), 3, 'nope', {}), /no passage/);
});

test('FEAT-08: a crossing without a seed is refused (every passage traces back to its seed)', () => {
  assert.throws(() => cross(typePage(), 3, 'p1', {}), /seed/);
});

test('FEAT-08: two devices merge their sidecars: passages and spoken audio unioned, nothing lost or doubled', () => {
  const base = typePage();
  const mac = cross(base, 3, 'p1', { seed: at('Mac', 'keys', 2) });
  const phone = cross(base, 9, 'p1', { seed: at('iPhone', 'touch', 3) });
  const merged = mergeMatter(mac.side, phone.side);
  const p = merged.passages.p1;
  assert.ok(p.forms.mark && p.forms.voice && p.forms.type);
  assert.equal(p.phase, 'voice', 'the later move sets the phase');
  assert.equal(merged.log.length, 2);
  assert.deepEqual(mergeMatter(merged, merged), merged, 'merging twice changes nothing');
  const v1 = seedVoicePassage(createMatter({ text: BODY }), { id: 'p2', spoken: SPOKEN, seed: at('iPhone', 'voice') });
  const both = mergeMatter(v1.side, v1.side);
  assert.equal(both.passages.p2.forms.voice.spoken.length, 1);
});
