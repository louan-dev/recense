// Continuous-scroll pages: every page stays visible in one continuous scroll with a thin divider between pages.
// Two-finger horizontal swipes, horizontal touch swipes, or ⌘] / ⌘[ glide the next or previous page's date heading
// to the top without locking vertical scroll. `currentPage` tracks both cursor jumps and scroll position.
import { StateField, StateEffect, Prec } from '@codemirror/state';
import { Decoration, EditorView, keymap } from '@codemirror/view';
import { inspectDraftpadPages } from './pages.js';
import { postHaptic } from './bridge.js';

export const setPageMode = StateEffect.define();
export const setPageIndex = StateEffect.define();

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

/** Legacy helper computing line ranges outside page `index` (kept for pure range calculation tests). */
export function hiddenRanges(text, index) {
  const pages = inspectDraftpadPages(text);
  if (pages.length <= 1) return [];
  const i = Math.max(0, Math.min(pages.length - 1, index));
  const { from, to } = pages[i];
  const out = [];
  if (from > 0) out.push({ from: 0, to: from - 1 });
  if (to < text.length) out.push({ from: to + 1, to: text.length });
  return out.filter(r => r.to >= r.from);
}

export const pageModeField = StateField.define({
  create() {
    return { on: true, index: 0, decos: Decoration.none };
  },
  update(v, tr) {
    let on = v.on;
    let index = v.index;
    for (const e of tr.effects) {
      if (e.is(setPageMode)) on = Boolean(e.value);
      if (e.is(setPageIndex)) index = e.value;
    }
    const pages = inspectDraftpadPages(tr.state.doc.toString());
    index = Math.max(0, Math.min(pages.length - 1, index));
    // When the cursor moves to another page (search, outline jump, arrows), follow it.
    if (on && tr.selection && !tr.effects.some(e => e.is(setPageIndex))) {
      const at = pageAt(pages, tr.state.selection.main.head);
      if (at !== index) index = at;
    }
    if (on === v.on && index === v.index) return v;
    return { on, index, decos: Decoration.none };
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

/**
 * Updates `currentPage` from `view.scrollDOM.scrollTop` so continuous scrolling keeps the active page in sync.
 */
export function syncPageFromScroll(view, { onSnap = null, globalObj } = {}) {
  if (!view || !view.scrollDOM || typeof view.lineBlockAtHeight !== 'function') {
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

/** Glides page `index`'s date heading to the top and places the cursor at its start. */
export function showPage(view, index) {
  const pages = inspectDraftpadPages(view.state.doc.toString());
  const i = Math.max(0, Math.min(pages.length - 1, index));
  const targetPos = pageHeadingOffset(view.state.doc, pages[i]);
  view.dispatch({
    selection: { anchor: targetPos },
    effects: [setPageIndex.of(i), EditorView.scrollIntoView(targetPos, { y: 'start', yMargin: 8 })]
  });
  if (view.scrollDOM) {
    const targetTop =
      i === 0
        ? 0
        : typeof view.lineBlockAt === 'function'
          ? Math.max(0, view.lineBlockAt(targetPos).top)
          : i * 240;
    // Setting scrollTop right after a smooth scrollTo cancels the glide: set it only where scrollTo is missing.
    if (typeof view.scrollDOM.scrollTo === 'function') {
      view.scrollDOM.scrollTo({ top: targetTop, behavior: 'smooth' });
    } else {
      view.scrollDOM.scrollTop = targetTop;
    }
  }
  return i;
}

/** One page deeper (+1) or back toward the top (-1). Returns false at either end. */
export function stepPage(view, delta, { onSnap = null, onBounce = null, globalObj } = {}) {
  if (!isPageMode(view.state)) return false;
  const target = currentPage(view.state) + delta;
  if (target < 0 || target >= pageCount(view.state)) {
    postHaptic('edge', globalObj);
    if (typeof onBounce === 'function') onBounce();
    return false;
  }
  showPage(view, target);
  postHaptic('snap', globalObj);
  if (typeof onSnap === 'function') onSnap(target);
  return true;
}

export function pageModeExtension({ onSnap = null, onBounce = null } = {}) {
  return [
    pageModeField,
    Prec.highest(keymap.of([
      { key: 'Mod-]', run: v => { stepPage(v, 1, { onSnap, onBounce }); return true; } },
      { key: 'Mod-[', run: v => { stepPage(v, -1, { onSnap, onBounce }); return true; } }
    ]))
  ];
}

/**
 * Horizontal swipes (two-finger trackpad `deltaX` or touch swipe away from the left edge) glide between pages,
 * while vertical scrolling remains continuous and unlocked and updates `currentPage` from the scroll position.
 */
export function attachSwipePaging(
  view,
  { threshold = 60, quietMs = 350, edgePx = 28, onSnap = null, onBounce = null } = {}
) {
  let acc = 0;
  let spent = false;
  let timer = null;
  let suppressScrollUntil = 0;

  const stepWithGlide = delta => {
    suppressScrollUntil = Date.now() + 380;
    return stepPage(view, delta, { onSnap, onBounce });
  };

  view.scrollDOM.addEventListener('wheel', e => {
    if (!isPageMode(view.state)) return;
    if (Math.abs(e.deltaX) <= Math.abs(e.deltaY)) return;
    e.preventDefault();
    clearTimeout(timer);
    timer = setTimeout(() => { acc = 0; spent = false; }, quietMs);
    if (spent) return;
    acc += e.deltaX;
    if (Math.abs(acc) >= threshold) {
      spent = true;
      stepWithGlide(acc > 0 ? 1 : -1);
    }
  }, { passive: false });

  let touchStartX = null;
  let touchStartY = null;
  view.scrollDOM.addEventListener('touchstart', e => {
    if (!isPageMode(view.state) || !e.touches || e.touches.length !== 1) {
      touchStartX = null;
      return;
    }
    const t = e.touches[0];
    // Leave left-edge swipes for summoning the outline.
    if (t.clientX <= edgePx) {
      touchStartX = null;
      return;
    }
    touchStartX = t.clientX;
    touchStartY = t.clientY;
  }, { passive: true });

  view.scrollDOM.addEventListener('touchend', e => {
    if (touchStartX === null || !e.changedTouches || e.changedTouches.length === 0) return;
    const t = e.changedTouches[0];
    const dx = t.clientX - touchStartX;
    const dy = t.clientY - touchStartY;
    touchStartX = null;
    touchStartY = null;
    if (Math.abs(dx) >= threshold && Math.abs(dx) > Math.abs(dy) * 1.4) {
      stepWithGlide(dx < 0 ? 1 : -1);
    }
  }, { passive: true });

  view.scrollDOM.addEventListener('scroll', () => {
    if (Date.now() < suppressScrollUntil) return;
    syncPageFromScroll(view, { onSnap });
  }, { passive: true });
}
