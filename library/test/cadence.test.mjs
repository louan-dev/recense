// Cadence (src/client/cadence.js): the voice's own syllables, found from the audio alone, and a song's words hung on
// them, so the light steps with each syllable, holds a held word, waits for a late entry and never lights a word that
// isn't sung (owner 2026-10-30: Variations on a Dream at 1:20, 1:52 and 2:35).
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
// (and `dips`: [start, end] where the loudness falls 6 dB, a syllable boundary sung legato)
const voice = (notes, secs = 6, dips = []) => {
  const n = secs * 100, pitch = new Array(n).fill(0), db = new Array(n).fill(-200);
  for (const [a, b, m] of notes) for (let k = Math.round(a * 100); k < Math.round(b * 100); k++) pitch[k] = m;
  for (const [a, b] of dips) for (let k = Math.round(a * 100); k < Math.round(b * 100); k++) db[k] = -260;
  return { format: 1, source: "vocals", hop: 0.01, floor: -57.5, db, voiced: new Array(n).fill(1),
    onset: new Array(n).fill(0), clarity: new Array(n).fill(0.9), pitch };
};

test("a held word stays lit for as long as its note is sung, syllable by syllable", () => {
  const F = voice([
    [1.0, 1.15, 6500], [1.2, 1.35, 6530], [1.4, 1.55, 6400], [1.6, 1.85, 6450], // va-ri-a-tions
    [2.0, 2.4, 6200], [2.42, 3.0, 6000],                                          // o-on, falling, held
    [3.2, 3.3, 6530], [3.34, 4.5, 6700],                                          // a (dr)eam
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
  assert.ok(Math.abs(dream.s - 3.34) < 0.03 && dream.e >= 4.45, "dream held: " + dream.s + "–" + dream.e);
});

test("syllables sung legato on one breath are told apart by the loudness", () => {
  const F = voice([[1.0, 2.0, 6500]], 4, [[1.22, 1.3], [1.47, 1.55], [1.72, 1.8]]);
  const u = C.units(F);
  assert.equal(u.length, 4, JSON.stringify(u));
  const [l] = C.fit([{ id: 2000001, words: [{ t: "Variations", s: 1.1, e: 1.9 }] }], F, 0);
  assert.equal(l.words[0].syl.length, 4);
  assert.ok(l.words[0].syl.every((y, k) => k === 0 || y.s > l.words[0].syl[k - 1].s), JSON.stringify(l.words[0].syl));
});

test("the light waits for the singer, and a word written but not sung (as corrected) is never lit", () => {
  // piano until 3.0 (nothing in the vocal stem), then "on a dream", "dream" held
  const F = voice([[3.0, 3.3, 6200], [3.4, 3.6, 6000], [3.7, 5.5, 6700]], 7);
  const words = (ts) => ts.map((t, i) => ({ t, s: 1 + i * 0.6, e: 1.5 + i * 0.6 }));
  // as transcribed: whatever it lights, it lights only once she sings
  const [l] = C.fit([{ id: 2000002, words: words(["Variations", "on", "a", "dream"]) }], F, 0);
  for (const w of l.words) assert.ok(w.un || w.s >= 3.0 - 1e-6, "lit before she sings: " + JSON.stringify(w));
  assert.ok(l.words[3].e >= 5.45, "dream held: " + JSON.stringify(l.words[3]));
  // as the listener corrected it: each word on its sung syllable
  const [m] = C.fit([{ id: 2000002, fixed: true, words: words(["On", "a", "dream"]) }], F, 0);
  assert.deepEqual(m.words.map((w) => [Math.round(w.s * 10) / 10, !!w.un]), [[3.0, false], [3.4, false], [3.7, false]]);
  assert.ok(m.words[2].e >= 5.45);
  // and a word left in that has no voice to go with it: never lit
  const G = voice([[3.0, 3.3, 6200]], 7);
  const [n] = C.fit([{ id: 2000003, words: [{ t: "hello", s: 0.5, e: 0.9 }, { t: "there", s: 3.0, e: 3.3 }] }], G, 0);
  assert.equal(n.words[0].un, true, JSON.stringify(n.words));
});

test("a listener's corrected words are lit even where no syllable of the voice is theirs (Whitacre's \"A world\")", () => {
  const G = voice([[3.0, 3.3, 6200], [3.5, 4.4, 6100]], 7);
  const ws = () => [{ t: "A", s: 0.6, e: 0.9 }, { t: "world", s: 3.0, e: 3.3 }, { t: "in", s: 3.5, e: 3.8 }];
  const [n] = C.fit([{ id: 3000001, words: ws() }], G, 0);
  assert.equal(n.words[0].un, true, "as heard, a word with no voice isn't lit: " + JSON.stringify(n.words));
  const [m] = C.fit([{ id: 3000001, fixed: true, words: ws() }], G, 0);
  assert.ok(m.words.every((w) => !w.un && w.e > w.s), JSON.stringify(m.words));
  assert.ok(m.words.every((w, i) => !i || w.s >= m.words[i - 1].s), "in order: " + JSON.stringify(m.words));
});

test("speech is left as heard", () => {
  const F = voice([[1.0, 2.0, 6000]]);
  const [l] = C.fit([{ id: 3, words: [{ t: "hello", s: 1.2, e: 1.6 }] }], F, 0);
  assert.equal(l.words[0].syl, undefined);
});

test("a word sung out to a whisper is held for as long as it's sung, and a lone quiet blip is still nobody", () => {
  // "dream" at full voice, then going soft (20 dB down) in a chain of short phrases; later a far-off quiet blip
  const F = voice([[1.0, 1.4, 6500], [1.5, 2.2, 6700], [2.4, 2.8, 6700], [3.0, 3.4, 6650], [3.6, 4.0, 6600], [6.5, 6.6, 6700]], 8);
  for (let k = 240; k < 600; k++) F.db[k] = -400;
  for (let k = 620; k < 690; k++) F.db[k] = -600;
  const [l] = C.fit([{ id: 2000001, words: [{ t: "a", s: 1.0, e: 1.4 }, { t: "dream", s: 1.5, e: 2.0 }] }], F, 0);
  assert.ok(l.words[1].e >= 3.95, "held through the soft phrases: " + JSON.stringify(l.words[1]));
  const u = C.units(F);
  assert.ok(u.find((x) => x.s >= 6.4).weak, "the blip far from the voice stays weak: " + JSON.stringify(u));
});

test("a word timed by the listener (corrections field \"time\") is lit where they set it, its neighbours giving way", async () => {
  const { pinsOf, applyOverrides } = await import("../src/corrections.js");
  const to = JSON.stringify([[1, 84.08, 85.26, -0.5]]);
  assert.deepEqual(pinsOf(to), { 1: { s: 84.08, e: 85.26, k: -0.5 } });
  assert.deepEqual(pinsOf("[[0, 5, 4, 0], \"x\"]"), {});
  const lines = applyOverrides([{ id: "2000008", words: [{ t: "a", s: 82.5, e: 83 }, { t: "dream", s: 83, e: 85.64 }] }],
    [{ segId: "2000008", field: "time", to, updatedAt: 1 }]);
  assert.deepEqual(lines[0].words[1].tm, { s: 84.08, e: 85.26, k: -0.5 });
  const [l] = globalThis.Cadence.pin([{ id: 2000008, words: [{ t: "a", s: 82.5, e: 84.5, syl: [{ c: 1, s: 82.5, e: 84.5 }] }, lines[0].words[1]] }]);
  assert.equal(l.words[1].s, 84.08);
  assert.equal(l.words[1].k, -0.5);
  assert.equal(l.words[0].e, 84.08);
  assert.equal(l.words[0].syl[0].e, 84.08);
});
