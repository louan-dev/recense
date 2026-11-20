// Derived from Spec: UI-14 (C1–C8, Z1). The Content Manager: every page of draftpad.md as a numbered thumbnail,
// with Search, a filter, Select, Expand, Undo/Redo, thumbnail size, and the page's timed passages (the underlay feed).
// Model: Notability's Content Manager (owner recordings 11-18, 11-20); clean-room, behaviour only.
// One home for every host (Mac, iPhone, iPad, web): the editor. Pure helpers first, then the panel.
import { inspectDraftpadPages, isFullDateLine, SLOT_RE } from './pages.js';
import { findQuote } from './matter.js';

const fold = t => String(t || '').normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/đ/g, 'd').replace(/Đ/g, 'D').toLowerCase();


/** C3 · One record per page: index, number (1-based), date line, body text (no date, no slot line), slot. */
export function pageThumbs(docText) {
  return inspectDraftpadPages(String(docText || '')).map(p => {
    const lines = p.rawContent.split('\n');
    let dateLine = '';
    let slot = null;
    const body = [];
    for (const raw of lines) {
      const t = raw.trim();
      const m = SLOT_RE.exec(t);
      if (m) { slot = Number(m[1]); continue; }
      if (!dateLine && !body.length && t && isFullDateLine(t)) { dateLine = t; continue; }
      body.push(raw);
    }
    return { index: p.index, number: p.index + 1, dateLine, text: body.join('\n').trim(), slot };
  });
}

/**
 * C2/C7 · The pages shown: `filter` 'all' or 'slotted'; `query` matches the page's text, or its handwriting
 * (`inkText(index)` returns the OCR text on that page), any case, accents ignored.
 */
export function filterThumbs(thumbs, { query = '', filter = 'all', inkText = null } = {}) {
  const q = fold(query).trim();
  return thumbs.filter(t => {
    if (filter === 'slotted' && t.slot == null) return false;
    if (!q) return true;
    if (fold(`${t.dateLine}\n${t.text}`).includes(q)) return true;
    return typeof inkText === 'function' && fold(inkText(t.index)).includes(q);
  });
}

/** C7 · `text` split into parts, the hits of `query` marked (for bold). */
export function markHits(text, query) {
  const s = String(text || '');
  const q = fold(query).trim();
  if (!q) return [{ text: s, hit: false }];
  const f = fold(s);
  const out = [];
  let at = 0;
  for (let i = f.indexOf(q); i !== -1; i = f.indexOf(q, i + q.length)) {
    if (i > at) out.push({ text: s.slice(at, i), hit: false });
    out.push({ text: s.slice(i, i + q.length), hit: true });
    at = i + q.length;
  }
  if (at < s.length) out.push({ text: s.slice(at), hit: false });
  return out;
}

/** mm:ss (or h:mm:ss) for a media second. */
export function clockOf(sec) {
  const s = Math.max(0, Math.floor(Number(sec) || 0));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60;
  const two = n => String(n).padStart(2, '0');
  return h ? `${h}:${two(m)}:${two(r)}` : `${m}:${two(r)}`;
}

/**
 * C8 · The underlay feed for page `index`: every passage written on it, with its note time, in time order.
 * `media`: { key, t } when the passage was written while a media item played (tap seeks there);
 * `at`: the real-life time it was written (FEAT-08 P6 seed). Passages no longer found in the body are left out.
 */
export function timedEntries(docText, side, index) {
  const text = String(docText || '');
  const page = inspectDraftpadPages(text)[index];
  if (!page) return [];
  const out = [];
  for (const p of Object.values((side && side.passages) || {})) {
    const form = p && p.forms && p.forms.type;
    if (!form || !form.quote) continue;
    const off = findQuote(text, form);
    if (off < page.from || off >= page.to) continue;
    const md = p.seed && p.seed.media;
    const media = md && typeof md.key === 'string' && Number.isFinite(md.t) ? { key: md.key, t: md.t } : null;
    const at = p.seed && p.seed.time ? String(p.seed.time) : '';
    out.push({ id: p.id, text: form.quote, offset: off, media, at });
  }
  return out.sort((a, b) => (a.media && b.media ? a.media.t - b.media.t : 0) || a.at.localeCompare(b.at) || a.offset - b.offset);
}

/** Z1 · thumbnail columns, 1 to 5. */
export const MIN_COLS = 1;
export const MAX_COLS = 5;
export const stepCols = (cols, d) => Math.max(MIN_COLS, Math.min(MAX_COLS, (Number(cols) || 2) + d));

/**
 * The panel. `deps`:
 *   getText(), getSide() (FEAT-08 sidecar), current(), inkText(i), hasInk(i),
 *   open(i), promote(i), slot(i, anchor), remove(i) → bool, move(i, to) → bool, newPage(), undo(), redo(),
 *   seek(key, t), jump(offset), haptic(kind), onClose().
 */
export function createContentManager(parent, deps) {
  const doc = parent.ownerDocument || document;
  const el = (tag, cls, txt) => { const e = doc.createElement(tag); if (cls) e.className = cls; if (txt != null) e.textContent = txt; return e; };
  const btn = (cls, label, aria, run) => {
    const b = el('button', cls, label);
    b.type = 'button';
    if (aria) b.setAttribute('aria-label', aria);
    b.addEventListener('click', e => { e.stopPropagation(); run(e); });
    return b;
  };

  const panel = el('aside', 'rc-cm');
  panel.setAttribute('role', 'dialog');
  panel.setAttribute('aria-label', 'Pages');
  panel.hidden = true;
  const head = el('div', 'rc-cm-head');
  const search = el('input', 'rc-cm-search');
  search.type = 'search';
  search.placeholder = 'Search';
  search.setAttribute('aria-label', 'Search pages');
  const tools = el('div', 'rc-cm-tools');
  const filterBtn = btn('rc-cm-filter', 'All pages ▾', 'Filter pages', () => { state.filter = state.filter === 'all' ? 'slotted' : 'all'; render(); });
  const count = el('span', 'rc-cm-count');
  const undoBtn = btn('rc-cm-icon', '↶', 'Undo', () => { deps.undo(); render(); });
  const redoBtn = btn('rc-cm-icon', '↷', 'Redo', () => { deps.redo(); render(); });
  const smaller = btn('rc-cm-icon', '−', 'Smaller thumbnails', () => setCols(stepCols(state.cols, 1)));
  const larger = btn('rc-cm-icon', '+', 'Larger thumbnails', () => setCols(stepCols(state.cols, -1)));
  tools.append(filterBtn, count, undoBtn, redoBtn, smaller, larger);
  head.append(search, tools);
  const grid = el('div', 'rc-cm-grid');
  grid.setAttribute('role', 'list');
  const feed = el('div', 'rc-cm-feed');
  const foot = el('div', 'rc-cm-foot');
  const selectBtn = btn('rc-cm-link', 'Select', 'Select pages', () => { state.selecting = !state.selecting; state.picked.clear(); render(); });
  const deleteSel = btn('rc-cm-link', 'Delete', 'Delete selected pages', () => {
    // highest first, so lower indices stay valid; each is one undoable change
    const ids = [...state.picked].sort((a, b) => b - a);
    let refused = 0;
    for (const i of ids) if (!deps.remove(i)) refused++;
    state.picked.clear();
    state.selecting = false;
    render(refused ? `${refused} page${refused > 1 ? 's' : ''} kept: ink or only page` : '');
  });
  const expandBtn = btn('rc-cm-link', 'Expand', 'Expand to full screen', () => { state.expanded = !state.expanded; render(); });
  const closeBtn = btn('rc-cm-link', 'Close', 'Close pages', () => close());
  foot.append(selectBtn, deleteSel, expandBtn, closeBtn);
  const note = el('p', 'rc-cm-note');
  note.setAttribute('role', 'status');
  panel.append(head, grid, feed, note, foot);
  parent.appendChild(panel);

  const state = { side: 'end', filter: 'all', cols: 2, expanded: false, selecting: false, picked: new Set(), menuFor: -1, drag: null };

  function setCols(c) { state.cols = c; render(); }

  function close() {
    if (panel.hidden) return;
    panel.hidden = true;
    state.selecting = false; state.picked.clear(); state.menuFor = -1;
    if (typeof deps.onClose === 'function') deps.onClose();
  }

  /** C1 · `side`: 'newest' opens at the logical start, 'oldest' (and the bar) at the end. */
  function open(side = 'oldest') {
    state.side = side === 'newest' ? 'start' : 'end';
    panel.hidden = false;
    render();
    if (typeof deps.haptic === 'function') deps.haptic('open');
    const cur = grid.querySelector('.is-current');
    if (cur && typeof cur.scrollIntoView === 'function') cur.scrollIntoView({ block: 'nearest' });
  }

  function thumbMenu(t, card) {
    const m = el('div', 'rc-cm-menu');
    m.setAttribute('role', 'menu');
    const item = (label, run) => { const b = btn('rc-menu-item', label, null, () => { state.menuFor = -1; run(); }); b.setAttribute('role', 'menuitem'); m.appendChild(b); };
    item('Open', () => { deps.open(t.index); close(); });
    if (t.index > 0) item('Promote to front', () => { deps.promote(t.index); render(); });
    item('Slot…', () => deps.slot(t.index, card));
    item('Delete page', () => render(deps.remove(t.index) ? '' : 'Page kept: it has ink, or it is the only page'));
    return m;
  }

  function render(message = '') {
    if (panel.hidden) return;
    const text = deps.getText();
    const all = pageThumbs(text);
    const shown = filterThumbs(all, { query: search.value, filter: state.filter, inkText: deps.inkText });
    const current = deps.current();
    panel.dataset.side = state.side;
    panel.classList.toggle('is-expanded', state.expanded);
    panel.style.setProperty('--rc-cm-cols', String(state.expanded ? Math.max(state.cols, 3) : state.cols));
    filterBtn.textContent = state.filter === 'all' ? 'All pages ▾' : 'Slotted ▾';
    count.textContent = search.value.trim() ? `${shown.length} result${shown.length === 1 ? '' : 's'}` : `${all.length} page${all.length === 1 ? '' : 's'}`;
    selectBtn.textContent = state.selecting ? 'Done' : 'Select';
    deleteSel.hidden = !state.selecting;
    deleteSel.disabled = state.picked.size === 0;
    expandBtn.textContent = state.expanded ? 'Shrink' : 'Expand';
    smaller.disabled = state.cols >= MAX_COLS;
    larger.disabled = state.cols <= MIN_COLS;
    note.textContent = message;
    note.hidden = !message;
    while (grid.firstChild) grid.removeChild(grid.firstChild);
    for (const t of shown) {
      const card = el('div', `rc-cm-thumb${t.index === current ? ' is-current' : ''}${state.picked.has(t.index) ? ' is-picked' : ''}`);
      card.setAttribute('role', 'listitem');
      card.dataset.page = String(t.index);
      const face = el('button', 'rc-cm-face');
      face.type = 'button';
      face.setAttribute('aria-label', `Page ${t.number}${t.dateLine ? `, ${t.dateLine}` : ''}`);
      const paper = el('div', 'rc-cm-paper');
      if (t.dateLine) paper.appendChild(el('div', 'rc-cm-date', t.dateLine));
      const body = el('div', 'rc-cm-body');
      for (const part of markHits(t.text.slice(0, 600), search.value)) body.appendChild(part.hit ? el('b', null, part.text) : doc.createTextNode(part.text));
      paper.appendChild(body);
      if (deps.hasInk && deps.hasInk(t.index)) paper.appendChild(el('span', 'rc-cm-ink', '✎'));
      if (t.slot != null) paper.appendChild(el('span', 'rc-cm-slot', String(t.slot)));
      face.appendChild(paper);
      face.addEventListener('click', e => {
        e.stopPropagation();
        if (state.drag && state.drag.moved) return;
        if (state.selecting) { state.picked.has(t.index) ? state.picked.delete(t.index) : state.picked.add(t.index); render(); return; }
        deps.open(t.index);
        close();
      });
      attachDrag(face, t.index);
      const more = btn('rc-cm-more', '···', `Page ${t.number} actions`, () => { state.menuFor = state.menuFor === t.index ? -1 : t.index; render(); });
      card.append(face, el('div', 'rc-cm-num', String(t.number)), more);
      if (state.menuFor === t.index) card.appendChild(thumbMenu(t, card));
      grid.appendChild(card);
    }
    if (!shown.length) grid.appendChild(el('p', 'rc-cm-empty', search.value.trim() ? 'No pages match' : 'No pages'));
    renderFeed(text, current);
  }

  /** C8 · what was written on the current page, each passage with its note time; tap seeks or jumps. */
  function renderFeed(text, current) {
    while (feed.firstChild) feed.removeChild(feed.firstChild);
    const rows = timedEntries(text, deps.getSide ? deps.getSide() : null, current);
    feed.hidden = rows.length === 0 || state.expanded;
    if (feed.hidden) return;
    feed.appendChild(el('h3', 'rc-cm-feed-title', 'Written on this page'));
    for (const r of rows) {
      const time = r.media ? clockOf(r.media.t) : (r.at ? new Date(r.at).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }) : '');
      const row = btn('rc-cm-row', '', r.media ? `Play from ${time}` : `Go to the passage written ${time}`, () => {
        if (r.media) deps.seek(r.media.key, r.media.t);
        else deps.jump(r.offset);
      });
      row.append(el('span', 'rc-cm-time', time));
      const words = el('span', 'rc-cm-words');
      for (const part of markHits(r.text, search.value)) words.appendChild(part.hit ? el('b', null, part.text) : doc.createTextNode(part.text));
      row.appendChild(words);
      feed.appendChild(row);
    }
  }

  /** C6 · drag a thumbnail over another to move the page there (order only; UI-06 G4's rule). */
  function attachDrag(face, index) {
    face.addEventListener('pointerdown', e => {
      if (state.selecting || e.button > 0) return;
      state.drag = { index, x: e.clientX, y: e.clientY, moved: false, id: e.pointerId };
    });
    face.addEventListener('pointermove', e => {
      const d = state.drag;
      if (!d || d.id !== e.pointerId) return;
      if (!d.moved && Math.hypot(e.clientX - d.x, e.clientY - d.y) >= 8) { d.moved = true; panel.classList.add('is-dragging'); }
    });
    face.addEventListener('pointerup', e => {
      const d = state.drag;
      if (!d || d.id !== e.pointerId) return;
      panel.classList.remove('is-dragging');
      if (d.moved) {
        const hit = typeof doc.elementFromPoint === 'function' ? doc.elementFromPoint(e.clientX, e.clientY) : null;
        const target = hit && hit.closest ? hit.closest('.rc-cm-thumb') : null;
        const to = target ? Number(target.dataset.page) : -1;
        if (to >= 0 && to !== d.index) deps.move(d.index, to);
        render();
      }
      setTimeout(() => { state.drag = null; }, 0);
    });
  }

  search.addEventListener('input', () => render());
  search.addEventListener('keydown', e => { if (e.key === 'Escape') { e.stopPropagation(); close(); } });
  panel.addEventListener('pointerdown', e => e.stopPropagation());
  // Z1 · pinch on the grid: apart = larger thumbnails (fewer columns), together = smaller.
  let pinch0 = null;
  grid.addEventListener('touchstart', e => { if (e.touches.length === 2) pinch0 = Math.hypot(e.touches[0].clientX - e.touches[1].clientX, e.touches[0].clientY - e.touches[1].clientY); }, { passive: true });
  grid.addEventListener('touchmove', e => {
    if (pinch0 == null || e.touches.length !== 2) return;
    const d = Math.hypot(e.touches[0].clientX - e.touches[1].clientX, e.touches[0].clientY - e.touches[1].clientY);
    if (d / pinch0 > 1.25) { pinch0 = d; setCols(stepCols(state.cols, -1)); }
    else if (d / pinch0 < 0.8) { pinch0 = d; setCols(stepCols(state.cols, 1)); }
  }, { passive: true });
  grid.addEventListener('touchend', () => { pinch0 = null; }, { passive: true });
  // Mac trackpad pinch arrives as ctrl+wheel.
  grid.addEventListener('wheel', e => {
    if (!e.ctrlKey) return;
    e.preventDefault();
    if (Math.abs(e.deltaY) < 4) return;
    setCols(stepCols(state.cols, e.deltaY > 0 ? 1 : -1));
  }, { passive: false });

  return {
    open, close, render,
    isOpen: () => !panel.hidden,
    toggle(side) { if (panel.hidden) open(side); else close(); },
    el: panel,
    _state: state
  };
}
