// Where Recense's transcripts live in its bucket (binding KEEP, recense-tmp), one folder per media:
//
//   keep/<key>/asr.json            the original transcript only: { format: 1, complete, duration,
//                                  segments: [{ id, start, end, text, lang?, words: [{ text, start, end, lang? }] }],
//                                  recense: { ...what Recense keeps to pick the work up again } }
//   keep/<key>/tr/<lang>.json      a translation (en, vi, fr), each written on its own: { lang, complete, updatedAt,
//                                  lines: { <segment id>: { src, text, words?: [{ w, s: [i] }], draft?, same? } } }
//                                  src = the segment's words it was made from (a line remade since is not shown it);
//                                  words = the translation word by word with the original words (by index) it
//                                  translates; same = the line is already in that language; draft = made on the Mac
//                                  while every model was out (a model redoes it).
//   keep/<key>/corrections.json    what listeners fixed (corrections.js), Recense's own edits beside them
//   keep/<key>/history/<v>.json    the last 20 versions of corrections.json
//   keep/<key>/changes.json        every correction made in Gallery, with the words it replaced (the last 1000)
//   keep/locks/<own key>           a viewer asked for a transcript (transcript.js); kept in one folder because
//                                  Recense lists it every minute
//   keep/library.json              aliases
//
// Before this, a transcript was keep/<key>.v2.json (lines with their English inside) and its corrections
// keep/<key>.edits.json, with keep/history/<key>/. Those are still read; the first read of one writes the new layout
// beside it (never over a file already there) and leaves the old file where it is.

export const LANGS = ["en", "vi", "fr"];

export const asrName = (k) => "keep/" + k + "/asr.json";
export const trName = (k, lang) => "keep/" + k + "/tr/" + lang + ".json";
export const corrName = (k) => "keep/" + k + "/corrections.json";
export const changesName = (k) => "keep/" + k + "/changes.json";
export const histName = (k, v) => "keep/" + k + "/history/" + v + ".json";
export const oldTranscriptName = (k) => "keep/" + k + ".v2.json";
export const oldCorrName = (k) => "keep/" + k + ".edits.json";

const wordsOf = (l) => (Array.isArray(l && l.words) ? l.words : []);
export const srcOf = (words) => words.filter((w) => w && typeof w.text === "string").map((w) => w.text).join(" ");

// the language most of a line's words were heard in, when Whisper named one
function langOf(words) {
  const n = {};
  for (const w of words) if (w && typeof w.lang === "string") n[w.lang] = (n[w.lang] || 0) + 1;
  const best = Object.entries(n).sort((a, b) => b[1] - a[1])[0];
  return best ? best[0] : undefined;
}

// An old <key>.v2.json as the new layout: { asr, en } (en null when no line had its English yet).
export function split(v2, now = Date.now()) {
  const { lines, complete, duration, ...rest } = v2 && typeof v2 === "object" ? v2 : {};
  const segments = [];
  const tr = {};
  let all = true;
  let any = false;
  for (const l of Array.isArray(lines) ? lines : []) {
    if (!l || l.id == null) continue;
    const words = wordsOf(l);
    const text = srcOf(words);
    const seg = { id: l.id, start: words.length ? Number(words[0].start) : 0, end: words.length ? Number(words[words.length - 1].end) : 0, text, words };
    const lang = langOf(words);
    if (lang) seg.lang = lang;
    segments.push(seg);
    if (Array.isArray(l.english)) {
      any = true;
      const en = l.english.filter((w) => w && typeof w.w === "string");
      tr[String(l.id)] = en.length ? { src: text, text: en.map((w) => w.w).join(" "), words: en, ...(l.draft ? { draft: true } : {}) } : { src: text, same: true };
    } else all = false;
  }
  const asr = { format: 1, complete: !!complete, duration: Number(duration) || 0, segments, recense: rest };
  return { asr, en: any ? { lang: "en", complete: all, updatedAt: now, lines: tr } : null };
}

// A translation file's entry for a line, if it was made from these words (any of `texts`); null otherwise.
export function entryFor(file, id, texts) {
  const e = file && file.lines && typeof file.lines === "object" ? file.lines[String(id)] : null;
  if (!e || typeof e !== "object") return null;
  if (e.src != null && !texts.includes(e.src)) return null;
  return e;
}

// The words of an entry as aligned translation words ([] when the line is in that language already).
export function entryWords(e) {
  if (e.same) return [];
  if (Array.isArray(e.words) && e.words.length) return e.words.filter((w) => w && typeof w.w === "string");
  return String(e.text || "").trim().split(/\s+/).filter(Boolean).map((w) => ({ w, s: [] }));
}

// asr.json and its English laid together as the lines the corrections work on (corrections.js: baseLines).
export function join(asr, en) {
  const lines = [];
  for (const s of (asr && Array.isArray(asr.segments) && asr.segments) || []) {
    if (!s || s.id == null) continue;
    const words = wordsOf(s);
    const line = { id: s.id, words };
    const e = entryFor(en, s.id, [srcOf(words)]);
    if (e) line.english = entryWords(e);
    lines.push(line);
  }
  return { complete: !!(asr && asr.complete), duration: Number(asr && asr.duration) || 0, lines };
}
