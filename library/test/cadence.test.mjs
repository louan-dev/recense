// Cadence's melody pass (src/client/cadence.js): a song's syllables on the notes they're sung on, so the light steps
// with each syllable and holds a held word to the end of its note (owner 2026-10-30: Variations on a Dream, "on").
import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

createRequire(import.meta.url)("../src/client/cadence.js");
const C = globalThis.Cadence;

const split = (w, lang = "en") => {
  const a = Array.from(w);
  let p = 0;
  return C.syllables(w, lang).map((x) => a.slice(p, (p = x)).join("")).join("-");
};

test("syllables", () => {
  assert.equal(split("Variations"), "Va-ri-a-tions");
  assert.equal(split("nation"), "na-tion");
  assert.equal(split("dream"), "dream");
  assert.equal(split("little"), "lit-tle");
  assert.equal(split("liked"), "liked");
  assert.equal(split("wanted"), "wan-ted");
  assert.equal(split("palabras", "es"), "pa-la-bras");
  assert.equal(split("pasó", "es"), "pa-só");
  assert.equal(split("我爱你", "zh"), "我-爱-你");
  assert.equal(split("ሰላም", "am"), "ሰ-ላ-ም");
});

// a vocal stem's features with these notes (start, end, MIDI × 100), voiced throughout as a stem with bleed is
const voice = (notes, secs = 6) => {
  const n = secs * 100, pitch = new Array(n).fill(0);
  for (const [a, b, m] of notes) for (let k = Math.round(a * 100); k < Math.round(b * 100); k++) pitch[k] = m;
  return { format: 1, source: "vocals", hop: 0.01, floor: -57.5, db: new Array(n).fill(-20), voiced: new Array(n).fill(1),
    onset: new Array(n).fill(0), clarity: new Array(n).fill(0.9), pitch };
};

test("a held word stays lit for as long as its note is sung, syllable by syllable", () => {
  const F = voice([
    [1.0, 1.15, 6500], [1.2, 1.35, 6530], [1.4, 1.55, 6400], [1.6, 1.85, 6450], // va-ri-a-tions
    [2.0, 2.4, 6200], [2.42, 3.0, 6000],                                          // o-on, falling, held
    [3.2, 3.3, 6530], [3.3, 4.5, 6700],                                           // a dream
  ]);
  // where a recognizer puts them: late, and "on" over before the singer is
  const lines = [{ id: 2000001, words: [
    { t: "Variations", s: 1.2, e: 1.6 }, { t: "on", s: 1.6, e: 2.1 }, { t: "a", s: 3.6, e: 3.7 }, { t: "dream", s: 3.9, e: 4.2 },
  ] }];
  const [l] = C.fit(lines, F, 0);
  const [v, on, a, dream] = l.words;
  assert.equal(v.syl.length, 4);
  assert.ok(Math.abs(v.s - 1.0) < 0.03, "Variations starts on its first note: " + v.s);
  assert.deepEqual(v.syl.map((y) => Math.round(y.s * 10) / 10), [1.0, 1.2, 1.4, 1.6]);
  assert.ok(Math.abs(on.s - 2.0) < 0.03 && on.e >= 2.95, "on is held to the end of its fall: " + on.s + "–" + on.e);
  assert.ok(Math.abs(a.s - 3.2) < 0.03, "a on its pickup: " + a.s);
  assert.ok(Math.abs(dream.s - 3.3) < 0.03 && dream.e >= 4.45, "dream held: " + dream.s + "–" + dream.e);
});

test("speech is left as heard", () => {
  const F = voice([[1.0, 2.0, 6000]]);
  const [l] = C.fit([{ id: 3, words: [{ t: "hello", s: 1.2, e: 1.6 }] }], F, 0);
  assert.equal(l.words[0].syl, undefined);
});
