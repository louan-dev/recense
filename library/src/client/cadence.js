// Cadence: a song's words timed to its measured voice, by the same rules as Recense's Cadence.fit in Sill
// (sill/sill/recense.swift, enum Cadence). Kept rule for rule with it, so Gallery, the iOS app and Sill light the same
// word at the same moment: change one, change the other.
//
// A recognizer says roughly where words start and nothing of how they're sung. With the song's features
// (keep/<key>/features.json: voiced, onset, pitch every 10 ms of its vocal stem), a word starts where its voice comes
// in and lasts as long as the voice holds it:
//   · run into the word before it (heard starting before that one ended), over a silence of 200 ms or more: it starts
//     where the voice comes back after that silence, if it then sings on for 0.25 s
//   · opening a line or following a pause (or after a breath of 100 ms or more), heard inside a voice that came in
//     less than 0.4 s before: it starts where that voice came in (a sung word is heard late, by its vowel)
//   · else on the strongest onset near the recognizer's start: within 120 ms, or from silence up to 350 ms late
// and it ends where the voice stops, or runs on into the next word.
//
//   Cadence.fit(lines, features, shift)  →  new lines, each word { t, s, e, … } retimed and each line's s/e with them.
// Lines are Gallery's (the Worker's `present`): word times in this file's time, which is the transcript's + `shift`.
(() => {
  "use strict";

  function voiceOf(F) {
    const hop = F.hop || 0.01, n = F.db.length, voiced = F.voiced, onset = F.onset, pitch = F.pitch;
    const frame = (t) => Math.max(0, Math.min(n - 1, Math.floor(t / hop)));
    const time = (k) => k * hop;
    const isVoiced = (k) => k >= 0 && k < n && voiced[k] === 1;
    const sustained = (k) => {
      if (!isVoiced(k)) return false;
      let c = 0;
      for (let j = k; j < k + 8; j++) if (isVoiced(j)) c++;
      return c >= 5;
    };
    // where the voice comes back after a silence and goes on, in [a, b): the frame and how long it was quiet before
    const entries = (a, b) => {
      const out = [];
      const lo = Math.max(1, frame(a)), hi = Math.min(n, Math.ceil(b / hop));
      for (let k = lo; k < hi; k++) {
        if (voiced[k] !== 1 || voiced[k - 1] !== 0 || !sustained(k)) continue;
        let g = 0;
        while (k - g - 1 >= 0 && voiced[k - g - 1] === 0 && g < 200) g++;
        out.push({ k, gap: g * hop });
      }
      return out;
    };
    // voiced in 95 % or more of the frames within a second either side
    const saturated = (k) => {
      let c = 0, all = 0;
      for (let j = Math.max(0, k - 100); j < Math.min(n, k + 100); j++, all++) if (voiced[j] === 1) c++;
      return all > 0 && c >= all * 0.95;
    };
    // in [a, b]: the frame where the loudness rises most, its next 150 ms over its last (dB × 10), if by 4 dB or more
    const db = F.db;
    const rise = (a, b) => {
      let best = -1, br = 40;
      for (let k = Math.max(15, a); k <= Math.min(n - 15, b); k++) {
        let before = 0, after = 0;
        for (let j = 1; j <= 15; j++) (before += db[k - j]), (after += db[k + j - 1]);
        const r = (after - before) / 15;
        if (r > br) (br = r), (best = k);
      }
      return best;
    };
    return { hop, n, db, onset, pitch, frame, time, isVoiced, sustained, entries, saturated, rise };
  }

  // A word's syllables, as where each ends in its letters (code points). Han, kana, Hangul and Ethiopic: a letter each.
  // Latin, Cyrillic and Greek: one per run of vowels, split where two vowels are sung apart (va-ri-a-tions; not the
  // -tion of "nation"), the consonants between two going to the second (or one to each, from two on, but pl, br… together). English
  // drops a silent final e, -es or -ed (love, loves, liked; not the, lit-tle, wan-ted). Other scripts: the word whole (the voice gives it all its syllables).
  const VOWEL = /[aeiouyæœøåıəаеёиоуыэюяіїєαεηιουω]/;
  function syllables(word, lang) {
    const cs = Array.from(word);
    if (!cs.length) return [];
    if (/[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}\p{Script=Ethiopic}]/u.test(word)) {
      const out = [];
      cs.forEach((c, k) => { if (/\p{L}/u.test(c)) out.push(k + 1); else if (out.length) out[out.length - 1] = k + 1; });
      return out.length ? out : [cs.length];
    }
    const base = cs.map((c) => c.normalize("NFD")[0].toLowerCase());
    const isV = base.map((c) => VOWEL.test(c));
    const nuclei = [];
    for (let k = 0; k < cs.length; k++) {
      if (!isV[k]) continue;
      const last = nuclei[nuclei.length - 1];
      // i before a vowel is its own syllable (ri-a), except as a glide after t, s, c, g, x (na-tion, spe-cial, re-gion)
      const hiatus = last && last.b === k && base[k - 1] === "i" && k >= 2 && !/[tscgx]/.test(base[k - 2]) && last.b - last.a === 1;
      if (last && last.b === k && !hiatus) last.b = k + 1;
      else nuclei.push({ a: k, b: k + 1 });
    }
    if (!nuclei.length) return [cs.length];
    const en = !lang || /^en/.test(lang);
    const lastN = nuclei[nuclei.length - 1];
    const tail = base.slice(lastN.b).join("").replace(/[^\p{L}]/gu, "");
    const before = base.slice(0, lastN.a).join("");
    if (en && nuclei.length > 1 && lastN.b - lastN.a === 1 && base[lastN.a] === "e"
        && (tail === "" && !/[^aeiouy]l$/.test(before) || tail === "s" && !/(s|z|x|ch|sh|c|g)$/.test(before) || tail === "d" && !/[td]$/.test(before))) nuclei.pop();
    const out = [];
    for (let j = 0; j + 1 < nuclei.length; j++) {
      const a = nuclei[j].b, gap = nuclei[j + 1].a - a;
      // two consonants go one to each, unless they start a syllable together (pa-la-bras, a-pple's pl, ma-tri-a)
      const onset = gap === 2 && /[bcdfgkpt]/.test(base[a]) && /[lr]/.test(base[a + 1]);
      out.push(a + (gap >= 2 && !onset ? 1 : 0));
    }
    out.push(cs.length);
    return out;
  }

  // ---- the voice's own syllables: a prosody transcription, from the audio alone --------------------------------------
  // The sung syllables of a vocal stem, found without the text (the audio is the truth; the words are a label on it):
  // where the voice is pitched, cut where it stops for 30 ms or more (a consonant, a breath) and where its loudness dips
  // 2.5 dB or more between two peaks (syllables sung legato on one breath, va-ri-a-tions: syllabic nuclei as Prosogram
  // finds them). A pitch move with no dip stays inside its syllable (a held word falling to its next note, a run on one
  // vowel). Each: { s, e, m (middle pitch, MIDI × 100), db (its loudest, dB), weak (15 dB or more under the song's
  // sung level, or 11 semitones or more from the singer's middle: bleed, an octave slip, breath) }. A quiet one joined to
  // the singing (30 ms to 300 ms between, a chain of them) is the voice going soft, not bleed: a word sung out to a
  // whisper is held for as long as it's sung (Variations on a Dream's "dream" at 2:51, owner 2026-10-31).
  function unitsOf(f) {
    const p = f.pitch, db = f.db, n = f.n;
    const on = (k) => f.isVoiced(k) && p[k] > 0;
    const L = new Float64Array(n);
    for (let k = 0; k < n; k++) { let s = 0, c = 0; for (let j = Math.max(0, k - 3); j <= Math.min(n - 1, k + 3); j++) (s += db[j]), c++; L[k] = s / c; }
    const runs = [];
    let a = -1, last = -1;
    for (let k = 0; k < n; k++) {
      if (on(k)) { if (a < 0) a = k; last = k; }
      else if (a >= 0 && k - last > 2) { if (last + 1 - a >= 6) runs.push([a, last + 1]); a = -1; }
    }
    if (a >= 0 && last + 1 - a >= 6) runs.push([a, last + 1]);
    const out = [];
    for (const [x, y] of runs) {
      const cuts = [x];
      let peak = -Infinity, trough = Infinity, tk = -1, falling = false;
      for (let k = x; k < y; k++) {
        const v = L[k];
        if (!falling) { if (v > peak) peak = v; else if (peak - v >= 25) { falling = true; trough = v; tk = k; } }
        else if (v < trough) { trough = v; tk = k; }
        else if (v - trough >= 25) { if (tk - cuts[cuts.length - 1] >= 6 && y - tk >= 6) cuts.push(tk); falling = false; peak = v; }
      }
      cuts.push(y);
      for (let i = 0; i + 1 < cuts.length; i++) {
        const u = cuts[i], v = cuts[i + 1], ps = [];
        let top = -Infinity;
        for (let k = u; k < v; k++) { if (p[k] > 0) ps.push(p[k]); if (L[k] > top) top = L[k]; }
        ps.sort((q, r) => q - r);
        out.push({ s: f.time(u), e: f.time(v), m: ps.length ? ps[ps.length >> 1] : 0, db: top / 10, weak: false });
      }
    }
    if (out.length) {
      const lv = out.map((u) => u.db).sort((q, r) => q - r)[Math.floor(out.length * 0.75)];
      const byLen = out.filter((u) => u.m > 0).map((u) => [u.m, u.e - u.s]).sort((q, r) => q[0] - r[0]);
      let half = byLen.reduce((q, x) => q + x[1], 0) / 2, reg = byLen.length ? byLen[0][0] : 0;
      for (const [m, d] of byLen) { reg = m; if ((half -= d) <= 0) break; }
      const off = out.map((u) => u.m > 0 && Math.abs(u.m - reg) >= 1100);
      out.forEach((u, k) => (u.weak = off[k] || u.db < lv - 15));
      // soft singing: a quiet unit next to a sung one (≤ 0.3 s), outward from the sung ones both ways
      for (let k = 1; k < out.length; k++) if (out[k].weak && !off[k] && !out[k - 1].weak && out[k].s - out[k - 1].e <= 0.3) out[k].weak = false;
      for (let k = out.length - 2; k >= 0; k--) if (out[k].weak && !off[k] && !out[k + 1].weak && out[k + 1].s - out[k].e <= 0.3) out[k].weak = false;
    }
    return out;
  }

  // Lyric to voice: a song's words (lines with ids 2 000 000 and up), syllable by syllable in order, hung on the voice's
  // own syllables over the whole song at once, by the cheapest of all the ways to do it (dynamic programming). The
  // recognizer's times are only a hint; the voice decides:
  //   a syllable starts on a sung one:    how far from where the recognizer put it, in 0.5 s (≤ 4; 0.3 of that within a
  //                                        word; a quarter on a line a listener rewrote, its times only spread over it),
  //                                        + 1.5 on a weak one, − 1 for a line's first where the voice comes in after a
  //                                        breath (0.5 s or more); within a word, on the next sung one, within a second
  //   a sung syllable left unworded:     its length in 0.15 s (≤ 4; a weak one 0.15 of that)
  //   a sung syllable run on by a word:  1.2 straight on (one vowel's run, a held word's swell), 1.6 after a gap under
  //                                       0.3 s, else 3 + the gap; by a line's last word 0.4 and 0.8 (it holds to the
  //                                       end of the phrase: "dream" sung out)
  //   a silence crossed inside a line:   1.2 a second
  //   a syllable run into the one before (fast singing, one sung syllable for two written): 1 within a word, 1.3 across
  //   a syllable left unsung:            3 for a word's first; the rest of a word not begun 1.5, of one begun 4 (a
  //                                       written word not sung at all, "Variations" where only "on a dream" is, rather
  //                                       than one cut across the voice)
  // A word then lasts from its first sung syllable to its last's end; one with none is unsung (`un`): never lit, no
  // notation under it. Speech (ids under 2 000 000) is left as heard.
  // → per word, its syllables [{ c, s, e }] (c: where each ends in the word's letters), or null; `un` per word.
  function align(lines, f, flat, s, e) {
    const res = new Array(flat.length).fill(null), un = new Array(flat.length).fill(false);
    if (!Array.isArray(f.pitch) || f.pitch.length < f.n) return { res, un };
    const Y = [];
    let at = 0;
    for (const l of lines) {
      const from = at, c = (l.words || []).length;
      at += c;
      if (!c || !(Number(l.id) >= 2000000)) continue;
      for (let i = from; i < at; i++) {
        const cut = syllables(flat[i].t, flat[i].lang), K = cut.length || 1;
        for (let k = 0; k < K; k++) Y.push({ i, c: cut[k] || Array.from(flat[i].t).length, exp: s[i] + ((e[i] - s[i]) * k) / K,
          wt: (k ? 0.3 : 1) * (l.fixed ? 0.25 : 1), inner: k > 0, first: i === from && !k, end: i === at - 1 && k === K - 1, fx: !!l.fixed });
      }
    }
    if (!Y.length) return { res, un };
    const lo = Math.min(...Y.map((y) => y.exp)) - 3, hi = Math.max(...Y.map((y) => y.exp)) + 3;
    const U = unitsOf(f).filter((u) => u.s >= lo && u.s < hi);
    const N = U.length, S = Y.length;
    if (!N) return { res, un };
    const P = new Float64Array(N + 1), M = new Float64Array(N), Mend = new Float64Array(N), gap = new Float64Array(N);
    for (let k = 0; k < N; k++) {
      P[k + 1] = P[k] + Math.min(4, (U[k].e - U[k].s) / 0.15) * (U[k].weak ? 0.15 : 1);
      gap[k] = k ? U[k].s - U[k - 1].e : Infinity;
    }
    for (let k = 1; k < N; k++) {
      const g = gap[k];
      M[k] = M[k - 1] + (g <= 0.03 ? 1.2 : g < 0.3 ? 1.6 : 3 + g);
      Mend[k] = Mend[k - 1] + (g <= 0.03 ? 0.4 : g < 0.3 ? 0.8 : 3 + g);
    }
    const start = (y, a) => y.wt * Math.min(4, Math.abs(U[a].s - y.exp) / 0.5) + (U[a].weak ? 1.5 : 0) - (y.first && gap[a] >= 0.5 ? 1 : 0);
    // two costs per syllable y and j sung syllables behind it: the cheapest with y sung (its first sung one in how), and
    // with y unsung; each remembers whether the syllable before it was sung (a word is sung or it isn't: leaving out the
    // rest of a word begun costs 4 a syllable, the rest of a word not begun 1.5)
    const how = [], back = [], fl = [], uf = [];
    let prevS = new Float64Array(N + 1).fill(Infinity), prevU = new Float64Array(N + 1).fill(Infinity);
    prevS[0] = 0;
    for (let y = 0; y < S; y++) {
      const Y0 = Y[y], Mx = Y0.end ? Mend : M, c = Y0.first ? 0 : 1.2;
      const prev = new Float64Array(N + 1), pf = new Uint8Array(N + 1);
      for (let j = 0; j <= N; j++) { const u = prevU[j] < prevS[j]; prev[j] = u ? prevU[j] : prevS[j]; pf[j] = u ? 1 : 0; }
      const curS = new Float64Array(N + 1).fill(Infinity), curU = new Float64Array(N + 1).fill(Infinity);
      const h = new Int32Array(N + 1).fill(-2), bq = new Int32Array(N), w = new Uint8Array(N + 1);
      let mq = Infinity, q = -1, ma = Infinity, a0 = -1;
      for (let a = 0; a < N; a++) {
        // a silence crossed inside a line costs 1.2 a second (the words of a line are sung together)
        const v0 = prev[a] - P[a] - c * (a ? U[a - 1].e : U[0].s);
        if (v0 < mq) { mq = v0; q = a; }
        // inside a word, the next sung syllable straight after (within a second), none skipped
        let from;
        if (Y0.inner) { from = gap[a] < 1 || !a ? prev[a] : Infinity; bq[a] = a; }
        else { from = P[a] + c * U[a].s + mq; bq[a] = q; }
        const best = from + start(Y0, a) - Mx[a];
        if (best < ma) { ma = best; a0 = a; }
        const v = Mx[a] + ma;
        if (v < curS[a + 1]) { curS[a + 1] = v; h[a + 1] = a0; }
      }
      // sung quickly, run into the one before it: a share of that one's last sung syllable (1 inside a word, 1.3 a word)
      const share = Y0.inner ? 1 : 1.3;
      for (let j = 1; j <= N; j++) if (prevS[j] + share < curS[j]) { curS[j] = prevS[j] + share; h[j] = -3; }
      const afterS = Y0.inner ? 4 : 3, afterU = Y0.inner ? 1.5 : 3;
      for (let j = 0; j <= N; j++) {
        const x = prevS[j] + afterS, z = prevU[j] + afterU;
        if (z < x) { curU[j] = z; w[j] = 1; } else curU[j] = x;
      }
      how.push(h); back.push(bq); fl.push(pf); uf.push(w);
      prevS = curS; prevU = curU;
    }
    let j = 0, sung = 1, bestEnd = Infinity;
    for (let k = 0; k <= N; k++) {
      const tail = P[N] - P[k];
      if (prevS[k] + tail < bestEnd) { bestEnd = prevS[k] + tail; j = k; sung = 1; }
      if (prevU[k] + tail < bestEnd) { bestEnd = prevU[k] + tail; j = k; sung = 0; }
    }
    if (!(bestEnd < Infinity)) return { res, un };
    const got = new Array(S).fill(null);
    for (let y = S - 1; y >= 0; y--) {
      if (!sung) { sung = uf[y][j] ? 0 : 1; continue; }
      const a = how[y][j];
      if (a === -3) { got[y] = { x: j - 1 }; continue; }   // shares unit j - 1 with the syllable before it
      if (a < 0) break;
      got[y] = { s: U[a].s, e: U[j - 1].e };
      j = back[y][a];
      sung = fl[y][j] ? 0 : 1;
    }
    // a sung syllable shared: its owner and the ones run into it split it evenly
    for (let y = 0; y < S; y++) {
      if (!got[y] || got[y].x === undefined || !y || !got[y - 1]) continue;
      let z = y;
      while (z + 1 < S && got[z + 1] && got[z + 1].x === got[y].x) z++;
      const u = U[got[y].x], o = got[y - 1], t0 = Math.max(u.s, o.s), d = (u.e - t0) / (z - y + 2);
      o.e = t0 + d;
      for (let k = y; k <= z; k++) got[k] = { s: t0 + d * (k - y + 1), e: t0 + d * (k - y + 2) };
      y = z;
    }
    // each word from its syllables; an unsung one inside a sung word takes the time between its neighbours
    let lastEnd = 0;
    for (let i = 0; i < flat.length; i++) {
      const ys = [];
      for (let k = 0; k < S; k++) if (Y[k].i === i) ys.push(k);
      if (!ys.length) continue;
      const sung = ys.filter((k) => got[k]);
      // a word a listener wrote in is sung (they heard it): with no syllable of its own it keeps the time it was given,
      // between its neighbours, and the light goes on over it (Whitacre's "A world", owner 2026-10-30)
      if (!sung.length && Y[ys[0]].fx) {
        s[i] = Math.max(lastEnd, s[i]);
        e[i] = Math.max(s[i] + 0.05, e[i]);
        lastEnd = e[i];
        continue;
      }
      if (!sung.length) {
        un[i] = true;
        s[i] = e[i] = Math.max(lastEnd, Math.min(s[i], i + 1 < flat.length ? s[i + 1] : s[i]));
        continue;
      }
      const ns = got[sung[0]].s, ne = Math.max(ns + 0.05, got[sung[sung.length - 1]].e);
      const out = ys.map((k) => ({ c: Y[k].c, s: got[k] ? got[k].s : NaN, e: got[k] ? got[k].e : NaN }));
      for (let k = 0; k < out.length; k++) {
        if (!Number.isNaN(out[k].s)) continue;
        const before = k ? out[k - 1].e : ns, after = out.slice(k + 1).find((x) => !Number.isNaN(x.s));
        out[k].s = before;
        out[k].e = after ? after.s : Math.max(before, ne);
      }
      s[i] = ns;
      e[i] = ne;
      res[i] = out;
      lastEnd = ne;
    }
    // in order still, and none running into the next
    for (let i = 1; i < flat.length; i++) if (s[i] < s[i - 1]) s[i] = s[i - 1];
    for (let i = 0; i + 1 < flat.length; i++) {
      if (un[i]) { e[i] = s[i]; continue; }
      let k = i + 1;
      while (k < flat.length && un[k]) k++;
      if (k < flat.length && s[k] > s[i] && e[i] > s[k]) e[i] = Math.max(s[i] + 0.05, s[k]);
      if (res[i]) for (const y of res[i]) { y.e = Math.min(y.e, e[i]); y.s = Math.min(y.s, y.e); }
    }
    return { res, un };
  }

  function fit(lines, F, shift = 0) {
    if (!F || F.source !== "vocals" || !Array.isArray(F.db) || F.db.length <= 20 || !Array.isArray(lines)) return lines;
    const f = voiceOf(F);
    const flat = [];
    // back in the transcript's time, to the millisecond the Worker keeps (so a frame is the frame Recense sees)
    const back = (x) => Math.round((x - shift) * 1000) / 1000;
    // (a line with an English translation isn't English: no English spelling rules for its syllables)
    const langOf = (l, w) => w.lang || l.lang || ((l.enw && l.enw.length) || (l.english && l.english.length) ? "und" : undefined);
    for (const l of lines) for (const w of l.words || []) flat.push({ start: back(w.s), end: back(w.e), t: String(w.t || ""), lang: langOf(l, w) });
    const n = flat.length;
    if (!n) return lines;

    // an onset counts when it stands out among the voice's own (its 60th percentile, at least a tenth of the strongest)
    const peaks = [];
    for (let k = 1; k < f.n - 1; k++) {
      const o = f.onset[k];
      if (f.isVoiced(k) && o > 0 && o >= f.onset[k - 1] && o >= f.onset[k + 1]) peaks.push(o);
    }
    peaks.sort((a, b) => a - b);
    const strong = Math.max(10, peaks.length ? peaks[Math.floor((peaks.length * 6) / 10)] : 10);
    // the next word sung after each, in its line or the next
    const next = new Array(n).fill(Infinity);
    for (let i = n - 2; i >= 0; i--) next[i] = flat[i + 1].start > flat[i].start ? flat[i + 1].start : next[i + 1];
    const s = flat.map((w) => w.start), e = flat.map((w) => w.end), legato = new Array(n).fill(false);
    // a line's first word, or one after a pause in what was heard
    const opens = new Array(n).fill(false);
    let at = 0;
    for (const l of lines) {
      const c = (l.words || []).length;
      if (c) opens[at] = true;
      at += c;
    }
    for (let i = 1; i < n; i++) if (flat[i - 1].end < flat[i].start - 0.15) opens[i] = true;

    for (let i = 0; i < n; i++) {
      const w = flat[i], after = Math.min(next[i], w.start + 8), lower = i > 0 ? s[i - 1] + 0.03 : 0;
      let entry = null;
      const end = Math.min(w.end, after), hk = f.frame(w.start);
      if (i > 0 && w.start < flat[i - 1].end + 0.05) {
        let quiet = 0;
        for (let k = hk; k < Math.max(hk, f.frame(end - 0.25)); k++) {
          if (!f.isVoiced(k)) { quiet++; continue; }
          if (quiet >= 20 && f.sustained(k)) {
            let c = 0;
            for (let j = k; j < Math.min(f.n, k + 25); j++) if (f.isVoiced(j)) c++;
            if (c >= 20) { entry = f.time(k); break; }
          }
          quiet = 0;
        }
      }
      if (entry === null && f.isVoiced(hk)) {
        const c = f.entries(Math.max(lower + 0.12, w.start - 0.4), w.start);
        const last = c[c.length - 1];
        if (last && last.gap >= (opens[i] ? 0.05 : 0.1)) entry = f.time(last.k);
      }
      // a line opening inside a voice that never falls silent (a stem the orchestra bleeds into: Variations at 1:13, voiced
      // in every frame for seconds): voicing can't say where the singer comes in, so the loudness does, where it rises
      // most (4 dB or more), from just before the recognizer's start to 0.6 s after (a sung word is heard early there)
      if (entry === null && opens[i] && f.saturated(hk)) {
        const k = f.rise(f.frame(Math.max(lower, w.start - 0.12)), f.frame(Math.min(w.end - 0.05, w.start + 0.6))); // (the words after it follow it on)
        if (k >= 0) entry = f.time(k);
      }
      if (entry !== null) s[i] = entry;
      // else the onset nearest the recognizer's start, as strong as can be
      const reach = f.isVoiced(f.frame(w.start)) ? 0.12 : 0.35;
      const lo = f.frame(Math.max(lower, w.start - 0.12)), hi = f.frame(Math.min(after - 0.08, w.start + reach));
      if (entry === null && lo <= hi) {
        let best = -1, bs = -Infinity;
        for (let k = lo; k <= hi; k++) {
          const o = f.onset[k];
          if (!(o >= strong && f.sustained(k) && (k === 0 || o >= f.onset[k - 1]) && (k + 1 >= f.n || o >= f.onset[k + 1]))) continue;
          const sc = o * (1 - Math.abs(f.time(k) - w.start) / 0.4);
          if (sc > bs) { bs = sc; best = k; }          // the first of equals, as Swift's max(by:) keeps
        }
        if (best >= 0) s[i] = f.time(best);
      }
      s[i] = Math.max(s[i], lower);
      // held while the voice holds it (see Cadence.fit): any voice up to the heard end, then one note running on
      const stop = f.frame(after), own = f.frame(Math.min(w.end, after));
      const note = (k) => f.isVoiced(k) && f.pitch[k] > 0;
      let k = f.frame(s[i]), last = -1, quiet = 0, broke = false;
      while (k < stop) {
        if (k < own) {
          if (f.isVoiced(k)) { last = k; quiet = 0; }
          else if (++quiet >= 15) { broke = true; break; }
        } else if (note(k)) last = k;
        else {
          let c = 0;
          for (let j = Math.max(own, k - 9); j <= k; j++) if (note(j)) c++;
          if (c <= 3 && k - own >= 6) { broke = true; break; }
        }
        k++;
      }
      if (last < 0) e[i] = Math.min(w.end, after);
      else if (!broke && after < Infinity) { e[i] = after; legato[i] = after === next[i]; }
      else e[i] = f.time(last + 1);
      e[i] = Math.min(Math.max(e[i], s[i] + 0.05), s[i] + 8);
    }
    // a word ends where the next starts, once those have moved
    for (let i = 0; i < n; i++) {
      if (next[i] === Infinity) continue;
      let j = i + 1;
      while (j < n && !(flat[j].start > flat[i].start)) j++;
      if (j >= n) continue;
      e[i] = legato[i] ? Math.max(s[i] + 0.05, s[j]) : Math.min(e[i], Math.max(s[i] + 0.05, s[j]));
    }
    // then a song's words hung on the voice's own syllables (align): the audio decides when each is sung, and for how
    // long; a written word that isn't sung is marked so
    const { res: syl, un } = align(lines, f, flat, s, e);
    const r3 = (x) => Math.round((x + shift) * 1000) / 1000;
    let i = 0;
    return lines.map((l) => {
      const { _learn, ...rest } = l;               // (the page's per-line cache, worked out from the old times)
      const words = (l.words || []).map((w) => {
        const { syl: _, un: __, ...o } = w;
        o.s = r3(s[i]);
        o.e = r3(e[i]);
        if (syl[i]) o.syl = syl[i].map((y) => ({ c: y.c, s: r3(y.s), e: r3(y.e) }));
        if (un[i]) o.un = true;
        i++;
        return o;
      });
      return words.length ? { ...rest, words, s: words[0].s, e: words[words.length - 1].e } : rest;
    });
  }

  // Can a song's words be trusted enough to show them, and the notation drawn from them? (item 22; the same rule as
// Recense's Cadence.confidence in Sill.) Not where many voices sing at once (a choir) or few words were heard
// surely, unless the song's own lyrics were found and its lines are theirs. A listener can still show them.
  //   dense   from the voice measured on the vocal stem: a single voice holds its notes, so the pitch tracked frame to
  //           frame rarely jumps (≤ 5 % of steps by more than 1.5 semitones in the songs and speech measured) and runs
  //           on (8 frames or more at the median); in a choir it hops between voices (Whitacre: 7.3 %, 4 frames).
  //           Dense: jumps ≥ 6 % with runs ≤ 6 frames, or jumps ≥ 9 %. Unknown without the voice.
  //   lyric   most of its lines are the song's lyrics (ids 2 000 000…) rather than words as heard (3 000 000…)
  //   rate    words heard a minute: under 15 with no voice measured (the Whitacre: 7)
  // Speech (ids under 2 000 000) is never turned off.
  function confidence(lines, F, duration) {
    const ls = (Array.isArray(lines) ? lines : []).filter((l) => l && Array.isArray(l.words) && l.words.length);
    let speech = 0, lyric = 0, heard = 0, words = 0, last = 0;
    for (const l of ls) {
      const id = Number(l.id);
      if (id < 2000000) speech++;
      else if (id < 3000000) lyric++;
      else if (id < 4000000) heard++;
      words += l.words.length;
      last = Math.max(last, Number(l.words[l.words.length - 1].e) || 0);
    }
    const song = lyric + heard > speech;
    const fromLyrics = lyric > 0 && lyric >= heard;
    const d = Number(duration) > 0 ? Number(duration) : last;
    const rate = d > 0 ? (words / d) * 60 : 0;
    let dense = null;
    if (F && F.source === "vocals" && Array.isArray(F.pitch) && Array.isArray(F.voiced)) {
      const p = F.pitch, v = F.voiced, n = Math.min(p.length, v.length);
      const on = (k) => v[k] === 1 && p[k] > 0;
      let pitched = 0, pairs = 0, jumps = 0, run = 0;
      const runs = [];
      for (let k = 0; k < n; k++) {
        if (on(k)) {
          pitched++;
          run++;
          if (k + 1 < n && on(k + 1)) { pairs++; if (Math.abs(p[k + 1] - p[k]) > 150) jumps++; }
        } else if (run) { runs.push(run); run = 0; }
      }
      if (run) runs.push(run);
      if (pitched >= 500 && pairs) {
        runs.sort((a, b) => a - b);
        const j = jumps / pairs, r = runs[Math.floor(runs.length / 2)];
        dense = (j >= 0.06 && r <= 6) || j >= 0.09;
      }
    }
    const off = song && !fromLyrics && (dense === null ? rate < 15 : dense);
    return { off, why: dense ? "dense" : "sparse", dense, lyric: fromLyrics, song, rate: Math.round(rate * 10) / 10 };
  }

  // The listener's own timing (a word's `tm` { s, e, k }: corrections field "time", set with the word's sliders while
  // listening, notes 20261029 row 35) over whatever was worked out: the word is lit from s to e, its light shaped by k
  // (fillOf), and the words beside it give way so none runs into it. Times in the lines' own time.
  function pin(lines) {
    if (!Array.isArray(lines)) return lines;
    return lines.map((l) => {
      const ws = l.words || [];
      if (!ws.some((w) => w.tm)) return l;
      const words = ws.map((w) => {
        if (!w.tm) return w;
        const { syl: _, un: __, ...o } = w;
        return { ...o, s: w.tm.s, e: w.tm.e, k: w.tm.k };
      });
      for (let i = 0; i < words.length; i++) {
        if (!words[i].tm) continue;
        const p = words[i - 1], q = words[i + 1];
        if (p && !p.tm && p.e > words[i].s) words[i - 1] = trim(p, Math.min(p.s, words[i].s), words[i].s);
        if (q && !q.tm && q.s < words[i].e) words[i + 1] = trim(q, words[i].e, Math.max(q.e, words[i].e + 0.05));
      }
      return { ...l, words, s: Math.min(...words.map((w) => w.s)), e: Math.max(...words.map((w) => w.e)) };
    });
  }
  // a word moved to [s, e], its syllables kept inside it
  const trim = (w, s, e) => ({ ...w, s, e, ...(w.syl ? { syl: w.syl.map((y) => ({ c: y.c, s: Math.min(Math.max(y.s, s), e), e: Math.min(Math.max(y.e, s), e) })) } : {}) });

  // How far the light has crossed a word at t, 0 … 1: the one rule for the captions (gallery.js fillOf), the notation
  // lane (prosogram-mount.js) and Sill (Cadence.progress), so the word and the line under it are lit to the same point.
  // `n`: the word's letters. Timed by the listener (k): one sweep shaped by k. Else syllable by syllable, each one's
  // letters spread over the time it is sung, up to the next one (or 0.25 s past its end); else even across the word.
  function fill(w, t, n) {
    if (w.un) return 0;
    if (w.k !== undefined) {
      const u = Math.max(0, Math.min(1, (t - w.s) / Math.max(0.05, w.e - w.s)));
      return Math.pow(u, Math.pow(2, -1.5 * w.k));
    }
    if (!(w.syl && w.syl.length && n)) return t >= w.e ? 1 : Math.max(0, Math.min(1, (t - w.s) / Math.max(0.05, w.e - w.s)));
    let c0 = 0;
    for (let k = 0; k < w.syl.length; k++) {
      const y = w.syl[k], end = k + 1 < w.syl.length ? Math.min(w.syl[k + 1].s, y.e + 0.25) : y.e;
      if (t < y.s) return c0 / n;
      if (t < end) return Math.min(1, (c0 + (y.c - c0) * (t - y.s) / Math.max(0.05, end - y.s)) / n);
      c0 = y.c;
    }
    return 1;
  }

  const api = { fit, pin, fill, confidence, syllables, units: (F) => (F && Array.isArray(F.db) ? unitsOf(voiceOf(F)) : []) };
  if (typeof globalThis !== "undefined") globalThis.Cadence = api;
  if (typeof module !== "undefined") module.exports = api;
})();
