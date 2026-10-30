// Corrections to Recense's transcripts: what listeners fixed, laid over what the ASR wrote.
//
// Kept beside the transcript in Recense's bucket, in the file Recense keeps its own fixes in
// (keep/<key>/corrections.json, formerly keep/<key>.edits.json; layout.js, main.swift: Edits). Recense's own fields (edits, english, last) are passed through
// untouched; the shared ones are:
//   { version, updatedAt, overrides: [{ segId, start, end, field, to, src, updatedAt }], glossary: { wrong: right } }
// (a glossary word taught back is kept as "": forgotten)
// field = "text" or "tr.<lang>"; src = "main" or "share"; times are transcript time (before an alias's shift),
// updatedAt in ms. The same rules run in Recense (main.swift: applyEdits), so both show the same words.
//
// Load order: the ASR's lines -> Recense's own edits (time stretches) -> overrides (by segId, else the line
// covering >= 50 % of the override's span) -> glossary on every line no one corrected the text of.

export const MAX_TEXT = 2000;
export const HISTORY = 20;
export const EDITED = 4000000; // a line one of Recense's edits made: EDITED + edit id
export const CUT_SHORT = 1000000; // an ASR line an edit cut short: its id + EDITED + CUT_SHORT

const EDGE = /^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/gu;
export const fold = (w) => String(w).normalize("NFC").replace(EDGE, "").toLowerCase();
const parts = (w) => {
  const m = String(w).normalize("NFC").match(/^([^\p{L}\p{N}]*)([\s\S]*?)([^\p{L}\p{N}]*)$/u);
  return m ? [m[1], m[2], m[3]] : ["", String(w), ""];
};
export const tokens = (s) => String(s || "").trim().split(/\s+/).filter(Boolean);
const joinWords = (ws) => ws.join(" ").replace(/\s+([,.!?;:…])/g, "$1").trim();
const r3 = (x) => Math.round(x * 1000) / 1000;

export const emptyDoc = () => ({ edits: [], english: {}, version: 0, updatedAt: 0, overrides: [], glossary: {} });

// a stored corrections file, with the shared fields made safe to use (Recense's own kept as they are)
export function normalizeDoc(d) {
  const doc = { ...emptyDoc(), ...(d && typeof d === "object" ? d : {}) };
  if (!Array.isArray(doc.edits)) doc.edits = [];
  if (!doc.english || typeof doc.english !== "object") doc.english = {};
  doc.version = Number.isInteger(doc.version) ? doc.version : 0;
  doc.updatedAt = Number(doc.updatedAt) || 0;
  doc.overrides = Array.isArray(doc.overrides)
    ? doc.overrides.filter((o) => o && o.segId != null && typeof o.to === "string" && /^(text|tr\.[a-z]{2,3})$/.test(o.field))
    : [];
  if (!doc.glossary || typeof doc.glossary !== "object" || Array.isArray(doc.glossary)) doc.glossary = {};
  return doc;
}

// ---------- the ASR's lines ----------

// Recense's transcript (asr.json with its English, or an old <key>.v2.json; layout.js) as lines in transcript time; a line without an id gets one from its start
export function baseLines(c) {
  const out = [];
  for (const l of (c && c.lines) || []) {
    const words = (l.words || []).filter((w) => w && typeof w.text === "string");
    if (!words.length) continue;
    out.push({
      id: l.id != null ? String(l.id) : "t" + Math.round(Number(words[0].start) * 1000),
      // h: what the recognizer heard where Recense's lexicon (what corrections taught it) wrote this word instead
      words: words.map((w) => (typeof w.heard === "string" ? { t: w.text, s: Number(w.start), e: Number(w.end), h: w.heard } : { t: w.text, s: Number(w.start), e: Number(w.end) })),
      english: l.english,
    });
  }
  return out;
}

const startOf = (l) => l.words[0].s;
const endOf = (l) => l.words[l.words.length - 1].e;

// ---------- Recense's own edits (main.swift: applyEdits) ----------

export function applyNative(lines, doc) {
  const edits = (doc.edits || []).filter((x) => x && Number.isFinite(x.a) && Number.isFinite(x.b));
  if (!edits.length) return lines;
  const english = doc.english || {};
  const owned = (w) => {
    const m = (w.s + w.e) / 2;
    return edits.some((x) => m >= x.a && m <= x.b);
  };
  const out = [];
  for (const l of lines) {
    const kept = l.words.filter((w) => !owned(w));
    if (kept.length === l.words.length) {
      out.push(l);
      continue;
    }
    if (!kept.length) continue;
    const key = kept.map((w) => w.t).join(" ");
    const n = Number(l.id);
    out.push({
      id: Number.isInteger(n) ? String(n + EDITED + CUT_SHORT) : l.id + "~",
      words: kept,
      english: Array.isArray(l.english) && !l.english.length ? [] : english[key] || null,
    });
  }
  for (const x of edits) {
    const words = (x.words || []).filter((w) => w && typeof w.text === "string");
    if (!words.length) continue;
    const key = words.map((w) => w.text).join(" ");
    out.push({
      id: String(EDITED + x.id),
      words: words.map((w) => ({ t: w.text, s: Number(w.start), e: Number(w.end) })),
      english: english[key] || null,
      human: true,
      at: Number(x.at) || 0, // when Recense's listener made it (ms); 0 = before overrides existed
    });
  }
  return out.sort((a, b) => startOf(a) - startOf(b));
}

// ---------- overrides ----------

// New words timed over the ones they replace, each where the same share of the characters falls (main.swift: layOver)
export function layOver(words, heard) {
  if (!heard.length || !words.length) return [];
  const len = (s) => [...s].length;
  const hc = heard.map((w) => len(w.t) + 1);
  const totalH = hc.reduce((a, b) => a + b, 0);
  const totalL = words.reduce((a, w) => a + len(w) + 1, 0);
  const time = (x) => {
    let at = 0;
    for (let i = 0; i < heard.length; i++) {
      if (x <= at + hc[i]) return heard[i].s + ((x - at) / hc[i]) * (heard[i].e - heard[i].s);
      at += hc[i];
    }
    return heard[heard.length - 1].e;
  };
  const out = [];
  let x = 0;
  for (const w of words) {
    const c = ((len(w) + 1) * totalH) / totalL;
    const s = Math.max(time(x), (out.length ? out[out.length - 1].s : -1) + 0.02);
    out.push({ t: w, s, e: Math.max(s + 0.05, time(x + c - 1)) });
    x += c;
  }
  return out;
}

// the line an override is for: its own segment, else the one covering at least half its span (never a line a
// listener in Recense corrected after the override was made)
export function targetOf(lines, o, byId) {
  const i = byId.get(String(o.segId));
  if (i !== undefined) return i;
  const a = Number(o.start);
  const b = Number(o.end);
  if (!Number.isFinite(a) || !Number.isFinite(b)) return -1;
  let best = -1;
  let most = 0;
  lines.forEach((l, k) => {
    if (l.human && l.at > (Number(o.updatedAt) || 0)) return;
    const s = startOf(l);
    const e = endOf(l);
    const ov = b > a ? Math.min(e, b) - Math.max(s, a) : (a + b) / 2 >= s && (a + b) / 2 <= e ? 1 : 0;
    const share = b > a ? ov / (b - a) : ov;
    if (share >= 0.5 && ov > most) {
      most = ov;
      best = k;
    }
  });
  return best;
}

export function applyOverrides(lines, overrides) {
  if (!overrides || !overrides.length) return lines;
  const byId = new Map(lines.map((l, i) => [l.id, i]));
  const text = new Map(); // line index -> corrected text
  const tr = new Map(); // line index -> { lang: text }
  const ordered = overrides.map((o, k) => [o, k]).sort((x, y) => (Number(x[0].updatedAt) || 0) - (Number(y[0].updatedAt) || 0) || x[1] - y[1]);
  for (const [o] of ordered) {
    const i = targetOf(lines, o, byId);
    if (i < 0) continue;
    if (o.field === "text") text.set(i, o.to);
    else tr.set(i, { ...(tr.get(i) || {}), [o.field.slice(3)]: o.to });
  }
  const out = [];
  lines.forEach((l, i) => {
    let n = l;
    if (text.has(i)) {
      const ws = tokens(text.get(i));
      if (!ws.length) return; // corrected to nothing: words the ASR made up
      const same = ws.length === l.words.length;
      n = { ...l, words: layOver(ws, l.words), fixed: true, text: ws.join(" ") };
      // a translation aligned word by word no longer lines up once the words change in number
      if (!same && Array.isArray(l.english)) n.english = l.english.map((w) => ({ w: w.w, s: [] }));
    }
    if (tr.has(i)) {
      const t = tr.get(i);
      n = { ...n, tr: { ...(n.tr || {}), ...t } };
      if (t.en !== undefined) n.english = tokens(t.en).map((w) => ({ w, s: [] }));
    }
    out.push(n);
  });
  return out;
}

// ---------- glossary ----------

// a word as the glossary has it, in the case of the word it replaces
export function caseLike(orig, right) {
  if (orig.length > 1 && orig === orig.toUpperCase() && orig !== orig.toLowerCase()) return right.toUpperCase();
  const f = [...orig][0] || "";
  if (f && f === f.toUpperCase() && f !== f.toLowerCase()) return right.charAt(0).toUpperCase() + right.slice(1);
  return right;
}

export function glossWord(w, glossary) {
  const [pre, core, post] = parts(w);
  const right = glossary[core.toLowerCase()];
  return typeof right === "string" && right ? pre + caseLike(core, right) + post : w;
}

export function applyGlossary(lines, glossary) {
  if (!glossary || !Object.keys(glossary).length) return lines;
  return lines.map((l) => {
    if (l.fixed || l.human) return l;
    let changed = false;
    const words = l.words.map((w) => {
      const t = glossWord(w.t, glossary);
      if (t === w.t) return w;
      changed = true;
      return { ...w, t };
    });
    return changed ? { ...l, words } : l;
  });
}

// What an edit teaches: each word replaced by one other word (by their letters), wrong (lower case) -> right as typed.
export function learned(from, to) {
  const a = tokens(from);
  const b = tokens(to);
  const fa = a.map(fold);
  const fb = b.map(fold);
  const m = a.length;
  const n = b.length;
  const L = Array.from({ length: m + 1 }, () => new Int32Array(n + 1));
  for (let i = m - 1; i >= 0; i--) for (let j = n - 1; j >= 0; j--) L[i][j] = fa[i] === fb[j] ? L[i + 1][j + 1] + 1 : Math.max(L[i + 1][j], L[i][j + 1]);
  const out = [];
  let i = 0;
  let j = 0;
  let del = [];
  let ins = [];
  const hunk = () => {
    // as many words out as in: each one replaced by one (a run of them changed word for word)
    if (del.length === ins.length) {
      del.forEach((d, k) => {
        const wrong = fold(d);
        const right = parts(ins[k])[1];
        if (wrong && right && wrong !== fold(right)) out.push([wrong, right]);
      });
    }
    del = [];
    ins = [];
  };
  while (i < m || j < n) {
    if (i < m && j < n && fa[i] === fb[j]) {
      hunk();
      i++;
      j++;
    } else if (j < n && (i === m || L[i][j + 1] >= L[i + 1][j])) ins.push(b[j++]);
    else del.push(a[i++]);
  }
  hunk();
  return out;
}

export function teach(glossary, from, to) {
  for (const [wrong, right] of learned(from, to)) {
    // taught back the other way: the earlier lesson was the mistake ("" = forgotten, kept so Recense's merge doesn't bring it back)
    if (glossary[fold(right)] && fold(glossary[fold(right)]) === wrong) glossary[fold(right)] = "";
    else glossary[wrong] = right;
  }
  return glossary;
}

// ---------- all of it ----------

// the lines as shown, in transcript time
export function correctedLines(c, doc) {
  const d = normalizeDoc(doc);
  return applyGlossary(applyOverrides(applyNative(baseLines(c), d), d.overrides), d.glossary);
}

// shaped for the page, in this file's time (shift = this file's time - the transcript's)
export function present(lines, shift = 0) {
  const r = (x) => r3(x + shift);
  return lines
    .map((l) => {
      const en = Array.isArray(l.english) ? l.english.filter((w) => w && typeof w.w === "string") : null;
      const out = {
        id: l.id,
        s: r(startOf(l)),
        e: r(endOf(l)),
        text: l.fixed ? l.text : joinWords(l.words.map((w) => w.t)),
        en: en && en.length ? joinWords(en.map((w) => w.w)) : "",
        words: l.words.map((w) => (w.h ? { t: w.t, s: r(w.s), e: r(w.e), h: w.h } : { t: w.t, s: r(w.s), e: r(w.e) })),
        // Learn mode: the English words, each with the original words (by index) it translates; null = not translated yet
        enw: en ? en.map((w) => ({ w: w.w, s: Array.isArray(w.s) ? w.s.filter(Number.isInteger) : [] })) : null,
      };
      if (l.fixed || l.human) out.fixed = true;
      if (l.tr) out.tr = l.tr;
      return out;
    })
    .sort((a, b) => a.s - b.s);
}

// ---------- saving ----------

// Strip markup and control characters; null when too long.
export function cleanText(s) {
  const t = String(s)
    .replace(/<[^>]*>?/g, "")
    .replace(/[\u0000-\u001f\u007f]+/g, " ")
    .trim();
  return t.length > MAX_TEXT ? null : t;
}

// Overrides merged per segment and field: the latest updatedAt wins (a tie goes to `incoming`).
export function mergeOverrides(base, incoming) {
  const m = new Map();
  for (const o of [...(base || []), ...(incoming || [])]) {
    const k = o.segId + "|" + o.field;
    const had = m.get(k);
    if (!had || (Number(o.updatedAt) || 0) >= (Number(had.updatedAt) || 0)) m.set(k, o);
  }
  return [...m.values()];
}
