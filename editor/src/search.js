// Find, kept small: one field that finds as you type. Enter / ↓ = next, Shift-Enter / ↑ = previous, Esc = close.
// Replace stays hidden behind the ⇄ toggle.
import { EditorSelection, StateField } from '@codemirror/state';
import {
  search,
  searchKeymap,
  openSearchPanel,
  closeSearchPanel,
  searchPanelOpen,
  highlightSelectionMatches,
  SearchQuery,
  setSearchQuery,
  getSearchQuery,
  replaceNext,
  replaceAll
} from '@codemirror/search';
import { Decoration, EditorView, keymap } from '@codemirror/view';

const matchMark = Decoration.mark({ class: 'cm-searchMatch' });
const selectedMatchMark = Decoration.mark({ class: 'cm-searchMatch cm-searchMatch-selected' });

export function openFindReplace(view) {
  openSearchPanel(view);
  if (searchPanelOpen(view.state)) {
    view.dispatch({ effects: setSearchQuery.of(getSearchQuery(view.state)) });
  }
  return searchPanelOpen(view.state);
}

export function closeFindReplace(view) {
  closeSearchPanel(view);
  return searchPanelOpen(view.state);
}

export function toggleFindReplace(view) {
  if (searchPanelOpen(view.state)) {
    closeSearchPanel(view);
    return false;
  }
  openFindReplace(view);
  return true;
}

export function isFindReplaceOpen(state) {
  return searchPanelOpen(state);
}

/** Collects all match ranges `{ from, to }` for `query` in `state`, capped for responsiveness. */
export function findMatches(state, query = getSearchQuery(state), cap = 999) {
  if (!query || !query.valid) return [];
  const cur = query.getCursor(state);
  const out = [];
  while (out.length <= cap && !cur.next().done) {
    out.push({ from: cur.value.from, to: cur.value.to });
  }
  return out;
}

/** How many matches `query` has in `state`, capped so a one-letter search on a long note stays cheap. */
export function countMatches(state, query, cap = 999) {
  return findMatches(state, query, cap).length;
}

/**
 * Computes `{ index, count, label, matches }` for `state` and `query`.
 * When match 3 of 12 is selected, `label` is `"3 of 12"`.
 */
export function matchStatus(state, query = getSearchQuery(state), cap = 999) {
  if (!query || !query.search) {
    return { index: 0, count: 0, label: '', matches: [] };
  }
  const matches = findMatches(state, query, cap);
  const count = matches.length;
  if (count === 0) {
    return { index: 0, count: 0, label: 'none', matches };
  }
  const sel = state.selection.main;
  let idx = matches.findIndex(m => m.from === sel.from && m.to === sel.to);
  if (idx === -1) {
    idx = matches.findIndex(m => m.from >= sel.from);
    if (idx === -1) idx = 0;
  }
  const index = idx + 1;
  const totalStr = count > cap ? `${cap}+` : String(count);
  return {
    index,
    count,
    label: `${index} of ${totalStr}`,
    matches
  };
}

function buildSearchDecos(state) {
  const query = getSearchQuery(state);
  if (!query || !query.valid) return Decoration.none;
  const matches = findMatches(state, query);
  if (matches.length === 0) return Decoration.none;
  const sel = state.selection.main;
  return Decoration.set(
    matches.map(m =>
      (m.from === sel.from && m.to === sel.to ? selectedMatchMark : matchMark).range(m.from, m.to)
    ),
    true
  );
}

export const searchHighlightField = StateField.define({
  create(state) {
    return buildSearchDecos(state);
  },
  update(decos, tr) {
    if (
      tr.docChanged ||
      tr.selection ||
      tr.effects.some(e => e.is(setSearchQuery))
    ) {
      return buildSearchDecos(tr.state);
    }
    return decos;
  },
  provide: f => EditorView.decorations.from(f)
});

/**
 * Moves selection to a match and scrolls it into view (centered).
 * - `delta = 0`: while typing, stays on the match starting at/after `selection.main.from` so typing word-by-word
 *   expands the highlight on the same word instead of skipping ahead on each keystroke.
 * - `delta > 0`: advances to the next match (wrapping around the end).
 * - `delta < 0`: moves to the previous match (wrapping around the start).
 */
export function stepFind(view, delta = 1, { onWrap = null } = {}) {
  const query = getSearchQuery(view.state);
  if (!query || !query.valid) return null;
  const matches = findMatches(view.state, query);
  if (matches.length === 0) return null;

  const sel = view.state.selection.main;
  const exactIdx = matches.findIndex(m => m.from === sel.from && m.to === sel.to);
  let idx = 0;
  let wrapped = false;

  if (delta === 0) {
    idx = matches.findIndex(m => m.from >= sel.from);
    if (idx === -1) {
      idx = 0;
      wrapped = true;
    }
  } else if (exactIdx !== -1) {
    const raw = exactIdx + (delta > 0 ? 1 : -1);
    if (raw >= matches.length) {
      idx = 0;
      wrapped = true;
    } else if (raw < 0) {
      idx = matches.length - 1;
      wrapped = true;
    } else {
      idx = raw;
    }
  } else if (delta > 0) {
    idx = matches.findIndex(m => m.from >= sel.to);
    if (idx === -1) {
      idx = 0;
      wrapped = true;
    }
  } else {
    idx = -1;
    for (let i = matches.length - 1; i >= 0; i--) {
      if (matches[i].to <= sel.from) {
        idx = i;
        break;
      }
    }
    if (idx === -1) {
      idx = matches.length - 1;
      wrapped = true;
    }
  }

  const target = matches[idx];
  const range = EditorSelection.range(target.from, target.to);
  const scrollEffect = EditorView.scrollIntoView(range, { y: 'center' });

  view.dispatch({
    selection: EditorSelection.create([range]),
    effects: [scrollEffect],
    userEvent: 'select.search'
  });

  if (view.scrollDOM && typeof view.lineBlockAt === 'function') {
    const block = view.lineBlockAt(target.from);
    const viewHeight = view.scrollDOM.clientHeight || 0;
    const centeredTop = Math.max(0, block.top - Math.round(viewHeight / 2));
    view.scrollDOM.scrollTop = centeredTop;
  }

  if (wrapped && delta !== 0 && typeof onWrap === 'function') {
    onWrap();
  }

  const status = matchStatus(view.state, query);
  return {
    from: target.from,
    to: target.to,
    index: status.index,
    count: status.count,
    label: status.label,
    wrapped,
    scrollEffect
  };
}

function el(tag, props = {}) {
  const e = document.createElement(tag);
  Object.assign(e, props);
  return e;
}

export function createFindPanel(view) {
  const dom = el('div', { className: 'rc-find' });
  const find = el('input', { className: 'rc-find-input', type: 'search', placeholder: 'Find', spellcheck: false });
  find.setAttribute('main-field', 'true');
  find.setAttribute('aria-label', 'Find');
  const count = el('span', { className: 'rc-find-count' });
  const prevBtn = el('button', {
    className: 'rc-find-btn rc-find-prev',
    type: 'button',
    textContent: '↑',
    title: 'Previous match (Shift-Enter)',
    ariaLabel: 'Previous match'
  });
  const nextBtn = el('button', {
    className: 'rc-find-btn rc-find-next',
    type: 'button',
    textContent: '↓',
    title: 'Next match (Enter)',
    ariaLabel: 'Next match'
  });
  const toggle = el('button', { className: 'rc-find-toggle', type: 'button', textContent: '⇄', title: 'Replace' });
  const close = el('button', { className: 'rc-find-close', type: 'button', textContent: '✕', title: 'Close (Esc)' });
  const row = el('div', { className: 'rc-find-row' });
  row.append(find, count, prevBtn, nextBtn, toggle, close);

  const replaceRow = el('div', { className: 'rc-find-row rc-find-replace', hidden: true });
  const repl = el('input', { className: 'rc-find-input', placeholder: 'Replace with', spellcheck: false });
  repl.setAttribute('aria-label', 'Replace with');
  const one = el('button', { className: 'rc-find-btn', type: 'button', textContent: 'Replace' });
  const all = el('button', { className: 'rc-find-btn', type: 'button', textContent: 'All' });
  replaceRow.append(repl, one, all);
  dom.append(row, replaceRow);

  const q = getSearchQuery(view.state);
  find.value = q.search;
  repl.value = q.replace;

  function commit() {
    const query = new SearchQuery({ search: find.value, replace: repl.value, caseSensitive: false });
    if (!query.eq(getSearchQuery(view.state))) view.dispatch({ effects: setSearchQuery.of(query) });
    return query;
  }
  function showCount() {
    const query = getSearchQuery(view.state);
    count.textContent = matchStatus(view.state, query).label;
  }

  find.addEventListener('input', () => {
    const query = commit();
    if (query.valid) stepFind(view, 0);
    showCount();
  });
  repl.addEventListener('input', commit);
  find.addEventListener('keydown', e => {
    if (e.key === 'Enter') {
      e.preventDefault();
      commit();
      stepFind(view, e.shiftKey ? -1 : 1);
      showCount();
    } else if (e.key === 'ArrowDown') {
      e.preventDefault();
      commit();
      stepFind(view, 1);
      showCount();
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      commit();
      stepFind(view, -1);
      showCount();
    } else if (e.key === 'Escape') {
      e.preventDefault();
      closeSearchPanel(view);
      view.focus();
    }
  });
  repl.addEventListener('keydown', e => {
    if (e.key === 'Enter') { e.preventDefault(); commit(); replaceNext(view); showCount(); }
    else if (e.key === 'Escape') { e.preventDefault(); closeSearchPanel(view); view.focus(); }
  });
  prevBtn.addEventListener('click', () => {
    commit();
    stepFind(view, -1);
    showCount();
  });
  nextBtn.addEventListener('click', () => {
    commit();
    stepFind(view, 1);
    showCount();
  });
  toggle.addEventListener('click', () => {
    replaceRow.hidden = !replaceRow.hidden;
    toggle.setAttribute('aria-pressed', String(!replaceRow.hidden));
    (replaceRow.hidden ? find : repl).focus();
  });
  close.addEventListener('click', () => { closeSearchPanel(view); view.focus(); });
  one.addEventListener('click', () => { commit(); replaceNext(view); showCount(); });
  all.addEventListener('click', () => { commit(); replaceAll(view); showCount(); });

  return {
    dom,
    top: true,
    mount() { find.focus(); find.select(); showCount(); },
    update(u) {
      if (
        u.docChanged ||
        u.selectionSet ||
        u.transactions.some(tr => tr.effects.some(e => e.is(setSearchQuery)))
      ) {
        showCount();
      }
    }
  };
}

export function searchExtension() {
  return [
    search({
      top: true,
      createPanel: createFindPanel,
      scrollToMatch: r => EditorView.scrollIntoView(r, { y: 'center' })
    }),
    searchHighlightField,
    highlightSelectionMatches(),
    keymap.of([
      {
        key: 'Mod-f',
        run: view => {
          openFindReplace(view);
          return true;
        },
        preventDefault: true
      },
      ...searchKeymap
    ])
  ];
}
