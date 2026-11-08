// The lenses' rules that need no model (brief: "Check each lens line"; "No model: extractive only, honestly labelled").
// · checkLines: every lens line must be found in what it cites. Its key terms are looked for in its source sentences;
//   a line whose terms aren't there is dropped, never shown. A line that cites nothing is labelled "added", unless its
//   terms are all found in the section's sentences, which then become its sources.
// · extractive: the stand-in when the on-device model can't run (Apple Intelligence off, an unsupported language):
//   Gist = the most central sentence of each paragraph (ranked by key terms shared with the rest), the chapter title
//   from the commonest terms, Reformat by pattern (timeline, definitions, outline). Labelled "extract" on screen.
// · reformatKind: which structure the section already has (IRAC for law, timeline for dates, definitions, outline).

const STOP = new Set((
  'the a an and or but if of to in on at by for with from as is are was were be been being it its this that these those ' +
  'there their they them he she his her we our you your i me my not no so than then also which who whom whose what when ' +
  'where how why all any each into over under about after before between because while would could should shall must may ' +
  'can will has have had do does did very more most such only own same other some just here out up down off again ' +
  'là và của các những một cho với trong được không có này đó khi thì để từ theo như người cũng đã sẽ đang ra vào ' +
  'le la les un une des et ou de du en au aux est sont pour par avec dans sur que qui ne pas ce cette ces il elle ils'
).split(/\s+/));

/** The words that carry a line's meaning: letters or digits, not stop words, case and accents kept apart from case. */
export function keyTerms(text) {
  const out = [];
  for (const m of String(text ?? '').toLowerCase().matchAll(/[\p{L}\p{N}][\p{L}\p{N}'’-]*/gu)) {
    const w = m[0].replace(/['’]s$/, '');
    if (STOP.has(w)) continue;
    if (/^\p{N}+$/u.test(w) || w.length >= 3 || /[^\x00-\x7f]/.test(w)) out.push(w);
  }
  return out;
}

const stem = w => (w.length > 5 ? w.slice(0, 5) : w);

/** How much of a line's terms its sources hold (0–1); a term matches on its first five letters (offer ~ offered). */
export function coverage(text, sourceTexts) {
  const terms = [...new Set(keyTerms(text))];
  if (!terms.length) return 1;
  const have = new Set(sourceTexts.flatMap(keyTerms).map(stem));
  return terms.filter(t => have.has(stem(t))).length / terms.length;
}

export const MIN_COVERAGE = 0.6;

// Letters only Vietnamese uses (not French): a line meant to be English that holds two words with them is mixed.
const VI_ONLY = /[ạảấầẩẫậăắằẳẵặẹẻẽếềểễệỉịĩọỏốồổỗộơớờởỡợụủũưứừửữựỳỵỷỹđõã]/iu;
const EN_GLUE = new Set('the of and is are was were which that with this from for'.split(' '));

/** A line in two languages (the one-language rule): flagged by the app (`mixed`), or caught here as a backup. */
export function isMixed(line) {
  if (line?.mixed) return true;
  const words = String(line?.text ?? '').toLowerCase().match(/[\p{L}]+/gu) || [];
  if (line?.lang === 'en') return words.filter(w => VI_ONLY.test(w)).length >= 2;
  if (line?.lang === 'vi') return words.filter(w => EN_GLUE.has(w)).length >= 2;
  return false;
}

/**
 * The citation check. `lines`: [{text, from:[keys], role?, lang?, mixed?}]; `sentences`: the section's [{key, text}];
 * `alt`: {key: that sentence in the line's language}, so a line in English about a Vietnamese sentence is checked
 * against its translation too. Returns the lines that pass, each with `from` (only keys that exist) or `added: true`;
 * the dropped ones apart (not in what they cite, or in two languages).
 */
export function checkLines(lines, sentences, alt = {}) {
  const pool = sentences.map(s => ({ key: s.key, text: alt[s.key] ? `${s.text} ${alt[s.key]}` : s.text }));
  const byKey = new Map(pool.map(s => [s.key, s.text]));
  const kept = [], dropped = [];
  for (const l of lines || []) {
    const text = String(l?.text ?? '').replace(/\s*[;,]?\s*\[s\d+(\s*,\s*s\d+)*\]/g, '').trim();   // ids belong in `from`
    if (!text) continue;
    if (isMixed({ ...l, text })) { dropped.push({ ...l, text, why: 'two languages in one line' }); continue; }
    const from = (l.from || []).filter(k => byKey.has(k));
    if (from.length) {
      if (coverage(text, from.map(k => byKey.get(k))) >= MIN_COVERAGE) kept.push({ ...l, text, from });
      else {
        const repaired = repair(text, pool);
        if (repaired) kept.push({ ...l, text, from: repaired });
        else if (/\?\s*$/.test(text)) kept.push({ ...l, text, from: [], added: true });   // a question claims nothing
        else dropped.push({ ...l, text, why: 'its words are not in the sentences it cites' });
      }
      continue;
    }
    const repaired = repair(text, pool);
    kept.push(repaired ? { ...l, text, from: repaired } : { ...l, text, from: [], added: true });
  }
  return { kept, dropped };
}

/** The fewest sentences that hold a line's terms (greedy), when together they hold enough of them; else null. */
function repair(text, sentences) {
  const terms = [...new Set(keyTerms(text).map(stem))];
  if (!terms.length) return null;
  const sets = sentences.map(s => ({ key: s.key, have: new Set(keyTerms(s.text).map(stem)) }));
  const missing = new Set(terms), pick = [];
  while (missing.size && pick.length < 4) {
    let best = null, gain = 0;
    for (const s of sets) {
      const g = [...missing].filter(t => s.have.has(t)).length;
      if (g > gain) { best = s; gain = g; }
    }
    if (!best) break;
    pick.push(best.key);
    for (const t of [...missing]) if (best.have.has(t)) missing.delete(t);
  }
  return (terms.length - missing.size) / terms.length >= MIN_COVERAGE ? pick : null;
}

// ── Reformat by what the section already holds ──────────────────────────────────────────────────────────────────────
const LAW_RE = /\b(v\.?|vs\.?|held|court|statute|article|art\.|section|rule|plaintiff|defendant|liable|tort|contract|clause|điều|khoản|luật|bộ luật|toà|tòa|arrêt|cour|loi|alinéa)\b|§/iu;
const DATE_RE = /\b(1[5-9]\d\d|20\d\d)\b|\b\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4}\b|\b(january|february|march|april|may|june|july|august|september|october|november|december|tháng\s+\d{1,2}|janvier|février|mars|avril|mai|juin|juillet|août|septembre|octobre|novembre|décembre)\b/iu;
const DEF_RE = /^(.{2,60}?)\s+(means|is defined as|refers to|is called|nghĩa là|là việc|được hiểu là|désigne|s'entend de)\s+(.+)$/iu;

export function reformatKind(sentences) {
  const texts = sentences.map(s => s.text);
  if (texts.filter(t => DEF_RE.test(t)).length >= 2) return 'definitions';
  if (texts.filter(t => DATE_RE.test(t)).length >= 2 && texts.filter(t => DATE_RE.test(t)).length >= texts.length / 2) return 'timeline';
  if (texts.some(t => LAW_RE.test(t))) return 'irac';
  return 'outline';
}

/** Reformat by pattern: a timeline, a definitions list, or an outline (each line cites the sentence it comes from). */
export function patternReformat(sentences, kind = reformatKind(sentences)) {
  if (kind === 'timeline') {
    return { kind, lines: sentences.filter(s => DATE_RE.test(s.text))
      .map(s => ({ text: `${s.text.match(DATE_RE)[0]} · ${s.text.replace(/[.;]\s*$/, '')}`, from: [s.key], role: 'when' })) };
  }
  if (kind === 'definitions') {
    return { kind, lines: sentences.map(s => [s, DEF_RE.exec(s.text)]).filter(([, m]) => m)
      .map(([s, m]) => ({ text: `${m[1].trim()}: ${m[3].replace(/[.;]\s*$/, '')}`, from: [s.key], role: 'term' })) };
  }
  // An outline: the opening sentence of each paragraph.
  const firsts = new Map();
  for (const s of sentences) if (!firsts.has(s.p)) firsts.set(s.p, s);
  return { kind: 'outline', lines: [...firsts.values()].map(s => ({ text: s.text, from: [s.key], role: 'point' })) };
}

// ── The extractive engine ──────────────────────────────────────────────────────────────────────────────────────────
function centrality(sentences) {
  const terms = sentences.map(s => new Set(keyTerms(s.text).map(stem)));
  const df = new Map();
  for (const set of terms) for (const t of set) df.set(t, (df.get(t) || 0) + 1);
  return sentences.map((s, i) => {
    let score = 0;
    for (const t of terms[i]) score += (df.get(t) || 1) - 1;   // terms shared with the rest of the section
    return score / Math.sqrt(terms[i].size || 1) + (i === 0 ? 0.5 : 0);
  });
}

/** Lenses without a model, from the section's own sentences. Every line is a sentence the owner wrote, cited. */
export function extractive(section, why = '') {
  const ss = section.sentences;
  const score = centrality(ss);
  const best = new Map();
  ss.forEach((s, i) => { if (!best.has(s.p) || score[i] > best.get(s.p).score) best.set(s.p, { s, score: score[i] }); });
  const gist = [...best.values()].map(({ s }) => ({ text: s.text, from: [s.key], para: s.p }));
  // The page gist: the most central sentences, those not already a paragraph line first, in the order written.
  const used = new Set(gist.map(l => l.from[0]));
  const ranked = ss.map((s, i) => [s, score[i]]).sort((a, b) => b[1] - a[1]).map(([s]) => s);
  const pageN = Math.min(PAGE_LINES, ss.length);
  const page = [...ranked.filter(s => !used.has(s.key)), ...ranked.filter(s => used.has(s.key))].slice(0, pageN)
    .sort((a, b) => a.from - b.from).map(s => ({ text: s.text, from: [s.key] }));
  const freq = new Map(), cased = new Map();
  for (const s of ss) {
    for (const m of s.text.matchAll(/[\p{L}\p{N}][\p{L}\p{N}'’-]*/gu)) if (!cased.has(m[0].toLowerCase())) cased.set(m[0].toLowerCase(), m[0]);
    for (const t of keyTerms(s.text)) if (t.length > 3 && !/^\p{N}+$/u.test(t)) freq.set(t, (freq.get(t) || 0) + 1);
  }
  const words = [...freq].sort((a, b) => b[1] - a[1]).slice(0, 3).map(([t]) => cased.get(t) || t);
  const title = words.length ? words.map((w, i) => (i ? w : w[0].toUpperCase() + w.slice(1))).join(' · ') : 'Untitled';
  const kind = reformatKind(ss);
  return {
    key: section.key, engine: 'extract', why, title,
    page,
    gist,
    // No model: IRAC can't be written from patterns, so law sections show their outline instead.
    reformat: patternReformat(ss, kind === 'irac' ? 'outline' : kind)
  };
}

export const PAGE_LINES = 3;
const normText = t => String(t).toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();

/** A result's page gist (older cached results kept one `whole` line). */
export const pageGist = r => r?.page || (r?.whole ? [r.whole] : []);

/**
 * One section's result as the layer shows it, enforced here whatever the model wrote:
 * · Gist: exactly one line per paragraph. A paragraph whose model line is missing, uncited, mixed or not in its
 *   sources gets its most central sentence instead, marked `extract`.
 * · the page gist: up to three lines (fewer only when the section has fewer sentences), filled the same way.
 * · Reformat by pattern where the model wrote none.
 * Extractive lines are the owner's own sentences, so they pass by construction.
 */
export function settle(section, result) {
  const ss = section.sentences;
  const ext = extractive(section, result?.why || '');
  const model = result && result.engine === 'model';
  const r = model ? result : ext;
  const alt = r.sourceIn || {};
  const pOf = new Map(ss.map(s => [s.key, s.p]));
  const fill = l => (model ? { ...l, extract: true } : l);

  const g = checkLines(r.gist, ss, alt);
  const cited = g.kept.filter(l => l.from.length);
  const extBy = new Map(ext.gist.map(l => [l.para, l]));
  const gist = [...new Set(ss.map(s => s.p))].map(p =>
    cited.find(l => l.para === p) ||
    cited.find(l => l.para == null && l.from.every(k => pOf.get(k) === p)) ||
    fill(extBy.get(p)));

  const pageN = Math.min(PAGE_LINES, ss.length);
  const pg = checkLines(pageGist(r), ss, alt);
  // A page line that repeats a paragraph line adds nothing: it goes (counted as dropped), and the gap is filled.
  const same = new Set(gist.map(l => normText(l.text)));
  const repeats = pg.kept.filter(l => same.has(normText(l.text)));
  const page = pg.kept.filter(l => l.from.length && !same.has(normText(l.text))).slice(0, pageN);
  for (const l of ext.page) {
    if (page.length >= pageN) break;
    if (!page.some(x => x.from[0] === l.from[0])) page.push(fill(l));
  }

  let reformat = r.reformat;
  if (!reformat || !reformat.lines?.length) {
    const kind = reformatKind(ss);
    reformat = patternReformat(ss, kind === 'irac' ? 'outline' : kind);
  }
  const ref = checkLines(reformat.lines, ss, alt);
  return {
    key: section.key, engine: r.engine, why: r.why || '', title: String(r.title || '').trim() || ext.title, lang: r.lang || '',
    page, whole: page[0] || null,
    gist,
    reformat: { kind: reformat.kind, lines: ref.kept },
    dropped: g.dropped.length + pg.dropped.length + repeats.length + ref.dropped.length,
    // What was dropped and why, so a check (and a curious reader) can see it; never shown as a lens line.
    droppedLines: [...g.dropped, ...pg.dropped, ...repeats.map(l => ({ ...l, why: 'repeats a paragraph line' })), ...ref.dropped]
      .map(l => ({ text: l.text, why: l.why })),
    at: Date.now()
  };
}
