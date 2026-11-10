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
import { docSections, reconcile, sentenceLine, lensLineToLine, fnv1a } from './typedlines.js';
import { settle, settleExtra, reformatKind, pageGist, EXTRA_LENSES } from './lenses.js';
import { inspectDraftpadPages } from './pages.js';
import { pageSavedId, pageTitle } from './library.js';
import { headingInsert } from './chapters.js';

export const LENSES = ['gist', 'retell', 'reformat', 'ask', 'reapply', 'source'];
export const LENS_NAMES = { gist: 'Gist', retell: 'Retell', reformat: 'Reformat', ask: 'Ask', reapply: 'Reapply', source: 'Source' };
export const QUIET_MS = 60_000;
export const MIN_BATTERY = 30;
const CACHE_MAX = 400;
const ROLE_NAMES = { issue: 'Issue', rule: 'Rule', application: 'Application', conclusion: 'Conclusion', facts: 'Facts', question: 'Question' };
const LANG_TAGS = { en: 'EN', vi: 'VI', fr: 'FR' };

/** The lines a lens shows for one settled result (Gist's paragraph lines, Reformat's, or an extra lens's). */
export function lensPool(r, lens) {
  if (!r) return [];
  if (lens === 'gist') return r.gist;
  if (lens === 'reformat') return r.reformat.lines;
  return r.extra?.[lens]?.lines || [];
}
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
  constructor(block, onTap, onAnswer, onPlay) {
    super(); this.block = block; this.onTap = onTap; this.onAnswer = onAnswer; this.onPlay = onPlay; this.sig = JSON.stringify(block);
  }
  eq(other) { return other.sig === this.sig; }
  toDOM() {
    const box = document.createElement('div');
    box.className = `rc-lens rc-lens-${this.block.lens}`;
    box.setAttribute('aria-label', `Recense ${LENS_NAMES[this.block.lens] || ''}`);
    if (this.block.sec) box.dataset.sec = this.block.sec;
    if (this.block.lines.length && this.onPlay) {
      // Read this block aloud (every lens can be heard); pressed again, it stops.
      const play = Object.assign(document.createElement('button'), { type: 'button', className: 'rc-lens-play', textContent: '▶' });
      play.setAttribute('aria-label', 'Read this lens aloud');
      play.title = 'Read aloud';
      play.addEventListener('mousedown', e => e.preventDefault());
      play.addEventListener('click', e => { e.preventDefault(); this.onPlay([box]); });
      box.appendChild(play);
    }
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
      if (l.role === 'other' && LANG_TAGS[l.lang]) row.append(Object.assign(document.createElement('span'), { className: 'rc-lens-role', textContent: LANG_TAGS[l.lang] }));
      row._rcText = document.createTextNode(l.text);      // read aloud: the word being spoken is lit in here
      row.append(row._rcText);
      if (l.added) row.append(Object.assign(document.createElement('span'), { className: 'rc-lens-added', textContent: 'added' }));
      else if (l.extract) row.append(Object.assign(document.createElement('span'), { className: 'rc-lens-added', textContent: 'extract' }));
      row.title = l.added ? 'Recense added this: it is not in your text' : 'Tap to light the sentences it comes from';
      row.addEventListener('mousedown', e => e.preventDefault());
      row.addEventListener('click', e => { e.preventDefault(); this.onTap?.(l.from || []); });
      box.appendChild(row);
      if (l.answer) {
        // Ask: the answer waits behind one button, so the question is answered from memory first.
        const btn = Object.assign(document.createElement('button'), { type: 'button', className: 'rc-lens-reveal', textContent: 'Show answer' });
        const ans = Object.assign(document.createElement('div'), { className: 'rc-lens-answer', textContent: l.answer, hidden: true });
        btn.addEventListener('mousedown', e => e.preventDefault());
        btn.addEventListener('click', e => { e.preventDefault(); ans.hidden = !ans.hidden; btn.textContent = ans.hidden ? 'Show answer' : 'Hide answer'; });
        box.append(btn, ans);
      }
      if (l.role === 'question' && l.added && this.block.answerKey) {
        // Reapply: the student's answer, kept beside the facts (saved when the field is left).
        const field = Object.assign(document.createElement('textarea'), { className: 'rc-lens-reply', rows: 3,
          placeholder: 'Your answer', value: this.block.answer || '' });
        field.setAttribute('aria-label', 'Your answer to these facts');
        field.addEventListener('change', () => this.onAnswer?.(this.block.answerKey, field.value));
        box.appendChild(field);
      }
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
export function lensBlocks(sections, lens, { results, translations = new Map(), stale = new Map(), answers = new Map() }) {
  const blocks = [];
  for (const s of sections) {
    const push = b => blocks.push({ ...b, sec: s.key });   // `sec`: read aloud finds the section's blocks by it
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
      for (const g of byPara.values()) push({ at: g.at, side: 1, lens, lines: g.lines });
      continue;
    }
    const r = results.get(s.key);
    const tag = r ? (r.engine === 'model' ? '' : 'extract') : (stale.get(s.key) ? 'earlier' : '');
    if (!r) {
      // Not recensed in this form yet: the lines of an earlier recense that still cite live sentences stay.
      const kept = stale.get(s.key) || [];
      if (kept.length) push({ at: s.to, side: 1, lens, tag: 'earlier', why: 'from before your last edit', lines: kept });
      continue;
    }
    if (lens === 'gist') {
      const top = pageGist(r);
      if (r.title || top.length) push({ at: s.sentences[0].from, side: -1, lens, head: s.heading ? '' : r.title, tag, why: r.why, lines: top });
      // One line per paragraph, under that paragraph.
      const paraEnd = new Map();
      for (const x of s.sentences) paraEnd.set(x.p, Math.max(paraEnd.get(x.p) ?? -1, x.to));
      const groups = new Map();
      for (const l of r.gist) {
        const at = paraEnd.has(l.para) ? paraEnd.get(l.para) : l.from.length ? endOf(l.from) : s.to;
        if (!groups.has(at)) groups.set(at, []);
        groups.get(at).push(l);
      }
      for (const [at, lines] of [...groups].sort((a, b) => a[0] - b[0])) push({ at, side: 1, lens, lines });
    } else if (lens === 'reformat') {
      push({ at: s.to, side: 1, lens, head: KIND_NAMES[r.reformat.kind] || '', tag, why: r.why, lines: r.reformat.lines });
    } else {
      const x = r.extra?.[lens];
      if (!x) continue;                                   // asked for; on its way
      const xtag = x.engine === 'model' ? '' : x.engine === 'key terms' ? 'key terms' : '';
      if (!x.lines.length) { push({ at: s.to, side: 1, lens, head: LENS_NAMES[lens], tag: x.why || 'nothing found', why: x.why, lines: [] }); continue; }
      if (lens === 'retell') {
        const paraEnd = new Map();
        for (const y of s.sentences) paraEnd.set(y.p, Math.max(paraEnd.get(y.p) ?? -1, y.to));
        const groups = new Map();
        for (const l of x.lines) {
          const at = paraEnd.get(l.para) ?? s.to;
          if (!groups.has(at)) groups.set(at, []);
          groups.get(at).push(l);
        }
        for (const [at, lines] of [...groups].sort((a, b) => a[0] - b[0])) push({ at, side: 1, lens, lines });
      } else {
        const b = { at: s.to, side: 1, lens, head: LENS_NAMES[lens], tag: xtag, why: x.why, lines: x.lines };
        if (lens === 'reapply') {
          const facts = x.lines.find(l => l.role === 'facts')?.text || '';
          b.answerKey = `${s.key}:${fnv1a(facts)}`;
          b.answer = answers.get(b.answerKey) || '';
        }
        push(b);
      }
    }
  }
  return blocks;
}

export function createRecense({
  getText, dispatch, getCaret = () => -1, hasFocus = () => false,
  post = null, storage = null, now = () => Date.now(), wingCard = null, onChaptersChanged = null,
  speak = null, stopSpeaking = null, root = null
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
  const answers = new Map(load('rc-recense-answers', []));        // Reapply: section key + facts hash → your answer
  const reqLenses = new Map();                                    // request id → the lenses it asked for
  function setAnswer(key, text) {
    if (String(text).trim()) answers.set(key, String(text)); else answers.delete(key);
    save('rc-recense-answers', [...answers].slice(-CACHE_MAX));
    const s = current().find(x => key.startsWith(`${x.key}:`));
    if (s) saveRecensed(s.pageIndex);
  }
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
    for (const [key, r] of results) for (const l of [...r.gist, ...(r.reformat?.lines || []), ...pageGist(r), ...EXTRA_LENSES.flatMap(x => lensPool(r, x))]) for (const k of l.from) sentenceOwner.set(k, key);
    for (const s of current()) {
      if (results.has(s.key)) continue;
      const olds = new Set(s.sentences.map(x => sentenceOwner.get(x.key)).filter(Boolean));
      const live = new Set(s.sentences.map(x => x.key));
      const lines = [];
      for (const k of olds) {
        const r = results.get(k);
        const pool = lensPool(r, lens);
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
      const blocks = lensBlocks(current(), lens, { results, translations: shownTranslations(), stale: staleLines(), answers });
      const text = getText();
      for (const b of blocks) {
        if (!b.lines.length && !b.head) continue;
        // Under the line the block belongs to (its end), or above the section's first line.
        let at = Math.max(0, Math.min(text.length, b.at));
        if (b.side > 0) { const nl = text.indexOf('\n', at); at = nl < 0 ? text.length : nl; }
        else at = text.lastIndexOf('\n', at - 1) + 1;
        ranges.push(Decoration.widget({ widget: new LensWidget(b, tap, setAnswer, speak ? play : null), block: true, side: b.side }).range(at));
      }
      const byKey = new Map(current().flatMap(s => s.sentences.map(x => [x.key, x])));
      for (const k of cited) { const x = byKey.get(k); if (x && x.to > x.from) ranges.push(citedMark.range(x.from, x.to)); }
    }
    dispatch({ effects: setRecenseDecos.of(Decoration.set(ranges, true)) });
    updateCard();
  }

  // ── Read aloud: any lens can be heard (the host's voice per line's language; the spoken word is lit) ─────────────
  let playing = null;                                   // { boxes } while a lens is being read
  const hasHighlights = typeof CSS !== 'undefined' && CSS.highlights && typeof Highlight !== 'undefined';
  function clearLight(rows) {
    if (hasHighlights) CSS.highlights.delete('rc-say');
    for (const r of rows || []) r.classList.remove('rc-lens-saying');
  }
  /** Reads the lines of these lens blocks in order; pressed again on the same blocks, stops. */
  function play(boxes) {
    if (!speak) return false;
    const same = playing && playing.boxes.length === boxes.length && playing.boxes.every((b, i) => b === boxes[i]);
    if (playing) { stopSpeaking?.(); if (same) return false; }
    const rows = boxes.flatMap(b => [...b.querySelectorAll('.rc-lens-line')]).filter(r => r._rcText?.data);
    if (!rows.length) return false;
    for (const b of boxes) b.classList.add('rc-lens-playing');
    const me = { boxes, rows };
    playing = me;
    speak(rows.map(r => r._rcText.data), {
      onWord: (part, from, len) => {
        const row = rows[part];
        if (!row || playing !== me) return;
        clearLight(rows);
        row.classList.add('rc-lens-saying');
        if (hasHighlights && len > 0) {
          const range = document.createRange();
          range.setStart(row._rcText, Math.min(from, row._rcText.length));
          range.setEnd(row._rcText, Math.min(from + len, row._rcText.length));
          CSS.highlights.set('rc-say', new Highlight(range));
        }
      },
      onDone: () => {
        clearLight(rows);
        for (const b of boxes) b.classList.remove('rc-lens-playing');
        if (playing === me) playing = null;
      }
    });
    return true;
  }
  /** "Read lens aloud" (menu, voice): the lens blocks of the section at the caret, else the first one on screen. */
  function readAloudAt(caret) {
    if (!enabled || !root) return false;
    const s = current().find(x => caret >= x.from && caret <= x.to + 1) || current()[0];
    let boxes = s ? [...root.querySelectorAll(`.rc-lens[data-sec="${s.key}"]`)] : [];
    if (!boxes.length) boxes = [...root.querySelectorAll('.rc-lens')].slice(0, 1);
    return boxes.length ? play(boxes) : false;
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
      const pool = lensPool(r, lens);
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

  /** What a pass asks for: Gist and Reformat always (chapters need the title), plus the lens on screen if extra. */
  function lensesFor() { return ['gist', 'reformat', ...(EXTRA_LENSES.includes(lens) && enabled ? [lens] : [])]; }

  function send(list, lenses = lensesFor()) {
    if (!list.length) return null;
    const id = `r${++reqN}`;
    inflight.set(id, new Map(list.map(s => [s.key, s])));
    reqLenses.set(id, lenses);
    if (post) {
      post({ recenseSections: { id, lenses, sections: list.map(s => ({ key: s.key, kind: s.kind, sentences: s.sentences.map(x => ({ key: x.key, text: x.text, p: x.p })) })) } });
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
    requestExtra();
    return id;
  }

  /** The extra lens on screen, for sections recensed without it (asked once; the answer is cached like the rest). */
  function requestExtra() {
    if (!enabled || !EXTRA_LENSES.includes(lens)) return null;
    const busy = new Set([...inflight.values()].flatMap(m => [...m.keys()]));
    return send(current().filter(s => results.has(s.key) && !results.get(s.key).extra?.[lens] && !busy.has(s.key)), [lens]);
  }

  function setSection(id, json) {
    const r = typeof json === 'string' ? JSON.parse(json) : json;
    const s = inflight.get(id)?.get(r?.key) || current().find(x => x.key === r?.key);
    if (!s) return false;
    const asked = reqLenses.get(id) || ['gist', 'reformat'];
    const before = results.get(s.key);
    const settled = asked.includes('gist') || !before ? settle(s, r) : before;
    settled.extra = { ...(before?.extra || {}) };
    for (const x of asked.filter(l => EXTRA_LENSES.includes(l))) settled.extra[x] = settleExtra(s, x, r);
    results.set(s.key, settled);
    persist();
    saveRecensed(s.pageIndex);
    redraw();
    return true;
  }

  function done(id) {
    inflight.delete(id);
    reqLenses.delete(id);
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
          reformat: r.reformat.lines.map(l => ({ ...lensLineToLine(l, m++), role: l.role || null })),
          ...Object.fromEntries(Object.entries(r.extra || {}).map(([x, v]) => [x, v.lines.map(l => ({ ...lensLineToLine(l, m++),
            role: l.role || null, ...(l.answer ? { answer: l.answer } : {}), ...(l.lang ? { lang: l.lang } : {}) }))])),
          answers: Object.fromEntries([...answers].filter(([k]) => k.startsWith(`${s.key}:`))) };
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
    requestExtra();
    redraw();
    return enabled;
  }
  function setLens(name) {
    if (!LENSES.includes(name)) return lens;
    lens = name;
    save('rc-recense-lens', lens);
    if (enabled && lens === 'source') requestSource();
    requestExtra();
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
    lastDone: () => lastDone, missing: () => missing, cardFor, inflight, answers, setAnswer, play, readAloudAt,
    isPlaying: () => Boolean(playing), stopReading: () => { if (playing) stopSpeaking?.(); }
  };
}
