// Page mode: the old Draftpad navigation inside the new editor. One page fills the view; the rest of the file is
// hidden (not removed), so the document stays one string. Page 0 is the top of the file (the newest page once the
// file is newest-first). Two fingers left / ⌘] go one page deeper; two fingers right / ⌘[ go back toward the top.
import { StateField, StateEffect, Prec } from '@codemirror/state';
import { Decoration, EditorView, keymap } from '@codemirror/view';
import { inspectDraftpadPages } from './pages.js';

export const setPageMode = StateEffect.define();
export const setPageIndex = StateEffect.define();

function pageAt(pages, pos) {
  for (let i = 0; i < pages.length; i++) {
    const next = pages[i + 1];
    if (!next || pos < next.from) return i;
  }
  return Math.max(0, pages.length - 1);
}

/** Ranges hidden around page `index`, each covering whole lines, so they can be block-replaced. */
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

function build(state, value) {
  if (!value.on) return Decoration.none;
  const ranges = hiddenRanges(state.doc.toString(), value.index);
  return Decoration.set(ranges.map(r => Decoration.replace({ block: true }).range(r.from, r.to)));
}

export const pageModeField = StateField.define({
  create(state) {
    const value = { on: true, index: 0 };
    return { ...value, decos: build(state, value) };
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
    // The cursor went to another page (search, a jump from the outline, arrows past the edge): follow it.
    if (on && tr.selection && !tr.effects.some(e => e.is(setPageIndex))) {
      const at = pageAt(pages, tr.state.selection.main.head);
      if (at !== index) index = at;
    }
    if (on === v.on && index === v.index && !tr.docChanged) return v;
    const value = { on, index };
    return { ...value, decos: build(tr.state, value) };
  },
  provide: f => EditorView.decorations.from(f, v => v.decos)
});

export function currentPage(state) {
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

/** Shows page `index` with the cursor at its start. */
export function showPage(view, index) {
  const pages = inspectDraftpadPages(view.state.doc.toString());
  const i = Math.max(0, Math.min(pages.length - 1, index));
  view.dispatch({
    selection: { anchor: pages[i].from },
    effects: [setPageIndex.of(i), EditorView.scrollIntoView(pages[i].from, { y: 'start' })]
  });
  view.scrollDOM.scrollTop = 0;
  return i;
}

/** One page deeper (+1) or back toward the top (-1). Returns false at either end (the host bounces). */
export function stepPage(view, delta) {
  if (!isPageMode(view.state)) return false;
  const target = currentPage(view.state) + delta;
  if (target < 0 || target >= pageCount(view.state)) return false;
  showPage(view, target);
  return true;
}

export function pageModeExtension() {
  return [
    pageModeField,
    Prec.highest(keymap.of([
      { key: 'Mod-]', run: v => { stepPage(v, 1); return true; } },
      { key: 'Mod-[', run: v => { stepPage(v, -1); return true; } }
    ]))
  ];
}

/**
 * Two-finger horizontal swipes page through the note. One page per swipe: the gesture is spent until the wheel has
 * been quiet for a moment, so momentum can't skip pages. Fingers left (deltaX > 0) go deeper.
 */
export function attachSwipePaging(view, { threshold = 60, quietMs = 350, onBounce = null } = {}) {
  let acc = 0;
  let spent = false;
  let timer = null;
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
      const moved = stepPage(view, acc > 0 ? 1 : -1);
      if (!moved && typeof onBounce === 'function') onBounce();
    }
  }, { passive: false });
}
