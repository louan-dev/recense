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
    return { hop, n, onset, pitch, frame, time, isVoiced, sustained, entries, saturated, rise };
  }

  // A word's syllables, as where each ends in its letters (code points). Han, kana, Hangul and Ethiopic: a letter each.
  // Latin, Cyrillic and Greek: one per run of vowels, split where two vowels are sung apart (va-ri-a-tions; not the
  // -tion of "nation"), the consonants between two going to the second (or one to each, from two on, but pl, br… together). English
  // drops a silent final e, -es or -ed (love, loves, liked; not the, lit-tle, wan-ted). Other scripts: the word whole (the melody gives it all its notes).
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

  // The sung notes in a vocal stem's pitch track (MIDI × 100 every 10 ms): runs that keep within 0.7 semitone of their
  // own middle, through a slip of a frame or two, 40 ms or longer. `odd`: 11 semitones or more from the singer's
  // middle (an octave slip, or the accompaniment bleeding in), cheap to leave unsung.
  function notesOf(f) {
    const p = f.pitch, n = f.n, out = [];
    const mid = (v) => v.slice().sort((a, b) => a - b)[v.length >> 1];
    let cur = null;
    const close = () => { if (cur && cur.b - cur.a >= 4) out.push(cur); cur = null; };
    for (let k = 0; k < n; k++) {
      const v = f.isVoiced(k) && p[k] > 0 ? p[k] : 0;
      if (!v) { if (cur && k - cur.b >= 3) close(); continue; }
      if (cur && Math.abs(v - cur.m) <= 70) {
        cur.b = k + 1;
        cur.v.push(v);
        if (cur.v.length % 4 === 0) cur.m = mid(cur.v);
        continue;
      }
      if (cur && k - cur.b <= 1 && [1, 2].some((d) => k + d < n && p[k + d] > 0 && Math.abs(p[k + d] - cur.m) <= 70)) continue;
      close();
      cur = { a: k, b: k + 1, m: v, v: [v] };
    }
    close();
    if (!out.length) return [];
    // one note still when a glitch broke it (the same pitch on within 20 ms, or past a blip of 50 ms or less tracked
    // at another pitch); a longer break at the same pitch is a consonant, a new syllable on a repeated note
    for (let k = out.length - 1; k > 0; k--) {
      const a = out[k - 1], b = out[k];
      if (b.a - a.b <= 2 && Math.abs(mid(b.v) - mid(a.v)) <= 50) { a.b = b.b; a.v = a.v.concat(b.v); out.splice(k, 1); }
      else if (k + 1 < out.length && b.b - b.a <= 5 && out[k + 1].a - a.b <= 10 && Math.abs(mid(out[k + 1].v) - mid(a.v)) <= 50) {
        a.b = out[k + 1].b; a.v = a.v.concat(out[k + 1].v); out.splice(k, 2);
      }
    }
    const byLen = out.map((x) => [x.m, x.b - x.a]).sort((a, b) => a[0] - b[0]);
    let half = byLen.reduce((a, x) => a + x[1], 0) / 2, reg = byLen[0][0];
    for (const [m, d] of byLen) { reg = m; if ((half -= d) <= 0) break; }
    return out.map((x) => ({ s: f.time(x.a), e: f.time(x.b), m: mid(x.v), odd: Math.abs(mid(x.v) - reg) >= 1100 }));
  }

  // Lyric to melody: each line of a song (ids 2 000 000 and up), its syllables in order, laid on the notes sung from
  // just before its first word to the next line's (or 1.5 s past its last), by the cheapest of all the ways to do it (dynamic programming):
  //   a syllable starts on a note:  how far from where the recognizer put it, in 0.35 s (≤ 3; half within a word)
  //   a note left unsung:           its length in 0.1 s (a fifth of that when odd)
  //     + 0.8 straight on from the note before (no consonant between: the same vowel moving on)
  //   a note run on by a syllable:  straight on 0.2 at the same pitch, 0.6 to another (a held word falling to its next
  //                                 note); after a gap under 0.1 s 1.5, longer 2.5 (a consonant starts a syllable)
  //   a syllable on no note:        2.5 (sung unvoiced; it takes the time between its neighbours)
  // A word then starts on its first syllable's note, unless that's more than 1.2 s from where it was, and ends with
  // its last syllable's. Lines with fewer notes than a third of their syllables (spoken, rapped) are left as they are.
  // → per word, its syllables [{ c, s, e }] (c: where it ends in the word's letters), or null.
  function melody(lines, f, flat, s, e) {
    const res = new Array(flat.length).fill(null);
    if (!Array.isArray(f.pitch) || f.pitch.length < f.n) return res;
    const notes = notesOf(f);
    if (!notes.length) return res;
    let at = 0, taken = 0;
    for (const l of lines) {
      const from = at, c = (l.words || []).length;
      at += c;
      if (!c || !(Number(l.id) >= 2000000)) continue;
      const lo = Math.max(s[from] - 0.35, taken), hi = Math.min(at < flat.length ? s[at] - 0.03 : Infinity, e[at - 1] + 1.5);
      const W = notes.filter((x) => x.s >= lo && x.s < hi);
      const Y = [];
      for (let i = from; i < at; i++) {
        const cut = syllables(flat[i].t, flat[i].lang), K = cut.length || 1;
        for (let k = 0; k < K; k++) Y.push({ i, c: cut[k] || Array.from(flat[i].t).length, exp: s[i] + ((e[i] - s[i]) * k) / K, wt: k ? 0.5 : 1 });
      }
      const N = W.length, S = Y.length;
      if (!N || N < S / 3) continue;
      // the unpitched gap before each note, past odd blips: a consonant (a new syllable) when 30 ms or more
      const gb = new Float64Array(N), pm = new Float64Array(N);
      let le = -Infinity, lm = 0;
      for (let k = 0; k < N; k++) { gb[k] = W[k].s - le; pm[k] = lm; if (!W[k].odd) { le = W[k].e; lm = W[k].m; } }
      const P = new Float64Array(N + 1), M = new Float64Array(N);
      for (let k = 0; k < N; k++) P[k + 1] = P[k] + ((W[k].e - W[k].s) / 0.1) * (W[k].odd ? 0.2 : 1);
      for (let k = 1; k < N; k++) {
        const g = gb[k], same = Math.abs(W[k].m - pm[k]) <= 50;
        M[k] = M[k - 1] + (W[k].odd ? 0.2 : g <= 0.03 ? (same ? 0.2 : 0.6) : g < 0.1 ? 1.5 : 2.5);
      }
      const start = (y, a) => y.wt * Math.min(3, Math.abs(W[a].s - y.exp) / 0.35) + (W[a].odd ? 1 : 0) + (gb[a] <= 0.03 ? 0.8 : 0);
      // D[y][j]: the cheapest with syllable y the last laid, j notes behind it; how: -1 on no note, else its first note a
      const D = [], how = [], back = [];
      let prev = new Float64Array(N + 1).fill(Infinity);
      prev[0] = 0;
      for (let y = 0; y < S; y++) {
        const cur = new Float64Array(N + 1).fill(Infinity), h = new Int32Array(N + 1).fill(-2), bq = new Int32Array(N);
        let mq = Infinity, q = -1, ma = Infinity, a0 = -1;
        for (let a = 0; a < N; a++) {
          if (prev[a] - P[a] < mq) { mq = prev[a] - P[a]; q = a; }
          bq[a] = q;
          const best = P[a] + mq + start(Y[y], a) - M[a];
          if (best < ma) { ma = best; a0 = a; }
          const v = M[a] + ma;
          if (v < cur[a + 1]) { cur[a + 1] = v; h[a + 1] = a0; }
        }
        for (let j = 0; j <= N; j++) if (prev[j] + 2.5 < cur[j]) { cur[j] = prev[j] + 2.5; h[j] = -1; }
        D.push(cur); how.push(h); back.push(bq);
        prev = cur;
      }
      let j = 0, bestEnd = Infinity;
      for (let k = 0; k <= N; k++) { const v = prev[k] + (P[N] - P[k]); if (v < bestEnd) { bestEnd = v; j = k; } }
      if (!(bestEnd < Infinity)) continue;
      const got = new Array(S).fill(null);
      for (let y = S - 1; y >= 0; y--) {
        const a = how[y][j];
        if (a === -2) break;
        if (a === -1) continue;
        got[y] = { s: W[a].s, e: W[j - 1].e };
        j = back[y][a];
      }
      // each word from its syllables; one on no note takes the time between its neighbours in the word
      for (let i = from; i < at; i++) {
        const ys = Y.map((y, k) => (y.i === i ? k : -1)).filter((k) => k >= 0);
        const sung = ys.filter((k) => got[k]);
        if (!sung.length) continue;
        const ns = got[sung[0]].s;
        if (Math.abs(ns - s[i]) > 1.2) continue;
        const ne = Math.max(ns + 0.05, got[sung[sung.length - 1]].e);
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
        taken = Math.max(taken, ne);
      }
    }
    // in order still, and none running into the next
    for (let i = 1; i < flat.length; i++) if (s[i] < s[i - 1]) s[i] = s[i - 1];
    for (let i = 0; i + 1 < flat.length; i++) {
      if (s[i + 1] > s[i] && e[i] > s[i + 1]) e[i] = Math.max(s[i] + 0.05, s[i + 1]);
      if (res[i]) for (const y of res[i]) { y.e = Math.min(y.e, e[i]); y.s = Math.min(y.s, y.e); }
    }
    return res;
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
    // then a song's syllables on the notes they're sung on (melody): a word starts with its first syllable's note and
    // is held for as long as its last syllable's is
    const syl = melody(lines, f, flat, s, e);
    const r3 = (x) => Math.round((x + shift) * 1000) / 1000;
    let i = 0;
    return lines.map((l) => {
      const { _learn, ...rest } = l;               // (the page's per-line cache, worked out from the old times)
      const words = (l.words || []).map((w) => {
        const { syl: _, ...o } = w;
        o.s = r3(s[i]);
        o.e = r3(e[i]);
        if (syl[i]) o.syl = syl[i].map((y) => ({ c: y.c, s: r3(y.s), e: r3(y.e) }));
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

  const api = { fit, confidence, syllables };
  if (typeof globalThis !== "undefined") globalThis.Cadence = api;
  if (typeof module !== "undefined") module.exports = api;
})();
