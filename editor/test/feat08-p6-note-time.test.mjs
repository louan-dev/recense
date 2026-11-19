// Derived from Spec: FEAT-08 P6
// The note time in the seed: a passage born in a media note keeps the item's second beside the text, never in it.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  createMatter, seedTypePassage, appendVoicePassage, toFiles, fromFiles, mergeMatter, FILES,
  noteTime, matterActions, menuForSelection, checkMatter
} from '../src/matter.js';

const read = p => readFileSync(new URL(p, import.meta.url), 'utf8');
const KEY = '0123456789abcdef01234567';
const seedAt = (t, extra = {}) => ({ device: 'iPhone', input: 'keys', time: t, ...extra });

test('FEAT-08 P6: at updateAudioTime(724.36) a new passage\'s seed has media.t = 724.3 (rounded down to 0.1 s)', () => {
  assert.equal(noteTime(724.36), 724.3);
  assert.equal(noteTime(724.3), 724.3, 'an exact tenth stays itself');
  assert.equal(noteTime(0), 0);
  assert.equal(noteTime(-1), null);
  assert.equal(noteTime(NaN), null);
  const m = seedTypePassage(createMatter({ text: 'The holding.\n' }), {
    id: 'p1', quote: 'The holding.', seed: seedAt(1, { media: { key: KEY, t: noteTime(724.36) } })
  });
  assert.deepEqual(m.side.passages.p1.seed.media, { key: KEY, t: 724.3 });
  assert.ok(!m.text.includes('724'), 'the time never enters the text');
  assert.deepEqual(checkMatter(m).problems, [], 'the five conditions are unchanged');
});

test('FEAT-08 P6: save → reload keeps media; a bad media field is not kept', () => {
  let m = seedTypePassage(createMatter({ text: 'A. B.\n' }), { id: 'p1', quote: 'A.', seed: seedAt(1, { media: { key: KEY, t: 12.5 } }) });
  m = seedTypePassage(m, { id: 'p2', quote: 'B.', seed: seedAt(2, { media: { key: 'NOTAKEY', t: 3 } }) });
  const back = fromFiles(toFiles(m));
  assert.deepEqual(back.side.passages.p1.seed.media, { key: KEY, t: 12.5 });
  assert.equal(back.side.passages.p2.seed.media, undefined);
  const v = appendVoicePassage(createMatter({ text: '' }), { id: 'v1', text: 'spoken aside', seed: seedAt(3, { input: 'voice', media: { key: KEY, t: 40 } }) });
  assert.deepEqual(v.side.passages.v1.seed.media, { key: KEY, t: 40 }, 'a dictated passage keeps it too');
});

test('FEAT-08 P6: two devices\' sidecars merge with both media fields kept', () => {
  const text = 'A. B.\n';
  const a = seedTypePassage(createMatter({ text }), { id: 'p1', quote: 'A.', seed: seedAt(1, { media: { key: KEY, t: 10 } }) });
  const bBase = seedTypePassage(createMatter({ text }), { id: 'p1', quote: 'A.', seed: seedAt(1) });
  const b = seedTypePassage(bBase, { id: 'p2', quote: 'B.', seed: seedAt(2, { device: 'Mac', media: { key: KEY, t: 20 } }) });
  for (const side of [mergeMatter(a.side, b.side), mergeMatter(b.side, a.side)]) {
    assert.deepEqual(side.passages.p1.seed.media, { key: KEY, t: 10 });
    assert.deepEqual(side.passages.p2.seed.media, { key: KEY, t: 20 });
  }
});

test('FEAT-08 P6: a sidecar from before this phase round-trips byte-identical', () => {
  const old = '{"version":1,"passages":{"p1":{"id":"p1","born":"type","seed":{"device":"Mac","input":"keys","time":1},"phase":"type","forms":{"type":{"quote":"A.","prefix":"","suffix":" B.\\n","from":{"cross":0,"device":"Mac","input":"keys","time":1}}}}},"log":[]}';
  const side = fromFiles({ [FILES.text]: 'A. B.\n', [FILES.side]: old }).side;
  assert.equal(toFiles(createMatter({ text: 'A. B.\n', side }))[FILES.side], old);
  assert.equal(JSON.stringify(mergeMatter(side, side)), old, 'a merge with itself changes no byte');
});

test('FEAT-08 P6: the Matter menu offers "Play from mm:ss" on a passage with media; it plays from t − 2.0, never below 0', () => {
  const m = seedTypePassage(createMatter({ text: 'Near. Start.\n' }), { id: 'p1', quote: 'Near.', seed: seedAt(1, { media: { key: KEY, t: 724.3 } }) });
  const play = matterActions(m, 'p1').find(a => a.id === 'play-from');
  assert.ok(play, 'listed');
  assert.equal(play.label, 'Play from 12:04');
  assert.deepEqual({ key: play.key, t: play.t }, { key: KEY, t: 722.3 });
  assert.equal(play.run(m), m, 'playing changes no matter');
  const sel = menuForSelection(m, 0, 5);
  assert.ok(sel.actions.some(a => a.id === 'play-from'), 'the selection menu lists it');
  const early = seedTypePassage(createMatter({ text: 'Intro.\n' }), { id: 'p1', quote: 'Intro.', seed: seedAt(1, { media: { key: KEY, t: 1.2 } }) });
  assert.equal(matterActions(early, 'p1').find(a => a.id === 'play-from').t, 0);
  const plain = seedTypePassage(createMatter({ text: 'Plain.\n' }), { id: 'p1', quote: 'Plain.', seed: seedAt(1) });
  assert.ok(!matterActions(plain, 'p1').some(a => a.id === 'play-from'), 'no media, no Play from');
});

test('FEAT-08 P6: the editor stamps media only in a media note, and a Play action is posted to the host', () => {
  const idx = read('../src/index.js');
  assert.ok(/media: \{ key: [^}]*noteTime\(/.test(idx), 'matterSeed adds media from the playhead in a note');
  assert.ok(idx.includes("if (action && action.play) return playMedia(action.key, action.t, 'passage')"), 'runMatter posts play for a Play from action');
});
