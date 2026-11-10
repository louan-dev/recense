// Learn's pure rules, moved out of gallery.js unchanged (coordinator, 2026-11-09) so the editor's Recense layer and
// Gallery's player share one copy: a line's beats, its phrases (a run of original words and the run of translation
// that goes with it), where a clause ends, which short words lean on the next. Ported from Recense (main.swift:
// phrases, readBy); recense.swift's phrases() is the Swift side.
// A classic script, not a module: it defines one global, RecenseLearn, and loads before gallery.js
// (library/src/page/gallery.js). Draftpad's editor imports it for that side effect (Follow/Learn on a lens).
(() => {
  "use strict";

  // Scripts written without spaces between words (Chinese, Japanese, Thai, Lao, Khmer, Burmese, Tibetan); gallery.js
  // builds its unspaced-word rules from this too.
  const UNSPACED = "[\\u0E00-\\u0EFF\\u0F00-\\u0FFF\\u1000-\\u109F\\u1780-\\u17FF\\u2E80-\\u2FFF\\u3000-\\u30FF\\u3100-\\u312F\\u31A0-\\u31FF\\u3400-\\u4DBF\\u4E00-\\u9FFF\\uF900-\\uFAFF\\uFE30-\\uFE4F\\uFF00-\\uFFEF\\u{20000}-\\u{3134F}]";
  const U_ANY = new RegExp(UNSPACED, "u");

  const TURN = 0.3; // how long a heard phrase takes to turn into its English

  // (and the stops of Chinese, Arabic and Ge'ez: ，。；：？！、 ، ؛ ؟ ። ፣ ፤ ፧)
  const endsClause = (w) => /[,.;:?!…，。；：？！、،؛؟።፣፤፧]$/.test(String(w).replace(/["'»”’)」』]+$/, ""));
  // (a Chinese or Thai word is short without leaning on the next)
  const leansOn = (w) => !endsClause(w) && !U_ANY.test(w) && (String(w).match(/\p{L}/gu) || []).length <= 3;
  const LEAN_EN = new Set(
    ("a an the of to in on at by for from with into about as and or but if than that which who whose this these those " +
      "my your his her its our their i you he she it we they is are was were be been am do does did have has had will " +
      "would shall should can could may might must not no").split(" ")
  );
  const leansOnEnglish = (w) => !endsClause(w) && LEAN_EN.has(String(w).toLowerCase().replace(/[^\p{L}']/gu, ""));
  const readingTime = (n) => 0.7 + 0.28 * n;

  // a line's words as beats: each lasts until the next one starts
  const sourceBeats = (l) =>
    l.words.map((w, i) => {
      const next = i + 1 < l.words.length ? l.words[i + 1].s : Infinity;
      // a short pause before the next word is bridged, so the light never drops out between words
      const e = next - w.e < 0.6 ? next : w.e;
      return { t: w.t, s: w.s, e: w.k !== undefined || w.c ? w.e : Math.max(w.s + 0.05, Math.min(e, next)), h: w.h, syl: w.syl, un: w.un, k: w.k, c: w.c, tm: w.tm };
    });

  // the original words an English word translates; one claiming most of a long line is a misread alignment
  const sourcesOf = (w, m) => {
    const s = (w.s || []).filter((x) => x >= 0 && x < m);
    return m > 3 && s.length > Math.max(2, Math.floor(m / 2)) ? [] : s;
  };

  const translated = (l) => Array.isArray(l.enw) && l.enw.length > 0 && !(l.enw.length === 1 && l.enw[0].w === "…");

  // A line's phrases: a run of original words and the run of English that translates it. Cut where
  // the speech pauses or a clause ends, rarely on a short word that leans on the next, with the
  // English cut at the same share of the English, a little behind rather than ahead.
  const phrasesOf = (l) => {
    const words = l.words.map((w) => w.t);
    const en = l.enw;
    const m = words.length;
    const n = en.length;
    if (m <= 1 || n <= 1) return [{ src: [0, m], en: [0, n] }];

    const s = en.map((w) => sourcesOf(w, m));
    const aligned = s.every((x) => x.length) && !s.every((x, i) => x.length === 1 && x[0] === i);
    const shares = (w) => {
      const c = [0];
      for (const x of w) c.push(c[c.length - 1] + x.length + 1);
      return c.map((v) => v / c[c.length - 1]);
    };
    const po = shares(words);
    const pe = shares(en.map((w) => w.w));
    const cut = new Map();

    for (let i = 1; i < m; i++) {
      let best = null;
      for (let k = 1; k < n; k++) {
        if (aligned && (s.slice(0, k).some((x) => Math.max(...x) >= i) || s.slice(k).some((x) => Math.min(...x) < i))) continue;
        let c = Math.abs(pe[k] - (po[i] - 0.04)) * 4 + (leansOnEnglish(en[k - 1].w) ? 0.6 : 0);
        if (endsClause(words[i - 1]) && endsClause(en[k - 1].w)) c -= 0.5;
        if (!best || c < best.cost) best = { k, cost: c };
      }
      if (!best) continue;
      if (endsClause(words[i - 1])) best.cost -= 1.2;
      if (l.words[i].s - l.words[i - 1].e >= 0.25) best.cost -= 0.8;
      if (leansOn(words[i - 1])) best.cost += 0.8;
      if (!aligned) best.cost += 0.5; // a guessed cut can be a word out: fewer of them
      cut.set(i, best);
    }

    // the cheapest run of cuts, with phrases of three or four words where it can
    const size = [0, 2, 0.5, 0, 0.1, 0.7];
    const path = [{ at: 0, k: 0, cost: 0, from: -1 }];
    for (const j of [...[...cut.keys()].sort((x, y) => x - y), m]) {
      const k = j < m ? cut.get(j).k : n;
      const c = j < m ? cut.get(j).cost : 0;
      let best = null;
      path.forEach((p, i) => {
        if (p.k >= k) return;
        const len = j - p.at;
        const cost = p.cost + (len < size.length ? size[len] : 0.7 + (len - 5)) + c;
        if (!best || cost < best.cost) best = { from: i, cost };
      });
      if (best) path.push({ at: j, k, cost: best.cost, from: best.from });
    }

    const out = [];
    for (let i = path.length - 1; i > 0; ) {
      const p = path[i];
      const q = path[p.from];
      out.unshift({ src: [q.at, p.at], en: [q.k, p.k] });
      i = p.from;
    }
    return out;
  };

  (typeof globalThis !== "undefined" ? globalThis : window).RecenseLearn = Object.freeze({
    TURN, endsClause, leansOn, leansOnEnglish, readingTime, sourceBeats, sourcesOf, translated, phrasesOf, UNSPACED
  });
})();
