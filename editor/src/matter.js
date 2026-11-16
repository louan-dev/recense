// FEAT-08 · Draftpad as one matter (docs/specs/FEAT-08-draftpad-one-matter.md; law: docs/law/purpose.md).
//
// One page in four states: ink (solid), type (liquid, the markdown body), mark (gas), voice (plasma).
// The body stays plain markdown (rule 5): `draftpad.md`. Strokes stay in `draftpad.ink.json`.
// What markdown cannot hold lives in one sidecar beside the page, `draftpad.matter.json`:
//   passages: one record per passage, its seed (device, input, time) and its forms in each state, linked;
//   log: every crossing, in order, with what it needs to reverse exactly.
// A crossing adds or links a form; it never removes a word, a stroke or a second of audio, never makes a file,
// and `reverseLast` undoes it to the same matter. Pure functions: no DOM, no host; the editor and the hosts
// call them (index.js `cross`, `reverseCrossing`, `getMatter`, `setMatter`, `mergeMatter`).
import { anchorStrokeToDoc, getDocumentPages, DEFAULT_LINE_HEIGHT } from './ink.js';
import { PAGE_MARKER } from './pages.js';

export const STATES = ['ink', 'type', 'mark', 'voice'];

/** The twelve crossings (purpose.md table, same numbers). */
export const CROSSINGS = [
  { n: 1, from: 'ink', to: 'type', name: 'melting' },
  { n: 2, from: 'type', to: 'ink', name: 'freezing' },
  { n: 3, from: 'type', to: 'mark', name: 'vaporizing' },
  { n: 4, from: 'mark', to: 'type', name: 'condensing' },
  { n: 5, from: 'ink', to: 'mark', name: 'subliming' },
  { n: 6, from: 'mark', to: 'ink', name: 'deposition' },
  { n: 7, from: 'mark', to: 'voice', name: 'ionizing' },
  { n: 8, from: 'voice', to: 'mark', name: 'recombining' },
  { n: 9, from: 'type', to: 'voice', name: 'read aloud' },
  { n: 10, from: 'voice', to: 'type', name: 'dictation' },
  { n: 11, from: 'ink', to: 'voice', name: 'handwriting read aloud' },
  { n: 12, from: 'voice', to: 'ink', name: 'spoken pin' }
];

/** One walk through all twelve, each starting where the last ended (an Eulerian circuit of the four states). */
export const CIRCUIT = [1, 3, 7, 12, 5, 4, 9, 8, 6, 11, 10, 2];

export const FILES = { text: 'draftpad.md', ink: 'draftpad.ink.json', side: 'draftpad.matter.json' };

const clone = v => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));
const emptyInk = () => ({ version: 1, strokes: [], removed: [] });
const emptySide = () => ({ version: 1, passages: {}, log: [] });

export function createMatter({ text = '', ink = null, side = null } = {}) {
  return { text: String(text), ink: clone(ink) || emptyInk(), side: clone(side) || emptySide() };
}

export function toFiles(m) {
  return {
    [FILES.text]: m.text,
    [FILES.ink]: JSON.stringify(m.ink),
    [FILES.side]: JSON.stringify(m.side)
  };
}

export function fromFiles(files) {
  const j = (s, d) => (typeof s === 'string' && s.trim() ? JSON.parse(s) : d());
  return createMatter({ text: files[FILES.text] || '', ink: j(files[FILES.ink], emptyInk), side: j(files[FILES.side], emptySide) });
}

// ---- words, language, timing -------------------------------------------------------------------------------

export function wordsOf(text) {
  return String(text || '').match(/[\p{L}\p{N}’']+/gu) || [];
}

export function guessLang(text) {
  const s = String(text || '').toLowerCase();
  if (/[ăâđêôơưạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ]/.test(s)) return 'vi';
  if (/[éèêëàçùûôîœ]|\b(le|la|les|des|est|une|du|et)\b/.test(s)) return 'fr';
  return 'en';
}

/** A read-aloud plan until the host's synthesizer reports real word times (`willSpeakRange`). */
export function estimateWordTimes(text) {
  let t = 0;
  return wordsOf(text).map(w => {
    const d = Math.round((0.12 + 0.06 * w.length) * 1000) / 1000;
    const out = { w, t0: Math.round(t * 1000) / 1000, t1: Math.round((t + d) * 1000) / 1000 };
    t += d + 0.05;
    return out;
  });
}

const spokenText = e => (e.words || []).map(w => w.w).join(' ');
const spokenKey = e => `${e.audio || ''}|${e.at ?? ''}|${spokenText(e)}`;

// ---- anchors in the body -----------------------------------------------------------------------------------

const CTX = 32;
export function makeQuote(text, off, len) {
  return { quote: text.slice(off, off + len), prefix: text.slice(Math.max(0, off - CTX), off), suffix: text.slice(off + len, off + len + CTX) };
}

/** Where a text-quote anchor sits now (W3C TextQuote style): the occurrence whose context matches best, or -1. */
export function findQuote(text, a) {
  if (!a || !a.quote) return -1;
  let best = -1;
  let bestScore = -1;
  for (let i = text.indexOf(a.quote); i !== -1; i = text.indexOf(a.quote, i + 1)) {
    let s = 0;
    const pre = a.prefix || '';
    while (s < pre.length && text[i - 1 - s] === pre[pre.length - 1 - s]) s++;
    let f = 0;
    const suf = a.suffix || '';
    const e = i + a.quote.length;
    while (f < suf.length && text[e + f] === suf[f]) f++;
    if (s + f > bestScore) { bestScore = s + f; best = i; }
  }
  return best;
}

function count(text, q) {
  if (!q) return 0;
  let n = 0;
  for (let i = text.indexOf(q); i !== -1; i = text.indexOf(q, i + 1)) n++;
  return n;
}

const eolOf = text => (text.includes('\r\n') ? '\r\n' : '\n');

/** End offset (before its line break) of the line holding `off`. */
function lineEnd(text, off) {
  let e = text.indexOf('\n', off);
  if (e === -1) return text.length;
  if (text[e - 1] === '\r') e--;
  return e;
}
function lineStart(text, off) {
  return text.lastIndexOf('\n', off - 1) + 1;
}

/** Page and line-in-page of a body offset, in the terms ink anchors use (ink.js getDocumentPages). */
function placeOf(text, off) {
  const lineNumber = text.slice(0, off).split('\n').length; // 1-based
  const pages = getDocumentPages(text);
  const p = pages.find(pg => lineNumber >= pg.startLine && lineNumber <= Math.max(pg.startLine, pg.endLine)) || pages[0];
  return { pageIndex: p.index, line: Math.max(0, lineNumber - p.startLine) };
}

/** Offset of the end of line `line` (0-based) inside page `pageIndex`. */
function offsetOfPageLine(text, pageIndex, line) {
  const pages = getDocumentPages(text);
  const p = pages[Math.min(pages.length - 1, Math.max(0, pageIndex))];
  const ln = p.startLine + Math.max(0, Math.min(Math.max(0, p.lines.length - 1), line)); // 1-based
  let off = 0;
  for (let i = 1; i < ln; i++) off = text.indexOf('\n', off) + 1;
  return lineEnd(text, off);
}

/** End of the last line holding words on a page (where a continuation lands, in order). */
function pageTailOffset(text, pageIndex) {
  const pages = getDocumentPages(text);
  const p = pages[Math.min(pages.length - 1, Math.max(0, pageIndex))];
  let i = p.lines.length - 1;
  while (i > 0 && !p.lines[i].trim()) i--;
  return offsetOfPageLine(text, p.index, i);
}

// ---- ink helpers -------------------------------------------------------------------------------------------

function strokesOf(m, p) {
  const ids = new Set((p.forms.ink && p.forms.ink.strokes) || []);
  return m.ink.strokes.filter(s => ids.has(s.id));
}

function inkReading(strokes) {
  const parts = [];
  for (const s of strokes) {
    const t = s.ocr && typeof s.ocr.t === 'string' ? s.ocr.t.trim() : '';
    if (t && parts[parts.length - 1] !== t) parts.push(t);
  }
  return parts.join(' ');
}

function bbox(strokes) {
  const pts = strokes.flatMap(s => s.points || []);
  const xs = pts.map(p => p[0]);
  const ys = pts.map(p => p[1]);
  const x = Math.min(...xs);
  const y = Math.min(...ys);
  return { x, y, w: Math.max(...xs) - x, h: Math.max(...ys) - y };
}

function inkAnchor(m, strokes) {
  const first = strokes[0];
  if (first.anchor) return clone(first.anchor);
  const b = bbox(strokes);
  return anchorStrokeToDoc({ points: [[b.x, b.y]] }, m.text, DEFAULT_LINE_HEIGHT);
}

/** Words of a frozen passage, offsets inside its quote: the targets strokes drawn over it anchor to. */
export function wordSurface(quote) {
  const out = [];
  const re = /[\p{L}\p{N}’']+/gu;
  let r;
  while ((r = re.exec(quote))) out.push({ w: r[0], from: r.index, to: r.index + r[0].length });
  return out;
}

/** The word a stroke drawn at `charIndex` (inside the quote) belongs to: the one holding it, else the nearest. */
export function wordAt(surface, charIndex) {
  let best = null;
  let d = Infinity;
  for (const w of surface || []) {
    const dist = charIndex < w.from ? w.from - charIndex : charIndex >= w.to ? charIndex - w.to + 1 : 0;
    if (dist < d) { d = dist; best = w; }
  }
  return best;
}

// ---- seeds -------------------------------------------------------------------------------------------------

function validSeed(seed) {
  return !!seed && typeof seed.device === 'string' && !!seed.device && typeof seed.input === 'string' && !!seed.input &&
    typeof seed.time === 'number' && Number.isFinite(seed.time);
}
const seedOf = s => ({ device: s.device, input: s.input, time: s.time });

function addPassage(m, id, born, seed, forms) {
  if (!validSeed(seed)) throw new Error('a passage needs its seed: device, input, time');
  const out = createMatter(m);
  if (out.side.passages[id]) throw new Error(`passage ${id} exists`);
  const from = { cross: 0, ...seedOf(seed) };
  for (const f of Object.values(forms)) f.from = from;
  out.side.passages[id] = { id, born, seed: seedOf(seed), phase: born, forms };
  return out;
}

export function seedInkPassage(m, { id, strokeIds, seed }) {
  const have = new Set(m.ink.strokes.map(s => s.id));
  if (!strokeIds || !strokeIds.length || !strokeIds.every(i => have.has(i))) throw new Error('no ink: strokes not on the page');
  return addPassage(m, id, 'ink', seed, { ink: { strokes: [...strokeIds] } });
}

export function seedTypePassage(m, { id, quote, seed }) {
  const off = m.text.indexOf(quote);
  if (!quote || off === -1) throw new Error('no type: the words are not on the page');
  return addPassage(m, id, 'type', seed, { type: makeQuote(m.text, off, quote.length) });
}

export function seedVoicePassage(m, { id, spoken, seed }) {
  if (!spoken || !spoken.words || !spoken.words.length) throw new Error('no voice: nothing spoken');
  return addPassage(m, id, 'voice', seed, { voice: { spoken: [clone(spoken)] } });
}

// ---- the crossings -----------------------------------------------------------------------------------------

function need(p, state) {
  const f = p.forms[state];
  const ok = state === 'ink' ? f && (f.strokes || []).length : !!f;
  if (!ok) throw new Error(`no ${state}: passage ${p.id} holds no ${state} form for this crossing`);
  return f;
}

function typeOffset(m, p) {
  const off = findQuote(m.text, p.forms.type);
  if (off === -1) throw new Error(`no type: passage ${p.id} is not found in the body`);
  return off;
}

function insertLineAfter(m, off, words) {
  const at = lineEnd(m.text, off);
  const ins = eolOf(m.text) + words;
  m.text = m.text.slice(0, at) + ins + m.text.slice(at);
  return makeQuote(m.text, at + ins.length - words.length, words.length);
}

function ensureVoice(p, from) {
  if (!p.forms.voice) p.forms.voice = { spoken: [], from };
  if (!p.forms.voice.spoken) p.forms.voice.spoken = [];
  return p.forms.voice;
}
function ensureInk(p, from) {
  if (!p.forms.ink) p.forms.ink = { strokes: [], from };
  if (!p.forms.ink.strokes) p.forms.ink.strokes = [];
  return p.forms.ink;
}
function ensureMark(p, from, kind, anchor) {
  if (!p.forms.mark) p.forms.mark = { kind, anchor: clone(anchor) || null, from };
  return p.forms.mark;
}

function addSpoken(voice, spoken, from) {
  const e = { ...clone(spoken), from };
  const k = spokenKey(e);
  const have = voice.spoken.find(x => spokenKey(x) === k);
  if (have) return have;
  voice.spoken.push(e);
  return e;
}

function lastSpoken(p) {
  const v = p.forms.voice;
  return v && v.spoken && v.spoken.length ? v.spoken[v.spoken.length - 1] : null;
}

function readPlan(source, text, from) {
  return { from: source, text, lang: guessLang(text), words: estimateWordTimes(text), by: from };
}

const STEPS = {
  // 1 ink → type: the handwriting's reading enters the body, on the line under the ink, on its page.
  1(m, p, o, from) {
    const strokes = strokesOf(m, p);
    need(p, 'ink');
    const text = (o.text || inkReading(strokes)).trim();
    if (!text) throw new Error('the handwriting has not been read yet (no OCR text on its strokes)');
    if (p.forms.type && findQuote(m.text, p.forms.type) !== -1) return; // already typed: link, never twice
    const a = inkAnchor(m, strokes);
    const off = offsetOfPageLine(m.text, a.pageIndex || 0, a.offsetInPage || 0);
    p.forms.type = { ...insertLineAfter(m, off, text), from };
  },
  // 2 type → ink: the typed passage becomes a surface whose words strokes anchor to.
  2(m, p, o, from) {
    const t = need(p, 'type');
    typeOffset(m, p);
    ensureInk(p, from).surface = wordSurface(t.quote);
  },
  // 3 type → mark: a highlight over the words, anchored to the words (not offsets).
  3(m, p, o, from) {
    const t = need(p, 'type');
    typeOffset(m, p);
    const anchor = { quote: t.quote, prefix: t.prefix, suffix: t.suffix };
    const mk = ensureMark(p, from, o.kind || 'highlight', anchor);
    if (!mk.anchor) mk.anchor = anchor;
    mk.highlight = true;
  },
  // 4 mark → type: a highlight collapses to a quoted block; a margin note settles inline under it.
  4(m, p, o, from) {
    const mk = need(p, 'mark');
    const eol = eolOf(m.text);
    if (p.forms.type && findQuote(m.text, p.forms.type) !== -1) {
      const off = typeOffset(m, p);
      const s = lineStart(m.text, off);
      const e = lineEnd(m.text, off + p.forms.type.quote.length);
      let block = m.text.slice(s, e).split(/\r?\n/).map(l => (l.startsWith('> ') ? l : `> ${l}`)).join(eol);
      if (mk.note) block += `${eol}> ${mk.note}`;
      m.text = m.text.slice(0, s) + block + m.text.slice(e);
      const q = p.forms.type.quote;
      const at = m.text.indexOf(q, s);
      p.forms.type = { ...makeQuote(m.text, at, q.length), from: p.forms.type.from, block: 'quote' };
    } else if (mk.note) {
      const off = pageTailOffset(m.text, o.pageIndex || 0);
      const q = insertLineAfter(m, off, `> ${mk.note}`);
      p.forms.type = { ...makeQuote(m.text, findQuote(m.text, q) + 2, mk.note.length), from, block: 'quote' };
    } else {
      throw new Error('no type: nothing to condense (no words and no note)');
    }
  },
  // 5 ink → mark: a circled region becomes a region-anchored comment; recognition skipped.
  5(m, p, o, from) {
    need(p, 'ink');
    const strokes = strokesOf(m, p);
    const region = bbox(strokes);
    const anchor = inkAnchor(m, strokes);
    const mk = ensureMark(p, from, 'region', anchor);
    mk.region = region;
    mk.regionAnchor = anchor;
  },
  // 6 mark → ink: the comment sets down as a hand-placed stroke in the margin beside the passage.
  6(m, p, o, from) {
    const mk = need(p, 'mark');
    let place;
    if (p.forms.type && findQuote(m.text, p.forms.type) !== -1) place = placeOf(m.text, typeOffset(m, p));
    else if (mk.regionAnchor || (mk.anchor && typeof mk.anchor.pageIndex === 'number')) {
      const a = mk.regionAnchor || mk.anchor;
      place = { pageIndex: a.pageIndex, line: a.offsetInPage || 0 };
    } else place = { pageIndex: 0, line: 0 };
    const y = place.line * DEFAULT_LINE_HEIGHT;
    const stroke = {
      id: `dep-${p.id}-${from.time}`,
      tool: 'pen',
      color: o.color || '#a78bfa',
      width: 2,
      points: [[4, y + 4, 0.5], [0, y + 4, 0.5], [0, y + DEFAULT_LINE_HEIGHT - 4, 0.5], [4, y + DEFAULT_LINE_HEIGHT - 4, 0.5]],
      deposit: p.id
    };
    if (mk.note) stroke.ocr = { g: stroke.id, t: mk.note };
    stroke.anchor = anchorStrokeToDoc({ points: stroke.points }, m.text, DEFAULT_LINE_HEIGHT, place.pageIndex);
    if (m.ink.strokes.some(s => s.id === stroke.id)) throw new Error('that comment is already set down');
    m.ink.strokes.push(stroke);
    ensureInk(p, from).strokes.push(stroke.id);
  },
  // 7 mark → voice: the marked passage, planned for read-aloud.
  7(m, p, o, from) {
    const mk = need(p, 'mark');
    let text = '';
    if (mk.anchor && mk.anchor.quote && findQuote(m.text, mk.anchor) !== -1) text = mk.anchor.quote;
    else if (mk.note) text = mk.note;
    else text = inkReading(strokesOf(m, p));
    if (!text) throw new Error('no words to read aloud in this mark');
    ensureVoice(p, from).read = readPlan('mark', text, from);
  },
  // 8 voice → mark: a spoken aside lands as a timestamped margin note, not body text.
  8(m, p, o, from) {
    const v = o.spoken ? ensureVoice(p, from) : need(p, 'voice');
    const e = o.spoken ? addSpoken(v, o.spoken, from) : lastSpoken(p);
    if (!e) throw new Error('no voice: nothing spoken to set as a note');
    const anchor = p.forms.type ? { quote: p.forms.type.quote, prefix: p.forms.type.prefix, suffix: p.forms.type.suffix } : null;
    const mk = ensureMark(p, from, 'note', anchor);
    mk.note = spokenText(e);
    mk.noteAt = o.at ?? e.at ?? 0;
    if (e.audio) mk.noteAudio = e.audio;
  },
  // 9 type → voice: the typed passage read aloud, in its language.
  9(m, p, o, from) {
    const t = need(p, 'type');
    typeOffset(m, p);
    ensureVoice(p, from).read = readPlan('type', t.quote, from);
  },
  // 10 voice → type: speech becomes text once; its words keep their times and point into the body.
  10(m, p, o, from) {
    const v = o.spoken ? ensureVoice(p, from) : need(p, 'voice');
    if (o.spoken) addSpoken(v, o.spoken, from);
    const waiting = v.spoken.filter(e => !e.typed || findQuote(m.text, e.typed) === -1);
    if (!waiting.length && !v.spoken.length) throw new Error('no voice: nothing spoken to type');
    for (const e of waiting) {
      const words = spokenText(e);
      const off = p.forms.type && findQuote(m.text, p.forms.type) !== -1
        ? typeOffset(m, p) + p.forms.type.quote.length
        : pageTailOffset(m.text, o.pageIndex || 0);
      e.typed = insertLineAfter(m, off, words);
      if (!p.forms.type) p.forms.type = { ...e.typed, from };
    }
  },
  // 11 ink → voice: handwriting read aloud from its reading, the typed state skipped.
  11(m, p, o, from) {
    need(p, 'ink');
    const text = inkReading(strokesOf(m, p));
    if (!text) throw new Error('the handwriting has not been read yet (no OCR text on its strokes)');
    ensureVoice(p, from).read = readPlan('ink', text, from);
  },
  // 12 voice → ink: a spoken phrase pinned to a place on the page, not a moment in a timeline.
  12(m, p, o, from) {
    const v = need(p, 'voice');
    const e = lastSpoken(p);
    const phrase = e ? { audio: e.audio || null, text: spokenText(e) } : v.read ? { audio: null, text: v.read.text } : null;
    if (!phrase) throw new Error('no voice: nothing spoken to pin');
    let anchor;
    if (o.place) {
      anchor = anchorStrokeToDoc({ points: [[o.place.x || 0, o.place.y || 0]] }, m.text, DEFAULT_LINE_HEIGHT, o.place.pageIndex || 0);
    } else if (strokesOf(m, p).length) {
      anchor = inkAnchor(m, strokesOf(m, p));
    } else {
      const pl = p.forms.type && findQuote(m.text, p.forms.type) !== -1 ? placeOf(m.text, typeOffset(m, p)) : { pageIndex: 0, line: 0 };
      anchor = anchorStrokeToDoc({ points: [[0, pl.line * DEFAULT_LINE_HEIGHT + 4]] }, m.text, DEFAULT_LINE_HEIGHT, pl.pageIndex);
    }
    const ink = ensureInk(p, from);
    if (!ink.pins) ink.pins = [];
    ink.pins.push({ ...phrase, anchor, from });
  }
};

function textPatch(before, after) {
  let a = 0;
  const max = Math.min(before.length, after.length);
  while (a < max && before[a] === after[a]) a++;
  let b = 0;
  while (b < max - a && before[before.length - 1 - b] === after[after.length - 1 - b]) b++;
  return { at: a, del: after.slice(a, after.length - b), ins: before.slice(a, before.length - b) };
}

/**
 * Carries passage `pid` across crossing `n`. `opts.seed` = { device, input, time } of this move (required).
 * Other opts by crossing: 1 text (else the strokes' reading); 4 pageIndex; 6 color; 8 spoken {audio, words}, at;
 * 10 spoken, pageIndex; 12 place {pageIndex, x, y}. Returns new matter; the input is not changed.
 */
export function cross(m, n, pid, opts = {}) {
  const c = CROSSINGS.find(x => x.n === n);
  if (!c) throw new Error(`unknown crossing ${n}`);
  if (!m.side.passages[pid]) throw new Error(`no passage ${pid}`);
  if (!validSeed(opts.seed)) throw new Error('a crossing needs its seed: device, input, time');
  const out = createMatter(m);
  const p = out.side.passages[pid];
  const priorPassage = clone(p);
  const priorStrokes = new Map(out.ink.strokes.map(s => [s.id, JSON.stringify(s)]));
  const from = { cross: n, ...seedOf(opts.seed) };
  STEPS[n](out, p, opts, from);
  for (const s of STATES) {
    if (p.forms[s] && JSON.stringify(p.forms[s]) !== JSON.stringify(priorPassage.forms[s])) p.forms[s].touched = from.time;
  }
  p.phase = c.to;
  const changed = [];
  const added = [];
  for (const s of out.ink.strokes) {
    if (!priorStrokes.has(s.id)) added.push(s.id);
    else if (priorStrokes.get(s.id) !== JSON.stringify(s)) changed.push(JSON.parse(priorStrokes.get(s.id)));
  }
  out.side.log.push({
    id: `${pid}:${n}:${from.time}:${from.device}`,
    cross: n,
    pid,
    state: c.to,
    seed: seedOf(opts.seed),
    undo: { text: textPatch(m.text, out.text), passage: priorPassage, strokes: { changed, added } }
  });
  return out;
}

/** Undoes the last crossing exactly. Refuses if the body moved under it in a way it cannot place. */
export function reverseLast(m) {
  if (!m.side.log.length) throw new Error('nothing to reverse');
  const out = createMatter(m);
  const e = out.side.log.pop();
  const { text, passage, strokes } = e.undo;
  let at = text.at;
  if (out.text.slice(at, at + text.del.length) !== text.del) {
    at = out.text.indexOf(text.del);
    if (at === -1 || out.text.indexOf(text.del, at + 1) !== -1) throw new Error('the page changed under this crossing; cannot reverse it safely');
  }
  out.text = out.text.slice(0, at) + text.ins + out.text.slice(at + text.del.length);
  out.side.passages[e.pid] = clone(passage);
  const addedSet = new Set(strokes.added);
  const prior = new Map(strokes.changed.map(s => [s.id, s]));
  out.ink.strokes = out.ink.strokes.filter(s => !addedSet.has(s.id)).map(s => (prior.has(s.id) ? clone(prior.get(s.id)) : s));
  return out;
}

/** The passage's path from its seed: [{cross: 0, state, device, input, time}, …one per crossing]. */
export function traceToSeed(m, pid) {
  const p = m.side.passages[pid];
  if (!p) return [];
  return [
    { cross: 0, state: p.born, ...p.seed },
    ...m.side.log.filter(e => e.pid === pid).map(e => ({ cross: e.cross, state: e.state, ...e.seed }))
  ];
}

// ---- the done check ----------------------------------------------------------------------------------------

function wordCounts(text) {
  const c = new Map();
  for (const w of wordsOf(text)) c.set(w, (c.get(w) || 0) + 1);
  return c;
}

/**
 * FEAT-08's pass conditions on `m`, against the matter just before (`before`) and at the start (`origin`):
 * same page, nothing lost, nothing duplicated, every passage and form traced to a seed. Returns { problems }.
 */
export function checkMatter(m, { before = null, origin = null } = {}) {
  const problems = [];
  const pagesOf = t => t.split(/\r?\n/).filter(l => l.trim() === PAGE_MARKER).length;
  for (const ref of [before, origin].filter(Boolean)) {
    if (pagesOf(ref.text) !== pagesOf(m.text)) problems.push('the page count changed');
    const now = wordCounts(m.text);
    for (const [w, k] of wordCounts(ref.text)) if ((now.get(w) || 0) < k) problems.push(`word lost: ${w}`);
    const strokes = new Map(m.ink.strokes.map(s => [s.id, s]));
    for (const s of ref.ink.strokes) {
      const n = strokes.get(s.id);
      if (!n) problems.push(`stroke lost: ${s.id}`);
      else if (JSON.stringify(n.points) !== JSON.stringify(s.points)) problems.push(`stroke changed: ${s.id}`);
    }
    for (const [id, rp] of Object.entries(ref.side.passages)) {
      const p = m.side.passages[id];
      if (!p) { problems.push(`passage lost: ${id}`); continue; }
      const keys = new Set(((p.forms.voice && p.forms.voice.spoken) || []).map(spokenKey));
      for (const e of (rp.forms.voice && rp.forms.voice.spoken) || []) if (!keys.has(spokenKey(e))) problems.push(`audio lost: ${e.audio}`);
      for (const s of STATES) if (rp.forms[s] && !p.forms[s]) problems.push(`form lost: ${id}.${s}`);
    }
  }
  const ids = m.ink.strokes.map(s => s.id);
  if (new Set(ids).size !== ids.length) problems.push('a stroke is duplicated');
  const strokeIds = new Set(ids);
  for (const [id, p] of Object.entries(m.side.passages)) {
    if (!validSeed(p.seed) || !STATES.includes(p.born)) problems.push(`passage ${id} has no seed`);
    for (const s of STATES) {
      const f = p.forms[s];
      if (!f) continue;
      if (!f.from || typeof f.from.cross !== 'number' || !validSeed(f.from)) problems.push(`${id}.${s} is not traced to a seed`);
    }
    if (p.forms.type && findQuote(m.text, p.forms.type) === -1) problems.push(`${id}: its words are not in the body`);
    for (const sid of (p.forms.ink && p.forms.ink.strokes) || []) if (!strokeIds.has(sid)) problems.push(`${id}: stroke ${sid} missing`);
    const spoken = (p.forms.voice && p.forms.voice.spoken) || [];
    const keys = spoken.map(spokenKey);
    if (new Set(keys).size !== keys.length) problems.push(`${id}: audio duplicated`);
    if (before) {
      const bp = before.side.passages[id];
      const quotes = [p.forms.type && p.forms.type.quote, ...spoken.map(e => e.typed && e.typed.quote)].filter(Boolean);
      for (const q of new Set(quotes)) {
        const was = count(before.text, q);
        const typedBefore = !!bp && [bp.forms.type && bp.forms.type.quote, ...(((bp.forms.voice && bp.forms.voice.spoken) || []).map(e => e.typed && e.typed.quote))].includes(q);
        if (count(m.text, q) > was + (typedBefore ? 0 : 1)) problems.push(`${id}: "${q}" duplicated in the body`);
      }
    }
  }
  return { problems };
}

// ---- two devices -------------------------------------------------------------------------------------------

const touchedOf = f => (f && (f.touched ?? (f.from && f.from.time))) || 0;

function mergeForm(state, a, b) {
  if (!a) return clone(b);
  if (!b) return clone(a);
  const later = touchedOf(b) > touchedOf(a) ? b : a;
  const out = clone(later);
  if (state === 'voice') {
    const seen = new Map();
    for (const e of [...(a.spoken || []), ...(b.spoken || [])]) if (!seen.has(spokenKey(e))) seen.set(spokenKey(e), clone(e));
    out.spoken = [...seen.values()];
  }
  if (state === 'ink') {
    out.strokes = [...new Set([...(a.strokes || []), ...(b.strokes || [])])];
    const pins = new Map();
    for (const pin of [...(a.pins || []), ...(b.pins || [])]) pins.set(JSON.stringify(pin), clone(pin));
    if (pins.size) out.pins = [...pins.values()];
  }
  return out;
}

/** Unions two devices' sidecars: every passage, form, stroke id and second of audio kept; the latest move sets the phase. */
export function mergeMatter(a, b) {
  const A = a || emptySide();
  const B = b || emptySide();
  const log = new Map();
  for (const e of [...(A.log || []), ...(B.log || [])]) if (!log.has(e.id)) log.set(e.id, clone(e));
  const entries = [...log.values()].sort((x, y) => x.seed.time - y.seed.time || (x.id < y.id ? -1 : x.id > y.id ? 1 : 0));
  const passages = {};
  for (const id of [...new Set([...Object.keys(A.passages || {}), ...Object.keys(B.passages || {})])].sort()) {
    const pa = A.passages && A.passages[id];
    const pb = B.passages && B.passages[id];
    if (!pa || !pb) { passages[id] = clone(pa || pb); continue; }
    const p = clone(pa);
    p.forms = {};
    for (const s of STATES) {
      const f = mergeForm(s, pa.forms[s], pb.forms[s]);
      if (f) p.forms[s] = f;
    }
    const last = entries.filter(e => e.pid === id).pop();
    p.phase = last ? last.state : pa.phase;
    passages[id] = p;
  }
  return { version: 1, passages, log: entries };
}
