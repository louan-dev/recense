// Isolated mini-document windows (restoring old Draftpad navigation, reference/draftpad):
// - Each window is a mini document: hiddenRanges + Decoration.replace({ block: true }) hides all other pages so
//   vertical scrolling stays strictly inside the current window's text and never crosses into another topic.
// - Left-to-right swipe (or stepPage(view, -1) / swipeLeftToRight(view)): one window newer, toward index 0.
// - Right-to-left swipe (or stepPage(view, 1) / swipeRightToLeft(view)): one window older.
// - UI-14: past either end the same end card appears (`view.__pageEnd`); a swipe never makes a page, and leaving
//   an empty window removes its `<!-- page -->` block (no text is lost). New pages come from newPage / ＋ / the card.
// - Per-window cursor and vertical scroll memory, plus live finger-follow drag with 0.25x rubber-banding and
//   220ms ease-out snap.
import { StateField, StateEffect, Prec, EditorState, EditorSelection } from '@codemirror/state';
import { Decoration, EditorView, keymap } from '@codemirror/view';
import { PAGE_JOINER, inspectDraftpadPages, isWindowEmpty, SLOT_RE, isMetaLine, CONTROL_CHARS_RE, formatDateLine } from './pages.js';
import { postHaptic } from './bridge.js';

export { isWindowEmpty };

export const setPageMode = StateEffect.define();
export const setPageIndex = StateEffect.define();

const viewMemory = new WeakMap();

function getMemory(view) {
  if (!view || typeof view !== 'object') {
    return { cursors: new Map(), scrolls: new Map(), dragX: 0, dragging: false, settling: false };
  }
  let m = viewMemory.get(view);
  if (!m) {
    m = { cursors: new Map(), scrolls: new Map(), dragX: 0, dragging: false, settling: false };
    viewMemory.set(view, m);
  }
  return m;
}

export function pageAt(pages, pos) {
  for (let i = 0; i < pages.length; i++) {
    const next = pages[i + 1];
    if (!next || pos < next.from) return i;
  }
  return Math.max(0, pages.length - 1);
}

/**
 * Computes the character offset of page `page`'s opening date heading (or first line).
 */
export function pageHeadingOffset(doc, page) {
  if (!page) return 0;
  if (page.dateLineNumber && doc && typeof doc.line === 'function') {
    return doc.line(page.dateLineNumber).from;
  }
  return page.from;
}

/**
 * Computes whole-line character ranges outside window `index` so only `pages[index]` remains visible.
 */
export function hiddenRanges(text, index) {
  const pages = inspectDraftpadPages(text);
  if (pages.length <= 1) return [];
  const i = Math.max(0, Math.min(pages.length - 1, index));
  const { from, to } = pages[i];
  const out = [];
  if (from > 0) {
    let beforeEnd = from - 1;
    if (beforeEnd > 0 && text[beforeEnd - 1] === '\r' && text[beforeEnd] === '\n') {
      beforeEnd -= 1;
    }
    out.push({ from: 0, to: beforeEnd });
  }
  if (to < text.length) {
    let afterStart = to + 1;
    if (text[to] === '\r' && text[to + 1] === '\n') {
      afterStart = to + 2;
    }
    if (afterStart <= text.length) {
      out.push({ from: afterStart, to: text.length });
    }
  }
  return out.filter(r => r.to >= r.from);
}

const hiddenPageDeco = Decoration.replace({ block: true });

function buildPageDecos(docText, on, index) {
  if (!on) return Decoration.none;
  const ranges = hiddenRanges(docText, index);
  if (ranges.length === 0) return Decoration.none;
  return Decoration.set(
    ranges.map(r => hiddenPageDeco.range(r.from, r.to)),
    true
  );
}

export const pageModeField = StateField.define({
  create(state) {
    const text = state.doc.toString();
    return { on: true, index: 0, decos: buildPageDecos(text, true, 0) };
  },
  update(v, tr) {
    let on = v.on;
    let index = v.index;
    let explicitIndex = false;
    for (const e of tr.effects) {
      if (e.is(setPageMode)) on = Boolean(e.value);
      if (e.is(setPageIndex)) {
        index = e.value;
        explicitIndex = true;
      }
    }
    const text = tr.state.doc.toString();
    const pages = inspectDraftpadPages(text);
    index = Math.max(0, Math.min(pages.length - 1, index));
    // When the cursor moves to another page (search, outline jump, arrows), follow it.
    if (on && tr.selection && !explicitIndex) {
      const at = pageAt(pages, tr.state.selection.main.head);
      if (at !== index) index = at;
    }
    if (!tr.docChanged && on === v.on && index === v.index) return v;
    return { on, index, decos: buildPageDecos(text, on, index) };
  },
  provide: f => EditorView.decorations.from(f, v => v.decos)
});

export function currentPage(stateOrView) {
  const state = stateOrView && stateOrView.state ? stateOrView.state : stateOrView;
  if (!state) return 0;
  const v = state.field(pageModeField, false);
  return v ? v.index : 0;
}

export function isPageMode(state) {
  const v = state.field(pageModeField, false);
  return Boolean(v && v.on);
}

export function pageCount(state) {
  return inspectDraftpadPages(state.doc.toString()).length;
}

function saveCurrentWindowMemory(view) {
  if (!view || !view.state) return;
  const mem = getMemory(view);
  const idx = currentPage(view.state);
  const pages = inspectDraftpadPages(view.state.doc.toString());
  const page = pages[idx];
  if (page) {
    const relCursor = Math.max(0, Math.min(page.to - page.from, view.state.selection.main.head - page.from));
    mem.cursors.set(idx, relCursor);
  }
  if (view.scrollDOM && typeof view.scrollDOM.scrollTop === 'number') {
    mem.scrolls.set(idx, Math.max(0, view.scrollDOM.scrollTop));
  }
}

function shiftWindowMemoryOnPrepend(mem, totalBefore) {
  const nextCursors = new Map();
  const nextScrolls = new Map();
  for (let i = 0; i < totalBefore; i++) {
    if (mem.cursors.has(i)) nextCursors.set(i + 1, mem.cursors.get(i));
    if (mem.scrolls.has(i)) nextScrolls.set(i + 1, mem.scrolls.get(i));
  }
  nextCursors.set(0, 0);
  nextScrolls.set(0, 0);
  mem.cursors = nextCursors;
  mem.scrolls = nextScrolls;
}

function shiftWindowMemoryOnDelete(mem, deletedIndex, totalBefore) {
  const nextCursors = new Map();
  const nextScrolls = new Map();
  for (let i = 0; i < totalBefore; i++) {
    if (i === deletedIndex) continue;
    const dst = i > deletedIndex ? i - 1 : i;
    if (mem.cursors.has(i)) nextCursors.set(dst, mem.cursors.get(i));
    if (mem.scrolls.has(i)) nextScrolls.set(dst, mem.scrolls.get(i));
  }
  mem.cursors = nextCursors;
  mem.scrolls = nextScrolls;
}

/**
 * In isolated mini-document window mode, vertical scrolling stays inside the active window (`currentPage`)
 * and records its per-window scrollTop without ever crossing to another topic.
 * If page mode is explicitly turned off, updates `currentPage` from scrollTop.
 */
export function syncPageFromScroll(view, { onSnap = null, globalObj } = {}) {
  if (!view || !view.state) return 0;
  if (isPageMode(view.state)) {
    if (view.scrollDOM && typeof view.scrollDOM.scrollTop === 'number') {
      getMemory(view).scrolls.set(currentPage(view.state), Math.max(0, view.scrollDOM.scrollTop));
    }
    return currentPage(view.state);
  }
  if (!view.scrollDOM || typeof view.lineBlockAtHeight !== 'function') {
    return currentPage(view);
  }
  const pages = inspectDraftpadPages(view.state.doc.toString());
  const top = Math.max(0, Number(view.scrollDOM.scrollTop) || 0);
  const pos = top <= 4 ? 0 : view.lineBlockAtHeight(top + 24).from;
  const at = pageAt(pages, pos);
  const prev = currentPage(view.state);
  if (at !== prev) {
    view.dispatch({ effects: setPageIndex.of(at) });
    postHaptic('snap', globalObj);
    if (typeof onSnap === 'function') onSnap(at);
  }
  return at;
}

/** Shows window `index`, restoring its saved cursor offset (or start) and its own scrollTop. */
export function showPage(view, index, { preserveMemory = true } = {}) {
  if (preserveMemory) saveCurrentWindowMemory(view);
  const pages = inspectDraftpadPages(view.state.doc.toString());
  const i = Math.max(0, Math.min(pages.length - 1, index));
  const page = pages[i];
  const mem = getMemory(view);
  const pageLen = page ? Math.max(0, page.to - page.from) : 0;
  const savedRel = mem.cursors.has(i) ? Math.min(mem.cursors.get(i), pageLen) : null;
  const targetPos = savedRel !== null ? page.from + savedRel : pageHeadingOffset(view.state.doc, page);

  view.dispatch({
    selection: { anchor: targetPos },
    effects: [setPageIndex.of(i), EditorView.scrollIntoView(targetPos, { y: 'start', yMargin: 8 })]
  });

  if (view.scrollDOM) {
    const savedScroll = mem.scrolls.has(i) ? mem.scrolls.get(i) : 0;
    if (typeof view.scrollDOM.scrollTo === 'function') {
      view.scrollDOM.scrollTo({ top: savedScroll, behavior: 'smooth' });
    } else {
      view.scrollDOM.scrollTop = savedScroll;
    }
  }
  return i;
}

/**
 * Deletes an empty window at `index` from `view.state.doc`, removing its `<!-- page -->` block from the .md file.
 * Returns true if deleted, false if the window has text or is the only window.
 */
export function deleteEmptyWindow(view, index = currentPage(view.state), { onSnap = null, globalObj } = {}) {
  const docText = view.state.doc.toString();
  const pages = inspectDraftpadPages(docText);
  if (pages.length <= 1) return false;
  const i = Math.max(0, Math.min(pages.length - 1, index));
  if (!isWindowEmpty(pages[i].rawContent)) return false;
  // UI-14 E4 · a page with ink is never empty: the host says whether strokes sit on it (ink anchors by page).
  if (typeof view.__pageHasInk === 'function' && view.__pageHasInk(i)) return false;

  const mem = getMemory(view);
  const delFrom = i === 0 ? 0 : pages[i - 1].to;
  const delTo = i === 0 ? pages[1].from : pages[i].to;
  shiftWindowMemoryOnDelete(mem, i, pages.length);

  const nextCount = pages.length - 1;
  const nextIndex = Math.min(i, nextCount - 1);
  const nextDocPreview = docText.slice(0, delFrom) + docText.slice(delTo);
  const nextPages = inspectDraftpadPages(nextDocPreview);
  const nextPage = nextPages[nextIndex];
  const nextPageLen = nextPage ? Math.max(0, nextPage.to - nextPage.from) : 0;
  const savedRel = mem.cursors.has(nextIndex) ? Math.min(mem.cursors.get(nextIndex), nextPageLen) : 0;
  const nextAnchor = nextPage ? nextPage.from + savedRel : 0;

  view.dispatch({
    changes: { from: delFrom, to: delTo, insert: '' },
    selection: { anchor: nextAnchor },
    effects: [setPageIndex.of(nextIndex), EditorView.scrollIntoView(nextAnchor, { y: 'start', yMargin: 8 })],
    userEvent: 'delete.page'
  });

  if (view.scrollDOM) {
    const savedScroll = mem.scrolls.get(nextIndex) || 0;
    if (typeof view.scrollDOM.scrollTo === 'function') {
      view.scrollDOM.scrollTo({ top: savedScroll, behavior: 'smooth' });
    } else {
      view.scrollDOM.scrollTop = savedScroll;
    }
  }

  postHaptic('snap', globalObj);
  if (typeof onSnap === 'function') onSnap(nextIndex);
  return true;
}

/**
 * Opens a new empty window on the left (index 0) by prepending `\n\n<!-- page -->\n\n` at the top of the .md file,
 * but only when window 0 currently has text.
 */
export function openNewWindowOnLeft(view, { onSnap = null, onBounce = null, globalObj, now = Date.now() } = {}) {
  const docText = view.state.doc.toString();
  const pages = inspectDraftpadPages(docText);
  if (pages.length > 0 && isWindowEmpty(pages[0].rawContent)) {
    postHaptic('edge', globalObj);
    if (typeof onBounce === 'function') onBounce();
    return false;
  }
  saveCurrentWindowMemory(view);
  const mem = getMemory(view);
  shiftWindowMemoryOnPrepend(mem, pages.length);

  // UI-06 D3 · every new page opens with today's date line; the caret waits on the empty line under it.
  const dateHead = `${formatDateLine(now)}\n\n`;
  view.dispatch({
    changes: { from: 0, to: 0, insert: dateHead + PAGE_JOINER },
    selection: { anchor: dateHead.length },
    effects: [setPageIndex.of(0), EditorView.scrollIntoView(0, { y: 'start', yMargin: 8 })],
    userEvent: 'input.page'
  });

  if (view.scrollDOM) {
    if (typeof view.scrollDOM.scrollTo === 'function') {
      view.scrollDOM.scrollTo({ top: 0, behavior: 'smooth' });
    } else {
      view.scrollDOM.scrollTop = 0;
    }
  }

  postHaptic('snap', globalObj);
  if (typeof onSnap === 'function') onSnap(0);
  return true;
}

// Derived from Spec: UI-14 (E1–E4). A swipe only moves. Past either end the same end card appears (the host draws it
// through `view.__pageEnd`, or `onEnd`), with one `edge` haptic. Leaving an empty page removes it (no text is lost).
/** Which end is ahead of a move: 'newest' (dir < 0 at page 0), 'oldest' (dir > 0 at the last page), or null. */
export function pageEndAhead(state, dir) {
  const n = pageCount(state);
  const cur = currentPage(state);
  if (dir < 0 && cur <= 0) return 'newest';
  if (dir > 0 && cur >= n - 1) return 'oldest';
  return null;
}

/** A globalObj with no message handler: postHaptic stays silent (one haptic per swipe). */
const QUIET = {};

function reachEnd(view, side, { onEnd = null, onBounce = null, globalObj } = {}) {
  postHaptic('edge', globalObj);
  if (typeof onEnd === 'function') onEnd(side);
  else if (typeof view.__pageEnd === 'function') view.__pageEnd(side);
  if (typeof onBounce === 'function') onBounce();
  return false;
}

/**
 * Left-to-right swipe: one page newer (`index - 1`). At page 0: the end card ('newest').
 * `allowCreate: true` (explicit callers only, never a swipe) keeps the old "new page at the front" for page 0 with text.
 */
export function swipeLeftToRight(view, { allowCreate = false, onSnap = null, onBounce = null, onEnd = null, globalObj } = {}) {
  if (!isPageMode(view.state)) return false;
  const pages = inspectDraftpadPages(view.state.doc.toString());
  const cur = currentPage(view.state);

  if (cur > 0) {
    if (typeof view.__pageEndClose === 'function') view.__pageEndClose();
    // UI-14 E4 · leaving an empty page removes it; the newer page is still cur - 1.
    deleteEmptyWindow(view, cur, { globalObj: QUIET });   // removes it only if it has no text and no ink; one haptic
    showPage(view, cur - 1);
    postHaptic('snap', globalObj);
    if (typeof onSnap === 'function') onSnap(cur - 1);
    return true;
  }

  if (allowCreate && !isWindowEmpty(pages[0].rawContent)) {
    return openNewWindowOnLeft(view, { onSnap, onBounce, globalObj });
  }
  return reachEnd(view, 'newest', { onEnd, onBounce, globalObj });
}

/**
 * Right-to-left swipe: one page older (`index + 1`). At the last page: the end card ('oldest').
 * Leaving an empty page removes it; the older page then takes its index.
 */
export function swipeRightToLeft(view, { onSnap = null, onBounce = null, onEnd = null, globalObj } = {}) {
  if (!isPageMode(view.state)) return false;
  const pages = inspectDraftpadPages(view.state.doc.toString());
  const cur = currentPage(view.state);

  if (cur >= pages.length - 1) return reachEnd(view, 'oldest', { onEnd, onBounce, globalObj });
  if (typeof view.__pageEndClose === 'function') view.__pageEndClose();

  // UI-14 E4 · an empty page (no text, no ink) goes; the older page slides into `cur`.
  if (isWindowEmpty(pages[cur].rawContent) && deleteEmptyWindow(view, cur, { onSnap, globalObj })) return true;
  showPage(view, cur + 1);
  postHaptic('snap', globalObj);
  if (typeof onSnap === 'function') onSnap(cur + 1);
  return true;
}

/**
 * Steps by `delta` windows (`+1` = right-to-left / older; `-1` = left-to-right / newer or new window on left).
 * Pass `{ allowCreate: false }` when a caller wants strict boundary checking without creating a new window at 0.
 */
export function stepPage(
  view,
  delta,
  { allowCreate = false, allowDeleteEmpty = true, onSnap = null, onBounce = null, globalObj } = {}
) {
  if (!isPageMode(view.state)) return false;
  if (delta < 0) {
    return swipeLeftToRight(view, { allowCreate, onSnap, onBounce, globalObj });
  }
  if (delta > 0) {
    if (allowDeleteEmpty) {
      return swipeRightToLeft(view, { onSnap, onBounce, globalObj });
    }
    const target = currentPage(view.state) + delta;
    if (target >= pageCount(view.state)) return reachEnd(view, 'oldest', { onBounce, globalObj });
    showPage(view, target);
    postHaptic('snap', globalObj);
    if (typeof onSnap === 'function') onSnap(target);
    return true;
  }
  return false;
}

// Derived from Spec: UI-06. One function per action; every gesture, control and voice phrase calls these.

/** G3 · Go straight to page `index`. */
export function goToPage(view, index, { onSnap = null, onBounce = null, globalObj } = {}) {
  const n = pageCount(view.state);
  const i = Number(index);
  if (!Number.isInteger(i) || i < 0 || i >= n) {
    postHaptic('edge', globalObj);
    if (typeof onBounce === 'function') onBounce();
    return false;
  }
  if (i !== currentPage(view.state)) showPage(view, i);
  postHaptic('snap', globalObj);
  if (typeof onSnap === 'function') onSnap(i);
  return true;
}

/** ＋ · A new empty page at the front, from any page (the front page must have text). */
export function newPage(view, { onSnap = null, onBounce = null, globalObj, now } = {}) {
  if (currentPage(view.state) !== 0) showPage(view, 0);
  return openNewWindowOnLeft(view, { onSnap, onBounce, globalObj, now });
}

/** G4 · Move page `index` to the front. Only the order changes: each page keeps its own bytes. */
export function promotePage(view, index, opts = {}) {
  if (index <= 0) return false;
  return movePage(view, index, 0, opts);
}

/** G4 · Move page `index` to position `to` (T-0089: any place, either way). Only the order changes: bytes stay. */
export function movePage(view, index, to, { onSnap = null, globalObj } = {}) {
  const text = view.state.doc.toString();
  const pages = inspectDraftpadPages(text);
  if (index < 0 || index >= pages.length) return false;
  to = Math.max(0, Math.min(pages.length - 1, to));
  if (to === index) return false;
  saveCurrentWindowMemory(view);
  const slices = pages.map(p => text.slice(p.from, p.to));
  const moved = slices.splice(index, 1)[0];
  slices.splice(to, 0, moved);
  const insert = slices.join(PAGE_JOINER);
  const from = pages[0].from;
  const end = pages[pages.length - 1].to;
  const mem = getMemory(view);
  const order = pages.map((_, i) => i).filter(i => i !== index);
  order.splice(to, 0, index);
  const cursors = new Map(), scrolls = new Map();
  order.forEach((old, dst) => {
    if (mem.cursors.has(old)) cursors.set(dst, mem.cursors.get(old));
    if (mem.scrolls.has(old)) scrolls.set(dst, mem.scrolls.get(old));
  });
  mem.cursors = cursors; mem.scrolls = scrolls;
  view.dispatch({ changes: { from, to: end, insert }, userEvent: 'move.page' });
  showPage(view, to, { preserveMemory: false });
  postHaptic('snap', globalObj);
  if (typeof onSnap === 'function') onSnap(to);
  return true;
}

/** T-0089 · Where a dragged dot lands: the slot whose centre the pointer passed. `centres` excludes nothing. */
export function dropIndex(centres, index, x) {
  let to = 0;
  centres.forEach((c, i) => { if (i !== index && x > c) to += 1; });
  return to;
}

/** S1 · { slot: pageIndex } for every `<!-- slot N -->` line. */
export function pageSlots(text) {
  const out = {};
  for (const p of inspectDraftpadPages(text)) {
    for (const line of p.rawContent.split('\n')) {
      const m = SLOT_RE.exec(line.trim());
      if (m) out[Number(m[1])] = p.index;
    }
  }
  return out;
}

/** S1/S2 · Put page `index` in `slot` (1–9), clearing that slot elsewhere and the page's old slot; null clears. */
export function setPageSlot(view, index, slot) {
  const text = view.state.doc.toString();
  const pages = inspectDraftpadPages(text);
  const page = pages[index];
  if (!page) return false;
  const n = slot == null ? null : Number(slot);
  if (n !== null && !(n >= 1 && n <= 9)) return false;
  const changes = [];
  for (const p of pages) {
    let pos = p.from;
    for (const line of p.rawContent.split('\n')) {
      const m = SLOT_RE.exec(line.trim());
      if (m && (p.index === index || Number(m[1]) === n)) {
        const end = pos + line.length;
        changes.push({ from: pos, to: Math.min(end + 1, view.state.doc.length) });
      }
      pos += line.length + 1;
    }
  }
  if (n !== null) changes.push({ from: page.from, insert: `<!-- slot ${n} -->\n` });
  if (!changes.length) return false;
  view.dispatch({ changes, userEvent: 'input.slot' });
  return true;
}

/** G6 · Go to the page in `slot`. */
export function slotPage(view, slot, opts = {}) {
  const at = pageSlots(view.state.doc.toString())[Number(slot)];
  if (at === undefined) {
    postHaptic('edge', opts.globalObj);
    if (typeof opts.onBounce === 'function') opts.onBounce();
    return false;
  }
  return goToPage(view, at, opts);
}

function pageHead(p) {
  if (!p) return '';
  const line = p.rawContent.split('\n').map(l => l.replace(CONTROL_CHARS_RE, '').trim()).find(l => l && !isMetaLine(l));
  return (line || '').slice(0, 120);
}

/** R1 · Which page to reopen on, from { index, head } saved on this device. */
export function reopenTarget(text, saved) {
  const pages = inspectDraftpadPages(text);
  if (!saved || !pages.length) return 0;
  const head = String(saved.head || '').trim();
  const at = Number(saved.index) || 0;
  // The page at its saved place still starts the same way: it is the one (pages that share a date stay apart).
  if (head && pages[at] && pageHead(pages[at]) === head.slice(0, 120)) return at;
  if (head) {
    const hit = pages.findIndex(p => pageHead(p) === head.slice(0, 120));
    if (hit !== -1) return hit;
  }
  const i = Number(saved.index) || 0;
  return Math.max(0, Math.min(pages.length - 1, i));
}

/** R1 · What to save for reopening: the current page's index and first line. */
export function reopenMemo(state) {
  const i = currentPage(state);
  const p = inspectDraftpadPages(state.doc.toString())[i];
  return { index: i, head: pageHead(p) };
}

/**
 * Computes rubber-banded horizontal drag offset matching `reference/draftpad/draftpad.swift` (`effectiveDrag`).
 * `dragX > 0`: fingers moving left-to-right.
 * `dragX < 0`: fingers moving right-to-left.
 */
// Derived from Spec: BUG-02 (A1 slop, A2 ratio). One rule for touch, Pencil, mouse and trackpad.
export const AXIS_SLOP_PX = 6;
export const AXIS_RATIO = 1.4;
export function decideAxis(dx, dy) {
  const ax = Math.abs(dx), ay = Math.abs(dy);
  if (Math.max(ax, ay) < AXIS_SLOP_PX) return null;
  return ax > ay * AXIS_RATIO ? 'h' : 'v';
}

export function computeEffectiveDrag(state, dragX, viewportWidth = 400) {
  const w = Math.max(120, Number(viewportWidth) || 400);
  let v = Number(dragX) || 0;
  // UI-14 E2 · pulling past either end rubber-bands the same (0.25x); a swipe never makes a page.
  if (v !== 0 && pageEndAhead(state, v > 0 ? -1 : 1)) v *= 0.25;
  return Math.max(-w, Math.min(w, v));
}

/** The page select-all should cover: the shown page in page mode, else the page holding the cursor. */
export function selectAllRange(state) {
  const pages = inspectDraftpadPages(state.doc.toString());
  if (pages.length <= 1) return { from: 0, to: state.doc.length };
  const i = isPageMode(state) ? currentPage(state) : pageAt(pages, state.selection.main.head);
  const p = pages[Math.min(i, pages.length - 1)];
  return { from: p.from, to: p.to };
}

/** Cmd+A: select all text on this page, not the whole file. */
export function selectPage(view) {
  const { from, to } = selectAllRange(view.state);
  view.dispatch({ selection: EditorSelection.single(from, to), userEvent: 'select', scrollIntoView: false });
  return true;
}

// Edit > Select All in the native menu runs WebKit's own select-all, which reaches CodeMirror as a selection of the
// whole file; in page mode, narrow it to the shown page.
const narrowWholeSelection = EditorState.transactionFilter.of(tr => {
  if (tr.docChanged || !tr.selection || !isPageMode(tr.startState)) return tr;
  const m = tr.selection.main;
  const len = tr.startState.doc.length;
  if (tr.selection.ranges.length !== 1 || Math.min(m.from, m.to) !== 0 || Math.max(m.from, m.to) !== len) return tr;
  const r = selectAllRange(tr.startState);
  if (r.from === 0 && r.to === len) return tr;
  return [tr, { selection: EditorSelection.single(r.from, r.to), sequential: true }];
});

export function pageModeExtension({ onSnap = null, onBounce = null } = {}) {
  return [
    pageModeField,
    narrowWholeSelection,
    Prec.highest(keymap.of([
      // UI-06 K1: no page-navigation keys; pages move by gesture and visible controls only.
      { key: 'Mod-a', run: selectPage }
    ]))
  ];
}

// Derived from Spec: BUG-31. While an ink tool is chosen the gestures (wheel, touch, Pencil edge drag, host swipe)
// never turn the page; the page bar's buttons and menu call stepPage/newPage directly and stay live.
export function setPagesLocked(view, locked) {
  if (!view) return false;
  view.__pagesLocked = !!locked;
  return view.__pagesLocked;
}

/**
 * Horizontal swipes (trackpad two-finger swipe, touch drag, Pencil/pointer drag) move the current window with the
 * fingers (`translateX` + 0.25x rubber-banding) and snap with a 220ms ease-out transition:
 * - Left-to-right (`dx > threshold`): steps left or opens a new window on the left (`<!-- page -->` at top of .md).
 * - Right-to-left (`dx < -threshold`): deletes the window if empty, else steps right.
 * Vertical scrolling stays strictly inside the current window's text.
 */
export function attachSwipePaging(
  view,
  { threshold = 36, quietMs = 350, edgePx = 28, onSnap = null, onBounce = null, onEdgeZone = null } = {}
) {
  let wheelAcc = 0;
  let wheelSpent = false;
  let wheelTimer = null;
  let axis = null;
  let wheelAxisX = 0;
  let wheelAxisY = 0;

  // Derived from Spec: BUG-02 (A6): move the whole scroller (text, selection, cursor, ink) as one, never the text alone.
  const targetEl = () => (view ? view.scrollDOM : null);
  if (view && view.dom && view.dom.style) view.dom.style.overflowX = 'hidden';
  const widthOf = () => (view && view.scrollDOM && view.scrollDOM.clientWidth ? view.scrollDOM.clientWidth : 400);

  function renderDrag(dx) {
    const el = targetEl();
    if (!el || !el.style) return 0;
    const eff = computeEffectiveDrag(view.state, dx, widthOf());
    el.style.transition = 'none';
    el.style.transform = eff === 0 ? '' : `translateX(${eff}px)`;
    return eff;
  }

  function settleDrag(dx) {
    const el = targetEl();
    const limit = Math.min(threshold, widthOf() * 0.12);
    const turn = dx >= limit ? () => swipeLeftToRight(view, { onSnap, onBounce })
      : dx <= -limit ? () => swipeRightToLeft(view, { onSnap, onBounce }) : null;
    if (!el || !el.style) { if (turn) turn(); return; }
    // UI-14 E2 · at an end the page settles back (no exit glide) and the end card appears.
    const atEnd = turn && pageEndAhead(view.state, dx > 0 ? -1 : 1);
    if (atEnd) turn();
    if (!turn || atEnd) {
      el.style.transition = 'transform 220ms cubic-bezier(0.2, 0.8, 0.2, 1)';
      el.style.transform = '';
      return;
    }
    // BUG-02 A7 glide: the old page leaves the way the fingers went (140 ms), the new page enters from the other side (220 ms).
    const reduce = typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reduce) { el.style.transition = 'none'; el.style.transform = ''; turn(); return; }
    const w = widthOf();
    const dir = dx > 0 ? 1 : -1;
    el.style.transition = 'transform 140ms cubic-bezier(0.4, 0, 1, 1)';
    el.style.transform = `translateX(${dir * w}px)`;
    setTimeout(() => {
      turn();
      el.style.transition = 'none';
      el.style.transform = `translateX(${-dir * w * 0.35}px)`;
      void el.offsetWidth;
      el.style.transition = 'transform 220ms cubic-bezier(0.2, 0.8, 0.2, 1)';
      el.style.transform = '';
    }, 140);
  }

  view.scrollDOM.addEventListener('wheel', e => {
    if (!isPageMode(view.state) || view.__nativeWheel || view.__pagesLocked) return;
    clearTimeout(wheelTimer);
    wheelTimer = setTimeout(() => {
      wheelAcc = 0;
      wheelSpent = false;
      axis = null;
      wheelAxisX = 0;
      wheelAxisY = 0;
      renderDrag(0);
    }, quietMs);

    if (axis === null) {
      wheelAxisX += e.deltaX; wheelAxisY += e.deltaY;
      axis = decideAxis(wheelAxisX, wheelAxisY);
      if (axis === null) return;
      // BUG-02 A5: the slop counts toward the swipe, so the page moves from the first pixel once it is sideways.
      if (axis === 'h') {
        const before = wheelAxisX - e.deltaX;
        wheelAcc = e.isDirectionInvertedFromDevice === false ? before : -before;
      }
    }
    if (axis === 'v') return;

    e.preventDefault();
    if (wheelSpent) return;
    // Trackpad natural scrolling: fingers moving left-to-right produces negative deltaX (`dx = -e.deltaX > 0`).
    const dx = e.isDirectionInvertedFromDevice === false ? e.deltaX : -e.deltaX;
    wheelAcc += dx;
    renderDrag(wheelAcc);

    const limit = Math.min(threshold, widthOf() * 0.12);
    if (Math.abs(wheelAcc) >= limit) {
      wheelSpent = true;
      const finalDx = wheelAcc;
      wheelAcc = 0;
      settleDrag(finalDx);
    }
  }, { passive: false });

  let touchStartX = null;
  let touchStartY = null;
  let touchAxis = null;
  view.scrollDOM.addEventListener('touchstart', e => {
    if (!isPageMode(view.state) || view.__pagesLocked || !e.touches || e.touches.length !== 1) {
      touchStartX = null;
      return;
    }
    const t = e.touches[0];
    // A touch that starts at either edge belongs to the wings (the edge swipe), never to paging.
    if (t.clientX <= edgePx || t.clientX >= widthOf() - edgePx) {
      if (typeof onEdgeZone === 'function') onEdgeZone(t.clientX <= edgePx ? 'left' : 'right');
      touchStartX = null;
      return;
    }
    touchStartX = t.clientX;
    touchStartY = t.clientY;
    touchAxis = null;
  }, { passive: true });

  view.scrollDOM.addEventListener('touchmove', e => {
    if (touchStartX === null || !e.touches || e.touches.length !== 1) return;
    const t = e.touches[0];
    const dx = t.clientX - touchStartX;
    const dy = t.clientY - touchStartY;
    if (touchAxis === null) {
      touchAxis = decideAxis(dx, dy);
    }
    if (touchAxis === 'h') {
      renderDrag(dx);
    }
  }, { passive: true });

  view.scrollDOM.addEventListener('touchend', e => {
    if (touchStartX === null || !e.changedTouches || e.changedTouches.length === 0) return;
    const t = e.changedTouches[0];
    const dx = t.clientX - touchStartX;
    const dy = t.clientY - touchStartY;
    const wasHorizontal = touchAxis === 'h' || (touchAxis === null && Math.abs(dx) >= threshold && Math.abs(dx) > Math.abs(dy) * AXIS_RATIO);
    touchStartX = null;
    touchStartY = null;
    touchAxis = null;
    if (wasHorizontal) {
      settleDrag(dx);
    } else {
      renderDrag(0);
    }
  }, { passive: true });

  view.scrollDOM.addEventListener('touchcancel', () => {
    touchStartX = null;
    touchStartY = null;
    touchAxis = null;
    renderDrag(0);
  }, { passive: true });

  // Pencil / mouse paging with Option held; the edge zones belong to the wings (UI-14 E5)
  let ptrId = null;
  let ptrStartX = null;
  let ptrStartY = null;
  let ptrAxis = null;

  view.scrollDOM.addEventListener('pointerdown', e => {
    if (!isPageMode(view.state) || view.__pagesLocked) return;
    if (e.pointerType === 'touch') return; // handled by touch listeners above
    const w = widthOf();
    const x = Number(e.clientX) || 0;
    const inEdgeZone = x <= edgePx * 1.5 || x >= w - edgePx * 1.5;
    // UI-14 E5 · a Pencil from either edge zone belongs to the wing, as a finger does (central strokes draw ink).
    // A mouse or Pencil pages only with Option held: a plain drag near the margin selects text or draws.
    if (e.pointerType !== 'mouse' && inEdgeZone) {
      if (typeof onEdgeZone === 'function') onEdgeZone(x <= edgePx * 1.5 ? 'left' : 'right');
      return;
    }
    if (!e.altKey) return;
    ptrId = e.pointerId;
    ptrStartX = x;
    ptrStartY = Number(e.clientY) || 0;
    ptrAxis = null;
  });

  view.scrollDOM.addEventListener('pointermove', e => {
    if (ptrId === null || e.pointerId !== ptrId) return;
    const dx = (Number(e.clientX) || 0) - ptrStartX;
    const dy = (Number(e.clientY) || 0) - ptrStartY;
    if (ptrAxis === null) {
      ptrAxis = decideAxis(dx, dy);
    }
    if (ptrAxis === 'h') {
      renderDrag(dx);
    }
  });

  const finishPointer = e => {
    if (ptrId === null || (e && e.pointerId !== undefined && e.pointerId !== ptrId)) return;
    const dx = e ? (Number(e.clientX) || 0) - ptrStartX : 0;
    const dy = e ? (Number(e.clientY) || 0) - ptrStartY : 0;
    const wasHorizontal =
      e && e.type !== 'pointercancel' && (ptrAxis === 'h' || (ptrAxis === null && Math.abs(dx) >= threshold && Math.abs(dx) > Math.abs(dy) * AXIS_RATIO));
    ptrId = null;
    ptrStartX = null;
    ptrStartY = null;
    ptrAxis = null;
    if (wasHorizontal) {
      settleDrag(dx);
    } else {
      renderDrag(0);
    }
  };

  view.scrollDOM.addEventListener('pointerup', finishPointer);
  view.scrollDOM.addEventListener('pointercancel', finishPointer);

  // Derived from Spec: BUG-02 A8. The Mac host reads the trackpad natively (finger down, lift, momentum ignored)
  // and drives the same drag and glide: total dx since the fingers touched (+ = fingers moved right), ended = lifted.
  view.__hostSwipe = (dx, ended) => {
    if (!isPageMode(view.state) || view.__pagesLocked) return 'off';
    const d = Number(dx) || 0;
    if (ended) settleDrag(d); else renderDrag(d);
    return 'ok';
  };

  view.scrollDOM.addEventListener('scroll', () => {
    syncPageFromScroll(view, { onSnap });
  }, { passive: true });
}
