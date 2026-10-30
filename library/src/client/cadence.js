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

  function fit(lines, F, shift = 0) {
    if (!F || F.source !== "vocals" || !Array.isArray(F.db) || F.db.length <= 20 || !Array.isArray(lines)) return lines;
    const f = voiceOf(F);
    const flat = [];
    // back in the transcript's time, to the millisecond the Worker keeps (so a frame is the frame Recense sees)
    const back = (x) => Math.round((x - shift) * 1000) / 1000;
    for (const l of lines) for (const w of l.words || []) flat.push({ start: back(w.s), end: back(w.e) });
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
    const r3 = (x) => Math.round((x + shift) * 1000) / 1000;
    let i = 0;
    return lines.map((l) => {
      const { _learn, ...rest } = l;               // (the page's per-line cache, worked out from the old times)
      const words = (l.words || []).map((w) => ({ ...w, s: r3(s[i]), e: r3(e[i++]) }));
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

  const api = { fit, confidence };
  if (typeof globalThis !== "undefined") globalThis.Cadence = api;
  if (typeof module !== "undefined") module.exports = api;
})();
