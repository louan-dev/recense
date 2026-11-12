// Isolated mini-document windows (restoring old Draftpad navigation, reference/draftpad):
// - Each window is a mini document: hiddenRanges + Decoration.replace({ block: true }) hides all other pages so
//   vertical scrolling stays strictly inside the current window's text and never crosses into another topic.
// - Left-to-right swipe (or stepPage(view, -1) / swipeLeftToRight(view)): steps one window left toward index 0;
//   when already at index 0 and window 0 has text, opens a new window on the left by prepending a `<!-- page -->`
//   block at the top of the .md file.
// - Right-to-left swipe (or stepPage(view, 1) / swipeRightToLeft(view)): if the current window's text is empty
//   (and there is more than 1 window), deletes that window and removes its `<!-- page -->` block from the .md file;
//   otherwise steps one window right toward older topics.
// - Per-window cursor and vertical scroll memory, plus live finger-follow drag with 0.25x rubber-banding and
//   220ms ease-out snap.
import { StateField, StateEffect, Prec, EditorState, EditorSelection } from '@codemirror/state';
import { Decoration, EditorView, keymap } from '@codemirror/view';
import { PAGE_JOINER, inspectDraftpadPages, isWindowEmpty } from './pages.js';
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
export function openNewWindowOnLeft(view, { onSnap = null, onBounce = null, globalObj } = {}) {
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

  view.dispatch({
    changes: { from: 0, to: 0, insert: PAGE_JOINER },
    selection: { anchor: 0 },
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

/**
 * Left-to-right swipe: moves one window left (`index - 1`); if already at window 0 and window 0 has text,
 * opens a new window on the left (new `<!-- page -->` block at the top of the .md file).
 */
export function swipeLeftToRight(view, { allowCreate = true, onSnap = null, onBounce = null, globalObj } = {}) {
  if (!isPageMode(view.state)) return false;
  const pages = inspectDraftpadPages(view.state.doc.toString());
  const cur = currentPage(view.state);

  // If leaving a trailing empty window on the right, clean it up just like reference/draftpad.swift finishSettle().
  if (cur > 0 && cur === pages.length - 1 && isWindowEmpty(pages[cur].rawContent)) {
    return deleteEmptyWindow(view, cur, { onSnap, globalObj });
  }

  if (cur > 0) {
    showPage(view, cur - 1);
    postHaptic('snap', globalObj);
    if (typeof onSnap === 'function') onSnap(cur - 1);
    return true;
  }

  if (allowCreate && !isWindowEmpty(pages[0].rawContent)) {
    return openNewWindowOnLeft(view, { onSnap, onBounce, globalObj });
  }

  postHaptic('edge', globalObj);
  if (typeof onBounce === 'function') onBounce();
  return false;
}

/**
 * Right-to-left swipe: if the current window's text is empty (and there is more than 1 window), deletes that window
 * and removes its `<!-- page -->` block from the .md file; otherwise steps one window right (`index + 1`).
 */
export function swipeRightToLeft(view, { onSnap = null, onBounce = null, globalObj } = {}) {
  if (!isPageMode(view.state)) return false;
  const pages = inspectDraftpadPages(view.state.doc.toString());
  const cur = currentPage(view.state);

  if (pages.length > 1 && isWindowEmpty(pages[cur].rawContent)) {
    return deleteEmptyWindow(view, cur, { onSnap, globalObj });
  }

  if (cur < pages.length - 1) {
    showPage(view, cur + 1);
    postHaptic('snap', globalObj);
    if (typeof onSnap === 'function') onSnap(cur + 1);
    return true;
  }

  postHaptic('edge', globalObj);
  if (typeof onBounce === 'function') onBounce();
  return false;
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
    if (target >= pageCount(view.state)) {
      postHaptic('edge', globalObj);
      if (typeof onBounce === 'function') onBounce();
      return false;
    }
    showPage(view, target);
    postHaptic('snap', globalObj);
    if (typeof onSnap === 'function') onSnap(target);
    return true;
  }
  return false;
}

/**
 * Computes rubber-banded horizontal drag offset matching `reference/draftpad/draftpad.swift` (`effectiveDrag`).
 * `dragX > 0`: fingers moving left-to-right.
 * `dragX < 0`: fingers moving right-to-left.
 */
// Derived from Spec: BUG-02 (A1 slop, A2 ratio). One rule for touch, Pencil, mouse and trackpad.
export const AXIS_SLOP_PX = 12;
export const AXIS_RATIO = 1.4;
export function decideAxis(dx, dy) {
  const ax = Math.abs(dx), ay = Math.abs(dy);
  if (Math.max(ax, ay) < AXIS_SLOP_PX) return null;
  return ax > ay * AXIS_RATIO ? 'h' : 'v';
}

export function computeEffectiveDrag(state, dragX, viewportWidth = 400) {
  const w = Math.max(120, Number(viewportWidth) || 400);
  const pages = inspectDraftpadPages(state.doc.toString());
  const idx = currentPage(state);
  const curEmpty = isWindowEmpty(pages[idx] ? pages[idx].rawContent : '');
  let v = Number(dragX) || 0;
  // Pulling left-to-right at index 0 when index 0 is already empty cannot open another blank window -> rubber-band
  if (v > 0 && idx <= 0 && curEmpty) v *= 0.25;
  // Pulling right-to-left at the rightmost window when it is non-empty (or only 1 window) -> rubber-band
  if (v < 0 && idx >= pages.length - 1 && (!curEmpty || pages.length <= 1)) v *= 0.25;
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
      { key: 'Mod-a', run: selectPage },
      { key: 'Mod-]', run: v => { swipeRightToLeft(v, { onSnap, onBounce }); return true; } },
      { key: 'Mod-[', run: v => { swipeLeftToRight(v, { allowCreate: true, onSnap, onBounce }); return true; } }
    ]))
  ];
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
  { threshold = 60, quietMs = 350, edgePx = 28, onSnap = null, onBounce = null, onEdgeZone = null } = {}
) {
  let wheelAcc = 0;
  let wheelSpent = false;
  let wheelTimer = null;
  let axis = null;
  let wheelAxisX = 0;
  let wheelAxisY = 0;

  const targetEl = () => (view && view.contentDOM ? view.contentDOM : view ? view.scrollDOM : null);
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
    const limit = Math.min(threshold, widthOf() * 0.2);
    if (dx >= limit) {
      swipeLeftToRight(view, { allowCreate: true, onSnap, onBounce });
    } else if (dx <= -limit) {
      swipeRightToLeft(view, { onSnap, onBounce });
    }
    if (el && el.style) {
      el.style.transition = 'transform 220ms cubic-bezier(0.2, 0.8, 0.2, 1)';
      el.style.transform = 'translateX(0px)';
    }
  }

  view.scrollDOM.addEventListener('wheel', e => {
    if (!isPageMode(view.state)) return;
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
    }
    if (axis === 'v') return;

    e.preventDefault();
    if (wheelSpent) return;
    // Trackpad natural scrolling: fingers moving left-to-right produces negative deltaX (`dx = -e.deltaX > 0`).
    const dx = e.isDirectionInvertedFromDevice === false ? e.deltaX : -e.deltaX;
    wheelAcc += dx;
    renderDrag(wheelAcc);

    const limit = Math.min(threshold, widthOf() * 0.2);
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
    if (!isPageMode(view.state) || !e.touches || e.touches.length !== 1) {
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

  // Apple Pencil / pointer edge-swipe navigation (hand-neutral left or right edge zone)
  let ptrId = null;
  let ptrStartX = null;
  let ptrStartY = null;
  let ptrAxis = null;

  view.scrollDOM.addEventListener('pointerdown', e => {
    if (!isPageMode(view.state)) return;
    if (e.pointerType === 'touch') return; // handled by touch listeners above
    const w = widthOf();
    const x = Number(e.clientX) || 0;
    const inEdgeZone = x <= edgePx * 1.5 || x >= w - edgePx * 1.5;
    // Pencil pages from either edge zone (central strokes draw ink). A mouse pages only with
    // Option held: a plain mouse drag near the margin is selecting text, never turning the page.
    if (e.pointerType === 'mouse' ? !e.altKey : !inEdgeZone && !e.altKey) return;
    if (typeof onEdgeZone === 'function') onEdgeZone(x <= edgePx * 1.5 ? 'left' : 'right');
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

  view.scrollDOM.addEventListener('scroll', () => {
    syncPageFromScroll(view, { onSnap });
  }, { passive: true });
}
