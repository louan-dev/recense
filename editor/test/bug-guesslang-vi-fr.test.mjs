// Regression guard: BUG-32 · guessLang (French letters â ê ô read as Vietnamese; no NFC)
import test from 'node:test';
import assert from 'node:assert/strict';
import { guessLang } from '../src/matter.js';

test('French words with â ê ô are French, not Vietnamese', () => {
  for (const s of ['fête', 'château', 'hôtel', 'forêt', 'Noël', 'garçon']) assert.equal(guessLang(s), 'fr', s);
});
test('Vietnamese-only letters and tone marks are Vietnamese', () => {
  for (const s of ['Việt Nam', 'đường', 'phở', 'cảm ơn', 'trăng', 'người']) assert.equal(guessLang(s), 'vi', s);
});
test('decomposed (NFD) input reads the same as composed', () => {
  assert.equal(guessLang('cảm ơn'.normalize('NFD')), 'vi');
  assert.equal(guessLang('fête'.normalize('NFD')), 'fr');
});
test('plain English stays English', () => assert.equal(guessLang('hello world'), 'en'));
