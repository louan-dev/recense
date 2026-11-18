// Regression guard: FEAT-08 P2 (voice continuation from any device and while moving)
// Spoken words land at the end of the page as their own passage, born as voice and already typed: one blank line
// before them, the seed kept, "Make text" never types them twice, and a passage written by the native host
// (shared/voiceappend.swift, no page open) survives the page's next save through mergeMatter.
import test from 'node:test';
import assert from 'node:assert/strict';

import { createMatter, appendVoicePassage, seedTypePassage, cross, mergeMatter, checkMatter, findQuote } from '../src/matter.js';

const seed = (device = 'iPhone', time = 1000) => ({ device, input: 'voice', time });

test('FEAT-08 P2: one blank line before the spoken passage, whatever the page ends with', () => {
  for (const [body, want] of [['note', 'note\n\nsaid'], ['note\n', 'note\n\nsaid'], ['note\n\n', 'note\n\nsaid'], ['', 'said']]) {
    const before = createMatter({ text: body });
    const after = appendVoicePassage(before, { id: 'v1', text: '  said \n', seed: seed() });
    assert.equal(after.text, want);
    assert.deepEqual(checkMatter(after, { before }).problems, []);
  }
});

test('FEAT-08 P2: the passage keeps its seed, born voice, and its words point into the body', () => {
  const m = appendVoicePassage(createMatter({ text: 'Le contrat' }), { id: 'v1', text: 'Tòa tuyên hợp đồng vô hiệu.', seed: seed('iPad', 42) });
  const p = m.side.passages.v1;
  assert.equal(p.born, 'voice');
  assert.deepEqual(p.seed, { device: 'iPad', input: 'voice', time: 42 });
  assert.equal(m.text.slice(findQuote(m.text, p.forms.type)), 'Tòa tuyên hợp đồng vô hiệu.');
  assert.equal(p.forms.voice.spoken[0].typed.quote, 'Tòa tuyên hợp đồng vô hiệu.');
});

test('FEAT-08 P2: "Make text" never types the spoken passage twice', () => {
  const m = appendVoicePassage(createMatter({ text: 'note' }), { id: 'v1', text: 'said', seed: seed() });
  const after = cross(m, 10, 'v1', { seed: seed('Mac', 2000) });
  assert.equal(after.text, 'note\n\nsaid');
  assert.deepEqual(checkMatter(after, { before: m }).problems, []);
});

test('FEAT-08 P2: silence adds nothing; a passage without a seed is refused', () => {
  assert.throws(() => appendVoicePassage(createMatter({ text: 'x' }), { id: 'v', text: '  ', seed: seed() }), /nothing spoken/);
  assert.throws(() => appendVoicePassage(createMatter({ text: 'x' }), { id: 'v', text: 'a', seed: {} }), /seed/);
});

// What shared/voiceappend.swift writes into draftpad.matter.json for "spoken on the walk" after "typed on the Mac\n"
// (copied from the Swift test's output, mobile/ios/Tests/voiceappend): the page must read it as its own.
const NATIVE = {
  log: [], version: 1,
  passages: {
    'vo-x': {
      born: 'voice', id: 'vo-x', phase: 'voice',
      seed: { device: 'iphone', input: 'voice', time: 2000 },
      forms: {
        type: { from: { cross: 0, device: 'iphone', input: 'voice', time: 2000 }, prefix: 'typed on the Mac\n\n', quote: 'spoken on the walk', suffix: '' },
        voice: {
          from: { cross: 0, device: 'iphone', input: 'voice', time: 2000 },
          spoken: [{
            at: 2000, from: { cross: 0, device: 'iphone', input: 'voice', time: 2000 },
            typed: { prefix: 'typed on the Mac\n\n', quote: 'spoken on the walk', suffix: '' },
            words: [{ w: 'spoken' }, { w: 'on' }, { w: 'the' }, { w: 'walk' }]
          }]
        }
      }
    }
  }
};

test('FEAT-08 P2: the native passage reads clean, and Make text leaves the body alone', () => {
  const m = createMatter({ text: 'typed on the Mac\n\nspoken on the walk', side: NATIVE });
  assert.deepEqual(checkMatter(m).problems, []);
  assert.equal(cross(m, 10, 'vo-x', { seed: seed('Mac', 3000) }).text, m.text);
});

test('FEAT-08 P2: the page\'s own sidecar and the native one merge; neither passage is lost', () => {
  const page = seedTypePassage(createMatter({ text: 'typed on the Mac\n' }), { id: 't1', quote: 'typed on the Mac', seed: { device: 'Mac', input: 'keys', time: 1 } });
  const merged = mergeMatter(page.side, NATIVE);
  assert.deepEqual(Object.keys(merged.passages).sort(), ['t1', 'vo-x']);
  assert.deepEqual(checkMatter(createMatter({ text: 'typed on the Mac\n\nspoken on the walk', side: merged })).problems, []);
});
