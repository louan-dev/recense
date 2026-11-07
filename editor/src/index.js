import { EditorState } from '@codemirror/state';
import { EditorView, keymap, drawSelection, highlightActiveLine } from '@codemirror/view';
import { defaultKeymap, history, historyKeymap } from '@codemirror/commands';
import { markdown } from '@codemirror/lang-markdown';
import { pageMarkersExtension } from './pages.js';
import {
  extractHeadings,
  orderPagesForOutline,
  headingFoldExtension,
  isHeadingFolded,
  toggleHeadingFold,
  jumpToOffset
} from './outline.js';
import {
  searchExtension,
  openFindReplace,
  toggleFindReplace,
  isFindReplaceOpen
} from './search.js';
import { legalNumberingExtension } from './legal.js';
import { createEditorBridge } from './bridge.js';
import { removedRecordExtension, getRemoved } from './removed.js';
import {
  pageModeExtension,
  attachSwipePaging,
  stepPage,
  showPage,
  currentPage,
  isPageMode,
  setPageMode,
  pageCount
} from './pagemode.js';
import { embedsExtension } from './embeds.js';
import { linksExtension } from './links.js';
import {
  DEFAULT_FONT_SIZE,
  createThemeCompartments,
  buildThemeExtension,
  buildFontSizeExtension,
  normalizeThemeName,
  normalizeFontSize
} from './theme.js';

export function createEditorExtensions({
  theme = 'dark',
  fontSize = DEFAULT_FONT_SIZE,
  compartments = createThemeCompartments(),
  onUpdate = null,
  onOpenFind = null,
  extraExtensions = []
} = {}) {
  const extensions = [
    EditorState.lineSeparator.of('\n'),
    history(),
    drawSelection(),
    highlightActiveLine(),
    EditorView.lineWrapping,
    markdown(),
    searchExtension({ onOpen: onOpenFind }),
    headingFoldExtension(),
    legalNumberingExtension(),
    removedRecordExtension(),
    keymap.of([...defaultKeymap, ...historyKeymap]),
    pageMarkersExtension(),
    pageModeExtension(),
    embedsExtension(),
    linksExtension(),
    compartments.theme.of(buildThemeExtension(theme)),
    compartments.fontSize.of(buildFontSizeExtension(fontSize)),
    ...extraExtensions
  ];

  if (typeof onUpdate === 'function') {
    extensions.push(EditorView.updateListener.of(onUpdate));
  }

  return {
    compartments,
    extensions
  };
}

export function createEditorState(doc = '', options = {}) {
  const { compartments, extensions } = createEditorExtensions(options);
  const state = EditorState.create({
    doc,
    extensions
  });
  return { state, compartments };
}

export function mountEditor(root = document.body, initialDoc = '') {
  let currentTheme = 'dark';
  let currentFontSize = DEFAULT_FONT_SIZE;
  let newestFirst = false;
  let outlineVisible = false;

  const shell = document.createElement('div');
  shell.className = 'rc-shell';

  const toolbar = document.createElement('header');
  toolbar.className = 'rc-toolbar';

  const leftGroup = document.createElement('div');
  leftGroup.className = 'rc-toolbar-group';

  const outlineToggleBtn = document.createElement('button');
  outlineToggleBtn.type = 'button';
  outlineToggleBtn.className = 'rc-btn';
  outlineToggleBtn.id = 'rc-outline-toggle-btn';
  outlineToggleBtn.setAttribute('aria-pressed', 'false');
  outlineToggleBtn.textContent = 'Outline';

  const pagesBtn = document.createElement('button');
  pagesBtn.type = 'button';
  pagesBtn.className = 'rc-btn';
  pagesBtn.id = 'rc-pages-btn';
  pagesBtn.setAttribute('aria-pressed', 'true');
  pagesBtn.title = 'One page at a time (two fingers left / right, ⌘] / ⌘[); off = one long scroll';
  pagesBtn.textContent = 'Pages';

  const searchBtn = document.createElement('button');
  searchBtn.type = 'button';
  searchBtn.className = 'rc-btn';
  searchBtn.id = 'rc-search-btn';
  searchBtn.setAttribute('aria-pressed', 'false');
  searchBtn.title = 'Find (⌘F)';
  searchBtn.textContent = 'Search';

  leftGroup.append(outlineToggleBtn, pagesBtn, searchBtn);

  const rightGroup = document.createElement('div');
  rightGroup.className = 'rc-toolbar-group';

  const themeBtn = document.createElement('button');
  themeBtn.type = 'button';
  themeBtn.className = 'rc-btn';
  themeBtn.id = 'rc-theme-btn';
  themeBtn.textContent = 'Light';

  rightGroup.appendChild(themeBtn);
  toolbar.append(leftGroup, rightGroup);

  const workspace = document.createElement('div');
  workspace.className = 'rc-workspace';

  const outlinePanel = document.createElement('aside');
  outlinePanel.className = 'rc-outline';
  outlinePanel.id = 'rc-outline-panel';
  outlinePanel.setAttribute('aria-label', 'Document Outline');
  outlinePanel.hidden = true;

  const outlineHeader = document.createElement('div');
  outlineHeader.className = 'rc-outline-header';

  const outlineTitle = document.createElement('span');
  outlineTitle.textContent = 'Outline';

  const newestFirstBtn = document.createElement('button');
  newestFirstBtn.type = 'button';
  newestFirstBtn.className = 'rc-btn';
  newestFirstBtn.id = 'rc-newest-first-btn';
  newestFirstBtn.setAttribute('aria-pressed', 'false');
  newestFirstBtn.textContent = 'Newest first';

  outlineHeader.append(outlineTitle, newestFirstBtn);

  const outlineList = document.createElement('div');
  outlineList.className = 'rc-outline-list';
  outlineList.id = 'rc-outline-list';

  outlinePanel.append(outlineHeader, outlineList);

  const editorHost = document.createElement('main');
  editorHost.className = 'rc-editor-Mount';
  workspace.append(outlinePanel, editorHost);

  shell.append(toolbar, workspace);
  root.innerHTML = '';
  root.appendChild(shell);

  let view = null;
  let bridge = null;

  function renderHeadingRow(h) {
    const row = document.createElement('div');
    row.className = 'rc-outline-item';
    row.style.paddingLeft = `${Math.max(0, (h.level - 1) * 12)}px`;

    const foldBtn = document.createElement('button');
    foldBtn.type = 'button';
    foldBtn.className = 'rc-outline-fold-btn';
    const foldable = h.foldFrom !== null && h.foldTo !== null;
    if (foldable && view) {
      const folded = isHeadingFolded(view.state, h);
      foldBtn.textContent = folded ? '▸' : '▾';
      foldBtn.title = folded ? 'Unfold heading' : 'Fold heading';
      foldBtn.addEventListener('click', e => {
        e.stopPropagation();
        toggleHeadingFold(view, h);
        renderOutline();
      });
    } else {
      foldBtn.textContent = '·';
      foldBtn.disabled = true;
    }

    const jumpBtn = document.createElement('button');
    jumpBtn.type = 'button';
    jumpBtn.className = 'rc-outline-jump-btn';
    jumpBtn.textContent = h.kind === 'section' ? `§ ${h.title}` : h.title;
    jumpBtn.addEventListener('click', () => {
      if (view) jumpToOffset(view, h.from);
      hideOutline();
    });

    row.append(foldBtn, jumpBtn);
    return row;
  }

  function renderOutline() {
    if (!view) return;
    const docText = view.state.doc.toString();
    outlineList.innerHTML = '';

    if (newestFirst) {
      const orderedPages = orderPagesForOutline(docText, { newestFirst: true });
      if (orderedPages.length === 0) {
        const empty = document.createElement('div');
        empty.className = 'rc-outline-empty';
        empty.textContent = 'No pages yet';
        outlineList.appendChild(empty);
        return;
      }
      for (const page of orderedPages) {
        const pageBlock = document.createElement('div');
        pageBlock.className = 'rc-outline-page';

        const pageBtn = document.createElement('button');
        pageBtn.type = 'button';
        pageBtn.className = 'rc-outline-page-btn';
        pageBtn.textContent = page.dateLine || page.title;
        pageBtn.addEventListener('click', () => {
          jumpToOffset(view, page.from);
          hideOutline();
        });
        pageBlock.appendChild(pageBtn);

        for (const h of page.headings) {
          pageBlock.appendChild(renderHeadingRow(h));
        }
        outlineList.appendChild(pageBlock);
      }
      return;
    }

    const headings = extractHeadings(docText);
    const pages = orderPagesForOutline(docText, { newestFirst: false });
    if (headings.length === 0 && pages.length <= 1) {
      const empty = document.createElement('div');
      empty.className = 'rc-outline-empty';
      empty.textContent = 'No headings yet';
      outlineList.appendChild(empty);
      return;
    }

    if (pages.length > 1) {
      for (const page of pages) {
        const pageBlock = document.createElement('div');
        pageBlock.className = 'rc-outline-page';

        const pageBtn = document.createElement('button');
        pageBtn.type = 'button';
        pageBtn.className = 'rc-outline-page-btn';
        pageBtn.textContent = page.dateLine || page.title;
        pageBtn.addEventListener('click', () => {
          jumpToOffset(view, page.from);
          hideOutline();
        });
        pageBlock.appendChild(pageBtn);

        for (const h of page.headings) {
          pageBlock.appendChild(renderHeadingRow(h));
        }
        outlineList.appendChild(pageBlock);
      }
    } else {
      for (const h of headings) {
        outlineList.appendChild(renderHeadingRow(h));
      }
    }
  }

  const { state, compartments } = createEditorState(initialDoc, {
    theme: currentTheme,
    fontSize: currentFontSize,
    onOpenFind: () => hideOutline(),
    onUpdate(update) {
      const findOpen = isFindReplaceOpen(update.state);
      searchBtn.setAttribute('aria-pressed', String(findOpen));
      if (findOpen && outlineVisible) {
        hideOutline();
      }
      if (update.docChanged) {
        if (bridge) bridge.notifyDocChanged(update.transactions);
      }
      if (update.docChanged || update.transactions.some(tr => tr.effects.length > 0)) {
        renderOutline();
      }
    }
  });

  view = new EditorView({
    state,
    parent: editorHost
  });

  // At the first or last page a swipe bounces; the host plays its bounce so it feels like the old strip.
  attachSwipePaging(view, {
    onBounce: () => {
      const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ui;
      if (h) h.postMessage('bounce');
    }
  });

  function hideOutline() {
    outlineVisible = false;
    outlinePanel.hidden = true;
    outlineToggleBtn.setAttribute('aria-pressed', 'false');
  }

  function setPages(on) {
    view.dispatch({ effects: setPageMode.of(Boolean(on)) });
    pagesBtn.setAttribute('aria-pressed', String(isPageMode(view.state)));
    if (on) showPage(view, currentPage(view.state));
  }

  /** Puts `text` on a new line under the cursor's line, as your own edit (it saves like typing). */
  function insertBlock(text) {
    const line = view.state.doc.lineAt(view.state.selection.main.head);
    const insert = `\n${String(text ?? '')}`;
    view.dispatch({
      changes: { from: line.to, insert },
      selection: { anchor: line.to + insert.length },
      scrollIntoView: true,
      userEvent: 'input'
    });
  }

  /** Places the cursor at `offset` (clamped), shows its page, and focuses the editor. */
  function setCursor(offset) {
    const at = Math.max(0, Math.min(view.state.doc.length, Number(offset) || 0));
    view.dispatch({ selection: { anchor: at }, scrollIntoView: true });
    view.focus();
  }

  function setTheme(mode) {
    currentTheme = normalizeThemeName(mode);
    if (typeof document !== 'undefined' && document.documentElement) {
      document.documentElement.setAttribute('data-theme', currentTheme);
    }
    themeBtn.textContent = currentTheme === 'dark' ? 'Light' : 'Dark';
    view.dispatch({
      effects: compartments.theme.reconfigure(buildThemeExtension(currentTheme))
    });
  }

  function setFontSize(px) {
    currentFontSize = normalizeFontSize(px);
    if (typeof document !== 'undefined' && document.documentElement) {
      document.documentElement.style.setProperty('--rc-font-size', `${currentFontSize}px`);
    }
    view.dispatch({
      effects: compartments.fontSize.reconfigure(buildFontSizeExtension(currentFontSize))
    });
  }

  function setNewestFirst(flag) {
    newestFirst = Boolean(flag);
    newestFirstBtn.setAttribute('aria-pressed', String(newestFirst));
    renderOutline();
  }

  bridge = createEditorBridge({
    getState: () => (view ? view.state : null),
    dispatch: spec => {
      if (view) view.dispatch(spec);
    },
    focusView: () => {
      if (view) view.focus();
    },
    getScroll: () =>
      view && view.scrollDOM
        ? { top: view.scrollDOM.scrollTop, left: view.scrollDOM.scrollLeft }
        : null,
    setScroll: pos => {
      if (view && view.scrollDOM && pos) {
        view.scrollDOM.scrollTop = pos.top;
        view.scrollDOM.scrollLeft = pos.left;
      }
    },
    setTheme,
    setFontSize,
    getRemoved: () => (view ? getRemoved(view.state) : []),
    extra: {
      step: delta => (stepPage(view, Number(delta) || 0) ? 'ok' : 'bounce'),
      showPage: i => showPage(view, Number(i) || 0),
      currentPage: () => currentPage(view.state),
      pageCount: () => pageCount(view.state),
      setPageMode: on => setPages(on),
      isPageMode: () => isPageMode(view.state),
      setCursor,
      insertBlock
    }
  });

  outlineToggleBtn.addEventListener('click', () => {
    outlineVisible = !outlineVisible;
    outlinePanel.hidden = !outlineVisible;
    outlineToggleBtn.setAttribute('aria-pressed', String(outlineVisible));
  });

  pagesBtn.addEventListener('click', () => setPages(!isPageMode(view.state)));

  searchBtn.addEventListener('click', () => {
    const open = toggleFindReplace(view);
    if (open) hideOutline();
    searchBtn.setAttribute('aria-pressed', String(open));
  });

  newestFirstBtn.addEventListener('click', () => {
    setNewestFirst(!newestFirst);
  });

  themeBtn.addEventListener('click', () => {
    setTheme(currentTheme === 'dark' ? 'light' : 'dark');
  });

  setTheme(currentTheme);
  setFontSize(currentFontSize);
  renderOutline();

  return {
    view,
    bridge: bridge.api,
    setTheme,
    setFontSize,
    setNewestFirst,
    openSearch: () => {
      hideOutline();
      return openFindReplace(view);
    },
    getTheme: () => currentTheme,
    getFontSize: () => currentFontSize,
    isNewestFirst: () => newestFirst
  };
}

if (typeof window !== 'undefined' && typeof document !== 'undefined') {
  const boot = () => {
    const host = document.getElementById('app') || document.body;
    const initial = typeof window.__RECENSE_INITIAL_DOC === 'string' ? window.__RECENSE_INITIAL_DOC : '';
    mountEditor(host, initial);
  };
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot, { once: true });
  } else {
    boot();
  }
}
