// The Recense layer: what you typed, recensed (brief: .handoff/coordinator/recense-the-text-brief.md, M1).
// Off by default. When on, one lens at a time shows under your text, dimmed, never in the file:
//   · Gist: the chapter's title and one-line gist at its start, a line per paragraph after it;
//   · Reformat: the structure the section already has (IRAC for law, a timeline, definitions, an outline);
//   · Source: each sentence's translation (English → Vietnamese, anything else → English, or the page's pick).
// Every line cites the sentences it came from (tap it: they light) or says "added"; a line that fails the check is
// never shown (lenses.js). Without the on-device model the lenses are extractive and say so ("extract").
// When it runs: a section quiet for 60 s, on power or battery above 30 %, or "Recense now" (menu, voice). Never per
// keystroke. Results are cached by section (a hash of its sentences); a saved page's go to Recensed/<id>.json.
// Host messages (webkit.messageHandlers.ui), answered by shared/recensetext.swift:
//   → {recenseSections:{id, sections}}  ← setRecenseSection(id, json) … recenseDone(id)
//   → {recenseSource:{id, sentences, target}}  ← setRecenseSource(id, json)
//   → {recenseSave:{pageId, json}}   → {powerState:true} ← setPowerState(onPower, percent)
//   → {recenseCard:{original, translation} | null}: the wing card shows the caret's lens line while you write.
import { StateField, StateEffect } from '@codemirror/state';
import { Decoration, EditorView, WidgetType } from '@codemirror/view';
import { docSections, reconcile, sentenceLine, lensLineToLine } from './typedlines.js';
import { settle, reformatKind, pageGist } from './lenses.js';
import { inspectDraftpadPages } from './pages.js';
import { pageSavedId, pageTitle } from './library.js';
import { headingInsert } from './chapters.js';

export const LENSES = ['gist', 'reformat', 'source'];
export const LENS_NAMES = { gist: 'Gist', reformat: 'Reformat', source: 'Source' };
export const QUIET_MS = 60_000;
export const MIN_BATTERY = 30;
const CACHE_MAX = 400;
const ROLE_NAMES = { issue: 'Issue', rule: 'Rule', application: 'Application', conclusion: 'Conclusion' };
const KIND_NAMES = { irac: 'IRAC', timeline: 'Timeline', definitions: 'Definitions', outline: 'Outline' };

// ── The layer's decorations (a state field: block widgets must come from one) ───────────────────────────────────────
export const setRecenseDecos = StateEffect.define();
export const recenseField = StateField.define({
  create: () => Decoration.none,
  update(value, tr) {
    let v = value.map(tr.changes);
    for (const e of tr.effects) if (e.is(setRecenseDecos)) v = e.value;
    return v;
  },
  provide: f => EditorView.decorations.from(f)
});

class LensWidget extends WidgetType {
  constructor(block, onTap) { super(); this.block = block; this.onTap = onTap; this.sig = JSON.stringify(block); }
  eq(other) { return other.sig === this.sig; }
  toDOM() {
    const box = document.createElement('div');
    box.className = `rc-lens rc-lens-${this.block.lens}`;
    box.setAttribute('aria-label', `Recense ${LENS_NAMES[this.block.lens] || ''}`);
    if (this.block.head || this.block.tag) {
      const head = document.createElement('div');
      head.className = 'rc-lens-head';
      if (this.block.head) head.append(Object.assign(document.createElement('span'), { className: 'rc-lens-title', textContent: this.block.head }));
      if (this.block.tag) head.append(Object.assign(document.createElement('span'), { className: 'rc-lens-tag', textContent: this.block.tag, title: this.block.why || '' }));
      box.appendChild(head);
    }
    for (const l of this.block.lines) {
      const row = document.createElement('button');
      row.type = 'button';
      row.className = 'rc-lens-line';
      if (ROLE_NAMES[l.role]) row.append(Object.assign(document.createElement('span'), { className: 'rc-lens-role', textContent: ROLE_NAMES[l.role] }));
      row.append(document.createTextNode(l.text));
      if (l.added) row.append(Object.assign(document.createElement('span'), { className: 'rc-lens-added', textContent: 'added' }));
      else if (l.extract) row.append(Object.assign(document.createElement('span'), { className: 'rc-lens-added', textContent: 'extract' }));
      row.title = l.added ? 'Recense added this: it is not in your text' : 'Tap to light the sentences it comes from';
      row.addEventListener('mousedown', e => e.preventDefault());
      row.addEventListener('click', e => { e.preventDefault(); this.onTap?.(l.from || []); });
      box.appendChild(row);
    }
    return box;
  }
  ignoreEvent() { return true; }
}

const citedMark = Decoration.mark({ class: 'rc-recense-cited' });

/**
 * The lens blocks for the sections, as plain data: [{at, side, lens, head?, tag?, why?, lines}] (at: a doc offset; the
 * block sits under that line, or above it with side −1). Pure, so tests read it without a DOM.
 */
export function lensBlocks(sections, lens, { results, translations = new Map(), stale = new Map() }) {
  const blocks = [];
  for (const s of sections) {
    const byKey = new Map(s.sentences.map(x => [x.key, x]));
    const endOf = keys => Math.max(...keys.map(k => byKey.get(k)?.to ?? -1));
    if (lens === 'source') {
      const byPara = new Map();
      for (const x of s.sentences) {
        const t = translations.get(x.key);
        if (!t) continue;
        if (!byPara.has(x.p)) byPara.set(x.p, { at: x.to, lines: [] });
        const g = byPara.get(x.p);
        g.at = Math.max(g.at, x.to);
        g.lines.push({ text: t, from: [x.key] });
      }
      for (const g of byPara.values()) blocks.push({ at: g.at, side: 1, lens, lines: g.lines });
      continue;
    }
    const r = results.get(s.key);
    const tag = r ? (r.engine === 'model' ? '' : 'extract') : (stale.get(s.key) ? 'earlier' : '');
    if (!r) {
      // Not recensed in this form yet: the lines of an earlier recense that still cite live sentences stay.
      const kept = stale.get(s.key) || [];
      if (kept.length) blocks.push({ at: s.to, side: 1, lens, tag: 'earlier', why: 'from before your last edit', lines: kept });
      continue;
    }
    if (lens === 'gist') {
      const top = pageGist(r);
      if (r.title || top.length) blocks.push({ at: s.sentences[0].from, side: -1, lens, head: s.heading ? '' : r.title, tag, why: r.why, lines: top });
      // One line per paragraph, under that paragraph.
      const paraEnd = new Map();
      for (const x of s.sentences) paraEnd.set(x.p, Math.max(paraEnd.get(x.p) ?? -1, x.to));
      const groups = new Map();
      for (const l of r.gist) {
        const at = paraEnd.has(l.para) ? paraEnd.get(l.para) : l.from.length ? endOf(l.from) : s.to;
        if (!groups.has(at)) groups.set(at, []);
        groups.get(at).push(l);
      }
      for (const [at, lines] of [...groups].sort((a, b) => a[0] - b[0])) blocks.push({ at, side: 1, lens, lines });
    } else {
      blocks.push({ at: s.to, side: 1, lens, head: KIND_NAMES[r.reformat.kind] || '', tag, why: r.why, lines: r.reformat.lines });
    }
  }
  return blocks;
}

export function createRecense({
  getText, dispatch, getCaret = () => -1, hasFocus = () => false,
  post = null, storage = null, now = () => Date.now(), wingCard = null, onChaptersChanged = null
}) {
  const load = (k, d) => { try { const v = storage?.getItem(k); return v == null ? d : JSON.parse(v); } catch { return d; } };
  const save = (k, v) => { try { storage?.setItem(k, JSON.stringify(v)); } catch { /* private window: per-session only */ } };

  let enabled = Boolean(load('rc-recense-on', false));
  let lens = LENSES.includes(load('rc-recense-lens', 'gist')) ? load('rc-recense-lens', 'gist') : 'gist';
  const results = new Map(load('rc-recense-cache', []));          // section key → settled result
  const translations = new Map(load('rc-recense-tr', []));        // sentence key + '>' + target → text
  const targets = load('rc-recense-targets', {});                 // page id (or 'p<index>') → language
  const seen = new Map();                                         // section key → when it first looked like this
  const inflight = new Map();                                     // request id → Map(section key → section)
  let lastDone = Number(load('rc-recense-last', 0)) || 0;
  let power = { onPower: true, percent: 100, at: 0 };
  let cited = [];
  let frozen = null;                                              // the titles as the Chapters panel opened
  let lastCard = 'null';
  let reqN = 0;
  let sections = [];
  let sectionsFor = null;

  function current() {
    const text = getText();
    if (text !== sectionsFor) {
      sections = docSections(text).map(s => ({ ...s, kind: reformatKind(s.sentences) }));
      sectionsFor = text;
      const t = now();
      const live = new Set(sections.map(s => s.key));
      for (const s of sections) if (!seen.has(s.key)) seen.set(s.key, t);
      for (const k of [...seen.keys()]) if (!live.has(k)) seen.delete(k);
    }
    return sections;
  }

  function persist() {
    const entries = [...results].sort((a, b) => (b[1].at || 0) - (a[1].at || 0)).slice(0, CACHE_MAX);
    save('rc-recense-cache', entries);
    save('rc-recense-tr', [...translations].slice(-4 * CACHE_MAX));
    save('rc-recense-last', lastDone);
  }

  /** For a section edited since its recense: the earlier lines whose cited sentences are all still there. */
  function staleLines() {
    const out = new Map();
    const sentenceOwner = new Map();
    for (const [key, r] of results) for (const l of [...r.gist, ...(r.reformat?.lines || []), ...pageGist(r)]) for (const k of l.from) sentenceOwner.set(k, key);
    for (const s of current()) {
      if (results.has(s.key)) continue;
      const olds = new Set(s.sentences.map(x => sentenceOwner.get(x.key)).filter(Boolean));
      const live = new Set(s.sentences.map(x => x.key));
      const lines = [];
      for (const k of olds) {
        const r = results.get(k);
        const pool = lens === 'gist' ? r.gist : lens === 'reformat' ? r.reformat.lines : [];
        lines.push(...reconcile(pool.filter(l => l.from.length), live).kept);
      }
      if (lines.length) out.set(s.key, lines);
    }
    return out;
  }

  function targetFor(pageIndex) {
    const pages = inspectDraftpadPages(getText());
    const id = pages[pageIndex] ? pageSavedId(pages[pageIndex]) || `p${pageIndex}` : `p${pageIndex}`;
    return targets[id] || '';
  }

  function trKey(sentenceKey, pageIndex) { return `${sentenceKey}>${targetFor(pageIndex) || 'auto'}`; }

  function shownTranslations() {
    const m = new Map();
    for (const s of current()) for (const x of s.sentences) {
      const t = translations.get(trKey(x.key, s.pageIndex));
      if (t) m.set(x.key, t);
    }
    return m;
  }

  /** Rebuilds the layer's decorations (only effects: the page's text is never touched here). */
  function redraw() {
    const ranges = [];
    if (enabled) {
      const blocks = lensBlocks(current(), lens, { results, translations: shownTranslations(), stale: staleLines() });
      const text = getText();
      for (const b of blocks) {
        if (!b.lines.length && !b.head) continue;
        // Under the line the block belongs to (its end), or above the section's first line.
        let at = Math.max(0, Math.min(text.length, b.at));
        if (b.side > 0) { const nl = text.indexOf('\n', at); at = nl < 0 ? text.length : nl; }
        else at = text.lastIndexOf('\n', at - 1) + 1;
        ranges.push(Decoration.widget({ widget: new LensWidget(b, tap), block: true, side: b.side }).range(at));
      }
      const byKey = new Map(current().flatMap(s => s.sentences.map(x => [x.key, x])));
      for (const k of cited) { const x = byKey.get(k); if (x && x.to > x.from) ranges.push(citedMark.range(x.from, x.to)); }
    }
    dispatch({ effects: setRecenseDecos.of(Decoration.set(ranges, true)) });
    updateCard();
  }

  let citedTimer = null;
  function tap(keys) {
    cited = keys;
    redraw();
    if (citedTimer) clearTimeout(citedTimer);
    citedTimer = later(() => { cited = []; redraw(); }, 4000);
  }

  // ── The wing card: the caret paragraph's lens line(s) and the sentences they cite ─────────────────────────────────
  function cardFor(caret) {
    if (!enabled || caret < 0) return null;
    const s = current().find(x => caret >= x.from && caret <= x.to + 1);
    if (!s) return null;
    const para = s.sentences.find(x => caret >= x.from && caret <= x.to + 1)?.p ?? s.sentences.at(-1).p;
    const inPara = new Set(s.sentences.filter(x => x.p === para).map(x => x.key));
    const text = new Map(s.sentences.map(x => [x.key, x.text]));
    let lines;
    if (lens === 'source') {
      const tr = shownTranslations();
      lines = [...inPara].filter(k => tr.has(k)).map(k => ({ text: tr.get(k), from: [k] }));
    } else {
      const r = results.get(s.key);
      if (!r) return null;
      const pool = lens === 'gist' ? r.gist : r.reformat.lines;
      lines = pool.filter(l => l.from.some(k => inPara.has(k)));
    }
    if (!lines.length) return null;
    const from = [...new Set(lines.flatMap(l => l.from))];
    return { original: lines.map(l => l.text).join(' '), translation: from.map(k => text.get(k)).filter(Boolean).join(' ') };
  }

  function updateCard() {
    const card = hasFocus() ? cardFor(getCaret()) : null;
    const sig = JSON.stringify(card);
    if (sig === lastCard) return;
    lastCard = sig;
    post?.({ recenseCard: card });
    wingCard?.(card);
  }

  // ── Running ────────────────────────────────────────────────────────────────────────────────────────────────────────
  function powerOK() { return power.onPower || power.percent > MIN_BATTERY; }

  function due(t = now()) {
    const busy = new Set([...inflight.values()].flatMap(m => [...m.keys()]));
    return current().filter(s => !results.has(s.key) && !busy.has(s.key) && t - (seen.get(s.key) ?? t) >= QUIET_MS);
  }

  function send(list) {
    if (!list.length) return null;
    const id = `r${++reqN}`;
    inflight.set(id, new Map(list.map(s => [s.key, s])));
    if (post) {
      post({ recenseSections: { id, sections: list.map(s => ({ key: s.key, kind: s.kind, sentences: s.sentences.map(x => ({ key: x.key, text: x.text, p: x.p })) })) } });
    } else {
      // No host (a browser): the extractive lenses, at once.
      for (const s of list) setSection(id, { key: s.key, engine: 'none', why: 'no Recense app here' });
      done(id);
    }
    return id;
  }

  /** The background pass: sections quiet for 60 s, on power or battery above 30 %. */
  function tick() {
    const list = due();
    if (!list.length) return null;
    if (!powerOK()) return null;
    return send(list);
  }

  /** "Recense now": every section not yet recensed, at once (still never one already on its way). */
  function recenseNow() {
    const busy = new Set([...inflight.values()].flatMap(m => [...m.keys()]));
    const id = send(current().filter(s => !results.has(s.key) && !busy.has(s.key)));
    if (lens === 'source' && enabled) requestSource();
    return id;
  }

  function setSection(id, json) {
    const r = typeof json === 'string' ? JSON.parse(json) : json;
    const s = inflight.get(id)?.get(r?.key) || current().find(x => x.key === r?.key);
    if (!s) return false;
    const settled = settle(s, r);
    results.set(s.key, settled);
    persist();
    saveRecensed(s.pageIndex);
    redraw();
    return true;
  }

  function done(id) {
    inflight.delete(id);
    lastDone = now();
    persist();
    onChaptersChanged?.();
  }

  // ── Source lens ────────────────────────────────────────────────────────────────────────────────────────────────────
  const sourceReq = new Map();
  function requestSource() {
    if (!post) return;
    const byPage = new Map();
    for (const s of current()) for (const x of s.sentences) {
      if (translations.has(trKey(x.key, s.pageIndex))) continue;
      if (!byPage.has(s.pageIndex)) byPage.set(s.pageIndex, []);
      byPage.get(s.pageIndex).push(x);
    }
    for (const [pageIndex, list] of byPage) {
      const id = `s${++reqN}`;
      sourceReq.set(id, { pageIndex, keys: list.map(x => x.key) });
      post({ recenseSource: { id, target: targetFor(pageIndex) || null, sentences: list.map(x => ({ key: x.key, text: x.text })) } });
    }
  }
  let missing = '';
  function setSource(id, json) {
    const req = sourceReq.get(id);
    sourceReq.delete(id);
    const r = typeof json === 'string' ? JSON.parse(json) : json;
    if (!req || !r) return 0;
    missing = r.missing || '';
    let n = 0;
    (r.keys || []).forEach((k, i) => {
      const words = r.lines?.[i]?.english;
      if (Array.isArray(words) && words.length) { translations.set(trKey(k, req.pageIndex), words.map(w => w.w).join(' ')); n++; }
    });
    persist();
    redraw();
    return n;
  }

  // ── Saved pages: Recensed/<id>.json (a transcript: the sentences as Lines, each lens as Lines, the chapters) ────────
  function saveRecensed(pageIndex) {
    if (!post) return;
    const text = getText();
    const page = inspectDraftpadPages(text)[pageIndex];
    const pageId = page && pageSavedId(page);
    if (!pageId) return;
    const secs = current().filter(s => s.pageIndex === pageIndex);
    let n = 0;
    const doc = {
      version: 1, pageId, title: pageTitle(page), updated: new Date(now()).toISOString(),
      lines: secs.flatMap(s => s.sentences.map(x => ({ ...sentenceLine(x, n++), key: x.key }))),
      chapters: secs.filter(s => results.get(s.key)?.title).map(s => ({ title: results.get(s.key).title, from: s.sentences.map(x => x.key), start: 0 })),
      sections: secs.filter(s => results.has(s.key)).map(s => {
        const r = results.get(s.key);
        let m = 0;
        return { key: s.key, engine: r.engine, title: r.title, kind: r.reformat.kind,
          page: pageGist(r).map(l => lensLineToLine(l, m++)),
          gist: r.gist.map(l => ({ ...lensLineToLine(l, m++), para: l.para ?? null })),
          reformat: r.reformat.lines.map(l => ({ ...lensLineToLine(l, m++), role: l.role || null })) };
      })
    };
    post({ recenseSave: { pageId, json: JSON.stringify(doc) } });
  }

  // ── Chapters (the side panel) ──────────────────────────────────────────────────────────────────────────────────────
  function liveTitles() {
    const m = new Map();
    for (const [k, r] of results) if (r.title || pageGist(r).length) m.set(k, { title: r.title, gist: pageGist(r)[0]?.text || r.gist[0]?.text || '' });
    return m;
  }
  function freeze() { frozen = liveTitles(); }
  function unfreeze() { frozen = null; }
  function titles() { return frozen || liveTitles(); }

  /** "Make heading": the only place Recense writes into the page. Puts the chapter's title above its section. */
  function makeHeading(sectionKey) {
    const s = current().find(x => x.key === sectionKey);
    const title = titles().get(sectionKey)?.title || results.get(sectionKey)?.title;
    if (!s || !title || s.heading) return false;
    const text = getText();
    const at = text.lastIndexOf('\n', s.from - 1) + 1;
    dispatch({ changes: { from: at, insert: headingInsert(title) }, userEvent: 'input' });
    return true;
  }

  function setEnabled(on) {
    enabled = Boolean(on);
    save('rc-recense-on', enabled);
    if (enabled && lens === 'source') requestSource();
    redraw();
    return enabled;
  }
  function setLens(name) {
    if (!LENSES.includes(name)) return lens;
    lens = name;
    save('rc-recense-lens', lens);
    if (enabled && lens === 'source') requestSource();
    redraw();
    return lens;
  }
  function nextLens() { return setLens(LENSES[(LENSES.indexOf(lens) + 1) % LENSES.length]); }

  function setTarget(pageIndex, lang) {
    const pages = inspectDraftpadPages(getText());
    const id = pages[pageIndex] ? pageSavedId(pages[pageIndex]) || `p${pageIndex}` : `p${pageIndex}`;
    if (lang) targets[id] = lang; else delete targets[id];
    save('rc-recense-targets', targets);
    if (enabled && lens === 'source') requestSource();
    redraw();
    return targets[id] || '';
  }

  /**
   * After an edit: the layer redraws once typing pauses (its blocks ride along with the text meanwhile). Sections are
   * re-cut lazily, when something reads them; nothing is recensed until a section has been quiet.
   */
  let redrawTimer = null;
  function later(fn, ms) {
    const t = setTimeout(fn, ms);
    t?.unref?.();
    return t;
  }
  function docChanged() {
    if (!enabled) return;
    if (redrawTimer) clearTimeout(redrawTimer);
    redrawTimer = later(() => { redrawTimer = null; redraw(); }, 400);
  }
  let cardTimer = null;
  function cardSoon() {
    if (!enabled && lastCard === 'null') return;
    if (cardTimer) clearTimeout(cardTimer);
    cardTimer = later(() => { cardTimer = null; updateCard(); }, 250);
  }

  return {
    docChanged, tick, recenseNow, setSection, recenseDone: done, setSource, redraw, updateCard: cardSoon,
    setEnabled, isEnabled: () => enabled, setLens, nextLens, getLens: () => lens, setTarget, getTarget: targetFor,
    setPowerState: (onPower, percent) => { power = { onPower: Boolean(onPower), percent: Number(percent) || 0, at: now() }; },
    powerOK, due, sections: current, results, freeze, unfreeze, titles, makeHeading,
    lastDone: () => lastDone, missing: () => missing, cardFor, inflight
  };
}
