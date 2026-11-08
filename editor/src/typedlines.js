// Typed text as Recense's transcript Lines (brief: .handoff/coordinator/recense-the-text-brief.md, pipeline 1 and 6).
// A page is cut into paragraphs and sentences; each sentence is keyed by a hash of its text, so editing one sentence
// changes one key and only the lens lines that cite it go stale. Sections (≤ ~1,500 words, cut at your own headings and
// at paragraph ends) are the unit Recense sends to the on-device model, and the unit of a recensed chapter.
import { inspectDraftpadPages, isMetaLine, isFullDateLine } from './pages.js';
import { parseHeadingLine } from './outline.js';

export const SECTION_WORDS = 1500;

/** FNV-1a, 32 bits, as 8 hex digits: a sentence's key. */
export function fnv1a(text) {
  let h = 0x811c9dc5;
  const s = String(text ?? '');
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h.toString(16).padStart(8, '0');
}

const norm = s => String(s).replace(/\s+/g, ' ').trim();
export const countWords = s => (norm(s).match(/[\p{L}\p{N}][\p{L}\p{N}'’.-]*/gu) || []).length;

/** Sentences in a paragraph, with their offsets in it (Intl.Segmenter when there is one; punctuation otherwise). */
export function splitSentences(text) {
  const out = [];
  const push = (seg, at) => {
    const lead = seg.length - seg.trimStart().length;
    const t = seg.trim();
    if (t && /[\p{L}\p{N}]/u.test(t)) out.push({ text: t, from: at + lead, to: at + lead + t.length });
  };
  if (typeof Intl !== 'undefined' && Intl.Segmenter) {
    for (const s of new Intl.Segmenter('und', { granularity: 'sentence' }).segment(text)) push(s.segment, s.index);
    return out;
  }
  const re = /[^.!?…]+(?:[.!?…]+["”’)]*|$)/g;
  let m;
  while ((m = re.exec(text)) && m[0]) push(m[0], m.index);
  return out;
}

/**
 * A page's sentences in order: {key, text, from, to, p (paragraph index), heading (your own heading above it, or '')}.
 * Skips the date heading, the saved line and headings themselves (they are titles, not content).
 * Repeated sentences get a #2, #3 … on their key, so each key names one place.
 */
export function pageSentences(pageText, base = 0) {
  const sentences = [];
  const seen = new Map();
  let p = -1, heading = '', inPara = false, offset = 0;
  for (const raw of pageText.split('\n')) {
    const line = raw.replace(/\r$/, '');
    const at = base + offset;
    offset += raw.length + 1;
    const t = line.trim();
    const h = parseHeadingLine(line);
    if (!t || isMetaLine(t) || isFullDateLine(t) || t.startsWith('<!--')) { inPara = false; continue; }
    if (h) { heading = h.title; inPara = false; sentences.push({ isHeading: true, title: h.title, from: at, to: at + line.length }); continue; }
    if (!inPara) { p++; inPara = true; }
    for (const s of splitSentences(line)) {
      const k = fnv1a(norm(s.text));
      const n = (seen.get(k) || 0) + 1;
      seen.set(k, n);
      sentences.push({ key: n > 1 ? `${k}#${n}` : k, text: s.text, from: at + s.from, to: at + s.to, p, heading });
    }
  }
  return sentences;
}

/**
 * A page's sections: runs of sentences cut at each of your headings and at the paragraph end after ~1,500 words.
 * {key (hash of its sentence keys), sentences, from, to, words, heading, pageIndex}.
 */
export function pageSections(pageText, { base = 0, pageIndex = 0, maxWords = SECTION_WORDS } = {}) {
  const sections = [];
  let cur = null;
  const close = () => {
    if (cur && cur.sentences.length) {
      cur.key = fnv1a(cur.sentences.map(s => s.key).join(' '));
      cur.to = cur.sentences[cur.sentences.length - 1].to;
      sections.push(cur);
    }
    cur = null;
  };
  let heading = '', headingFrom = -1;
  for (const s of pageSentences(pageText, base)) {
    if (s.isHeading) { close(); heading = s.title; headingFrom = s.from; continue; }
    if (cur && cur.words >= maxWords && s.p !== cur.lastP) close();
    if (!cur) cur = { sentences: [], from: headingFrom >= 0 && heading ? headingFrom : s.from, words: 0, heading, pageIndex, lastP: s.p };
    if (cur.sentences.length && cur.from === headingFrom) headingFrom = -1;
    cur.sentences.push(s);
    cur.words += countWords(s.text);
    cur.lastP = s.p;
  }
  close();
  for (const s of sections) delete s.lastP;
  return sections;
}

/** Every page's sections, with document offsets. */
export function docSections(text, opts = {}) {
  const out = [];
  inspectDraftpadPages(text).forEach((pg, i) => {
    out.push(...pageSections(text.slice(pg.from, pg.to), { ...opts, base: pg.from, pageIndex: i }));
  });
  return out;
}

/** A sentence as a transcript Line (shared/transcript.swift `Line`): words untimed until a voice reads it. */
export function sentenceLine(sentence, id) {
  const words = (sentence.text.match(/[^\s]+/g) || []).map(w => ({ text: w, start: 0, end: 0 }));
  return { id, words, english: null };
}

/** A lens line as a Line: its own words, and `from` naming the sentences it was made from (or added). */
export function lensLineToLine(lens, id) {
  const line = sentenceLine({ text: lens.text }, id);
  line.from = lens.from || [];
  if (lens.added) line.added = true;
  return line;
}

/**
 * After an edit: which lens lines still stand. A line stays while every sentence it cites is still on the page;
 * a line citing a changed or deleted sentence goes stale (redone at the next recense), the rest are kept as they are.
 */
export function reconcile(lines, liveKeys) {
  const live = liveKeys instanceof Set ? liveKeys : new Set(liveKeys);
  const kept = [], stale = [];
  for (const l of lines) ((l.from || []).every(k => live.has(k)) ? kept : stale).push(l);
  return { kept, stale };
}
