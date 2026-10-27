// Key slider label math (src/client/keylabel.js), run in node: the 10 notation states, steps,
// stored-key parsing, position-0 spelling, and key detection. Run with `npm test`.

import { readFileSync } from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const code = readFileSync(new URL("../src/client/keylabel.js", import.meta.url), "utf8");
const ctx = vm.createContext({});
vm.runInContext(code, ctx);
const K = ctx.GalleryKey;

let passed = 0;
const test = (name, fn) => {
  fn();
  passed++;
  console.log("ok   " + name);
};
const L = (v, state, stored, native = "en") => [...K.label(v, state, stored, native).lines];

test("captions and steps", () => {
  assert.deepEqual([...K.CAPTIONS], ["C/Đô", "Ton.", "Tông", "Tonart", "調", "调", "Sa", "Maqam", "Maqam¼", "Cents"]);
  assert.deepEqual([...K.STEPS], [1, 1, 1, 1, 1, 1, 1, 1, 0.5, 0.01]);
  assert.equal(K.label(0, 11, "C", "en").caption, "Ton."); // modulo 10
  assert.equal(K.label(0, -1, "C", "en").caption, "Cents");
});

test("quantize snaps to the state's step and clamps to ±12", () => {
  assert.equal(K.quantize(1.4, 0), 1);
  assert.equal(K.quantize(1.6, 7), 2);
  assert.equal(K.quantize(1.3, 8), 1.5);
  assert.equal(K.quantize(1.2, 8), 1);
  assert.equal(K.quantize(0.344, 9), 0.34);
  assert.equal(K.quantize(-0.004, 9), 0);
  assert.ok(!Object.is(K.quantize(-0.2, 0), -0));
  assert.equal(K.quantize(13, 9), 12);
  assert.equal(K.quantize(-20, 0), -12);
});

test("parser accepts # b ♯ ♭ ♮ and mode words", () => {
  assert.equal(K.canon("Ebm"), "E♭m");
  assert.equal(K.canon("eb minor"), "E♭m");
  assert.equal(K.canon("D#"), "D♯");
  assert.equal(K.canon("F♯ major"), "F♯");
  assert.equal(K.canon("Bbmaj"), "B♭");
  assert.equal(K.canon("E♮m"), "E♮m");
  assert.equal(K.canon("CM"), "C");
  assert.equal(K.parse("Cb").pc, 11);
  assert.equal(K.parse("E#m").pc, 5);
  assert.equal(K.parse("H"), null);
  assert.equal(K.parse("Ebx"), null);
  assert.equal(K.parse(""), null);
});

test("spec examples for Ebm in every state", () => {
  assert.deepEqual(L(0, 0, "Ebm", "fr"), ["E♭m", "Mi♭m"]);
  assert.deepEqual(L(0, 0, "Ebm", "vi"), ["E♭m", "Mi♭t"]);
  assert.deepEqual(L(0, 0, "Ebm", "en"), ["E♭m"]);
  assert.deepEqual(L(0, 1, "Ebm"), ["Mi♭m"]);
  assert.deepEqual(L(0, 1, "Eb"), ["Mi♭maj"]);
  assert.deepEqual(L(0, 2, "Ebm"), ["Mi♭t"]);
  assert.deepEqual(L(0, 2, "Eb"), ["Mi♭T"]);
  assert.deepEqual(L(0, 3, "Ebm"), ["es"]);
  assert.deepEqual(L(0, 3, "Eb"), ["Es"]);
  assert.deepEqual(L(0, 4, "Ebm"), ["変ホ短"]);
  assert.deepEqual(L(0, 5, "Ebm"), ["6=E♭"]);
  assert.deepEqual(L(0, 6, "Ebm"), ["Sa=E♭"]);
  assert.deepEqual(L(0, 7, "Ebm"), ["E♭m", "Kurd"]);
  assert.deepEqual(L(0.5, 8, "Ebm"), ["E♭/m", "Sikah"]);
  assert.deepEqual(L(0.34, 9, "Ebm"), ["E♭m", "+34¢"]);
});

test("moving the key walks the table; mode never changes", () => {
  // C major up a semitone: the table's major spelling
  assert.deepEqual(L(1, 0, "C"), ["D♭maj"]);
  // A minor up 3: pc 0 minor
  assert.deepEqual(L(3, 1, "Am"), ["Dom"]);
  // E minor down 2: pc 2 minor
  assert.deepEqual(L(-2, 3, "Em"), ["d"]);
  // A minor down 1: pc 8 minor uses G♯
  assert.deepEqual(L(-1, 0, "Am", "fr"), ["G♯m", "Sol♯m"]);
  assert.deepEqual(L(-1, 4, "Am"), ["嬰ト短"]);
  assert.deepEqual(L(-1, 6, "Am"), ["Sa=G♯"]);
  assert.deepEqual(L(-1, 6, "A"), ["Sa=A♭"]);
  assert.deepEqual(L(2, 2, "C"), ["Rê T"]);
  assert.deepEqual(L(11, 3, "C"), ["H"]);
  assert.deepEqual(L(-2, 3, "C"), ["B"]);
  assert.deepEqual(L(4, 7, "C"), ["Emaj", "Busel."]);
});

test("every table cell is reachable and verbatim", () => {
  const am = ["Cmaj", "D♭maj", "Dmaj", "E♭maj", "Emaj", "Fmaj", "F♯maj", "Gmaj", "A♭maj", "Amaj", "B♭maj", "Bmaj"];
  const amMin = ["Cm", "C♯m", "Dm", "E♭m", "Em", "Fm", "F♯m", "Gm", "G♯m", "Am", "B♭m", "Bm"];
  const vi = ["Đô T", "Rê♭T", "Rê T", "Mi♭T", "Mi T", "Fa T", "Fa♯T", "Sol T", "La♭T", "La T", "Si♭T", "Si T"];
  const zhMin = ["6=C", "6=C♯", "6=D", "6=E♭", "6=E", "6=F", "6=F♯", "6=G", "6=G♯", "6=A", "6=B♭", "6=B"];
  for (let pc = 1; pc < 12; pc++) {
    assert.equal(L(pc, 0, "C")[0], am[pc]);
    assert.equal(L(pc, 0, "Cm")[0], amMin[pc]);
    assert.equal(L(pc, 2, "C")[0], vi[pc]);
    assert.equal(L(pc, 5, "Cm")[0], zhMin[pc]);
    assert.equal(L(pc, 7, "C")[1], K.MAQAM.tone[pc]);
  }
});

test("position 0 keeps the stored spelling in every notation", () => {
  assert.deepEqual(L(0, 0, "D#m", "fr"), ["D♯m", "Ré♯m"]);
  assert.deepEqual(L(0, 2, "D#m"), ["Rê♯t"]);
  assert.deepEqual(L(0, 3, "D#m"), ["dis"]);
  assert.deepEqual(L(0, 4, "D#m"), ["嬰ニ短"]);
  assert.deepEqual(L(0, 5, "D#m"), ["6=D♯"]);
  assert.deepEqual(L(0, 6, "D#m"), ["Sa=D♯"]);
  assert.deepEqual(L(0, 7, "D#m"), ["D♯m", "Kurd"]);
  assert.deepEqual(L(0, 9, "D#m"), ["D♯m", "+0¢"]);
  // away from 0 the table spelling is used
  assert.deepEqual(L(1, 0, "D#m"), ["Em"]);
  // ±12 shows the same label as 0
  assert.deepEqual(L(12, 0, "D#m", "fr"), ["D♯m", "Ré♯m"]);
  assert.deepEqual(L(-12, 3, "D#m"), ["dis"]);
  // German specials
  assert.deepEqual(L(0, 3, "Bb"), ["B"]);
  assert.deepEqual(L(0, 3, "Bm"), ["h"]);
  assert.deepEqual(L(0, 3, "Ab"), ["As"]);
  assert.deepEqual(L(0, 3, "Gb"), ["Ges"]);
  // a stored spelling that agrees with the table gives the table's own cells
  for (let pc = 0; pc < 12; pc++) {
    const maj = K.ROWS[pc].am[0].replace(/maj$/, "");
    const min = K.ROWS[pc].am[1];
    for (let s = 0; s < 7; s++) {
      const col = ["am", "fr", "vi", "de", "ja", "zh", "in"][s];
      if (s === 0) continue;
      assert.equal(L(0, s, maj)[0], K.ROWS[pc][col][0], col + " " + maj);
      assert.equal(L(0, s, min)[0], K.ROWS[pc][col][1], col + " " + min);
    }
  }
});

test("♮ shows only at position 0, and 本 in Japanese", () => {
  assert.deepEqual(L(0, 0, "E♮m", "fr"), ["E♮m", "Mi♮m"]);
  assert.deepEqual(L(0, 4, "E♮m"), ["本ホ短"]);
  assert.deepEqual(L(0, 3, "E♮m"), ["e♮"]);
  assert.deepEqual(L(12, 4, "E♮m"), ["本ホ短"]);
  assert.deepEqual(L(1, 0, "E♮m"), ["Fm"]);
  assert.deepEqual(L(0, 4, "Em"), ["ホ短"]);
  assert.deepEqual(L(0, 2, "E♮"), ["Mi♮T"]);
});

test("State 8: even quarter-tones use State 7, odd ones the 24-tone table", () => {
  assert.deepEqual(L(0, 8, "C"), ["Cmaj", "Rast"]);
  assert.deepEqual(L(0.5, 8, "C"), ["C♯/maj", "Tik Zirg."]);
  assert.deepEqual(L(0.5, 8, "Cm"), ["C♯/m", "Tik Zirg."]);
  assert.deepEqual(L(1, 8, "C"), ["D♭maj", "Zirg."]);
  assert.deepEqual(L(-0.5, 8, "C"), ["C♭/maj", "Nim Rast"]);
  assert.deepEqual(L(11.5, 8, "C"), ["C♭/maj", "Nim Rast"]);
  assert.deepEqual(L(0.3, 8, "C"), ["C♯/maj", "Tik Zirg."]); // snapped to 0.5
  const odd = { 1: "C♯/", 3: "D♭/", 5: "D♯/", 7: "E♭/", 9: "F♭/", 11: "F♯/", 13: "G♭/", 15: "G♯/", 17: "A♭/", 19: "A♯/", 21: "B♭/", 23: "C♭/" };
  for (const q of Object.keys(odd)) {
    assert.deepEqual(L(q / 2, 8, "C"), [odd[q] + "maj", K.MAQAM.quarter[q]]);
  }
});

test("State 9: nearest key over a signed cent offset", () => {
  assert.deepEqual(L(0, 9, "C"), ["Cmaj", "+0¢"]);
  assert.deepEqual(L(1.2, 9, "C"), ["D♭maj", "+20¢"]);
  assert.deepEqual(L(0.8, 9, "C"), ["D♭maj", "−20¢"]);
  assert.deepEqual(L(-0.5, 9, "Am"), ["Am", "−50¢"]);
  assert.deepEqual(L(0.5, 9, "Am"), ["B♭m", "−50¢"]);
  assert.deepEqual(L(2.999, 9, "C"), ["E♭maj", "+0¢"]);
});

test("no stored key: numeric labels", () => {
  // no key: never a fake root, the shift only when there is one (SPEC 62)
  assert.deepEqual(L(0, 0, ""), ["Key: —"]);
  assert.deepEqual(L(1, 0, null), ["Key: —", "(+1 st)"]);
  assert.deepEqual(L(-2, 4, ""), ["Key: —", "(−2 st)"]);
  assert.deepEqual(L(12, 7, ""), ["Key: —", "(+12 st)"]);
  assert.deepEqual(L(1.5, 8, ""), ["Key: —", "(+1.5 st)"]);
  assert.deepEqual(L(-0.5, 8, ""), ["Key: —", "(−0.5 st)"]);
  assert.deepEqual(L(0.35, 9, ""), ["Key: —", "(+0.35 st)"]);
  for (let s = 0; s < 10; s++) assert.ok(!/[A-H]|Do|Đô|Sa/.test(L(3, s, "").join(" ").replace("Key", "")));
  assert.deepEqual(L(1.2, 9, ""), ["Key: —", "(+1.2 st)"]);
  assert.deepEqual(L(-0.07, 9, ""), ["Key: —", "(−0.07 st)"]);
  assert.deepEqual(L(0, 0, "nonsense", "fr"), ["Key: —"]);
});

test("detection: a profile, and synthetic tones", () => {
  const KK_MAJ = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
  const KK_MIN = [6.33, 2.68, 3.52, 5.38, 2.6, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];
  const rot = (p, r) => p.map((_, i) => p[(i - r + 12) % 12]);
  assert.equal(K.keyOfChroma(rot(KK_MAJ, 0)), "C");
  assert.equal(K.keyOfChroma(rot(KK_MAJ, 1)), "D♭");
  assert.equal(K.keyOfChroma(rot(KK_MIN, 3)), "E♭m");
  assert.equal(K.keyOfChroma(rot(KK_MIN, 8)), "G♯m");
  assert.equal(K.keyOfChroma(new Array(12).fill(0)), "");

  // a G major scale weighted to its tonic triad, as sines
  const sr = 22050;
  const n = sr * 4;
  const buf = new Float32Array(n);
  const tones = { 67: 3, 71: 2, 74: 2.5, 69: 1, 72: 1, 76: 1, 78: 1, 55: 2 }; // midi: weight
  for (const [m, w] of Object.entries(tones)) {
    const f = 440 * Math.pow(2, (m - 69) / 12);
    for (let i = 0; i < n; i++) buf[i] += w * Math.sin((2 * Math.PI * f * i) / sr);
  }
  const chroma = K.chromaOf(buf, sr);
  assert.equal(chroma.indexOf(Math.max(...chroma)), 7); // G is the strongest pitch class
  assert.equal(K.keyOfChroma(chroma), "G");
});

test("SPEC 40: chords are detected and spelled in the language's notation, or the Key notation picked after it", () => {
  const ch = new Array(12).fill(0.05);
  ch[3] = 1; ch[6] = 0.8; ch[10] = 0.9; // E♭ G♭ B♭
  const c = K.chordOf(ch);
  assert.equal(c.pc, 3);
  assert.equal(c.minor, true);
  assert.equal(K.chordOf(new Array(12).fill(1)), null); // noise: no chord
  assert.equal(K.chordName(c, K.chordState("en", 2, false)), "E♭m");
  assert.equal(K.chordName(c, K.chordState("vi", 2, false)), "Mi♭ t");
  assert.equal(K.chordName(c, K.chordState("vi", 1, true)), "Mi♭m"); // Tông, then Ton.: French solfège
  assert.equal(K.chordName({ pc: 7, minor: false }, 2), "Sol");
});

console.log("\n" + passed + " passed");
