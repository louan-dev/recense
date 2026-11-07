// Find, kept small: one field that finds as you type. Enter = next, Shift-Enter = previous, Esc = close.
// Replace stays hidden behind the ⇄ toggle.
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
  findNext,
  findPrevious,
  replaceNext,
  replaceAll
} from '@codemirror/search';
import { keymap } from '@codemirror/view';

export function openFindReplace(view) {
  openSearchPanel(view);
  return searchPanelOpen(view.state);
}

export function toggleFindReplace(view) {
  if (searchPanelOpen(view.state)) {
    closeSearchPanel(view);
    return false;
  }
  openSearchPanel(view);
  return true;
}

export function isFindReplaceOpen(state) {
  return searchPanelOpen(state);
}

/** How many matches `query` has in `state`, capped so a one-letter search on a long note stays cheap. */
export function countMatches(state, query, cap = 999) {
  if (!query.valid) return 0;
  const cur = query.getCursor(state);
  let n = 0;
  while (n <= cap && !cur.next().done) n++;
  return n;
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
  const toggle = el('button', { className: 'rc-find-toggle', type: 'button', textContent: '⇄', title: 'Replace' });
  const close = el('button', { className: 'rc-find-close', type: 'button', textContent: '✕', title: 'Close (Esc)' });
  const row = el('div', { className: 'rc-find-row' });
  row.append(find, count, toggle, close);

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
    if (!query.search) { count.textContent = ''; return; }
    const n = countMatches(view.state, query);
    count.textContent = n > 999 ? '999+' : n === 0 ? 'none' : String(n);
  }

  find.addEventListener('input', () => {
    commit();
    if (find.value) findNext(view);
    showCount();
  });
  repl.addEventListener('input', commit);
  find.addEventListener('keydown', e => {
    if (e.key === 'Enter') { e.preventDefault(); commit(); (e.shiftKey ? findPrevious : findNext)(view); }
    else if (e.key === 'Escape') { e.preventDefault(); closeSearchPanel(view); view.focus(); }
  });
  repl.addEventListener('keydown', e => {
    if (e.key === 'Enter') { e.preventDefault(); commit(); replaceNext(view); showCount(); }
    else if (e.key === 'Escape') { e.preventDefault(); closeSearchPanel(view); view.focus(); }
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
    update(u) { if (u.docChanged) showCount(); }
  };
}

export function searchExtension() {
  return [
    search({ top: true, createPanel: createFindPanel }),
    highlightSelectionMatches(),
    keymap.of([
      {
        key: 'Mod-f',
        run: view => {
          openSearchPanel(view);
          return true;
        },
        preventDefault: true
      },
      ...searchKeymap
    ])
  ];
}
