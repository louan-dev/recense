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
  jumpToOffset,
  attachOutlineGestures
} from './outline.js';
import {
  searchExtension,
  openFindReplace,
  toggleFindReplace,
  isFindReplaceOpen
} from './search.js';
import { legalNumberingExtension } from './legal.js';
import { createEditorBridge, externalSetTextAnnotation, postHaptic } from './bridge.js';
import { removedRecordExtension, getRemoved } from './removed.js';
import {
  pageModeExtension,
  attachSwipePaging,
  stepPage,
  showPage,
  currentPage,
  isPageMode,
  setPageMode,
  pageCount,
  swipeLeftToRight,
  swipeRightToLeft,
  openNewWindowOnLeft,
  deleteEmptyWindow,
  computeEffectiveDrag
} from './pagemode.js';
import { embedsExtension } from './embeds.js';
import { linksExtension } from './links.js';
import {
  formatDotIndicator,
  detectHapticZone,
  attachHapticZones,
  executeVoiceMove,
  HAPTIC_ZONES
} from './gestures.js';
import {
  DEFAULT_FONT_SIZE,
  createThemeCompartments,
  buildThemeExtension,
  buildFontSizeExtension,
  normalizeThemeName,
  normalizeFontSize
} from './theme.js';

export {
  formatDotIndicator,
  detectHapticZone,
  attachHapticZones,
  executeVoiceMove,
  HAPTIC_ZONES
};

export const MENU_ACTIONS = [
  'outline',
  'find',
  'newerPage',
  'olderPage',
  'pages',
  'newestFirst',
  'theme'
];

export function formatPageIndicator(index, total) {
  const safeTotal = Math.max(1, Number(total) || 1);
  const safePage = Math.max(1, Math.min(safeTotal, (Number(index) || 0) + 1));
  return `Page ${safePage} of ${safeTotal}`;
}

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
  let menuOpen = false;
  let toolbarFaded = true;

  const shell = document.createElement('div');
  shell.className = 'rc-shell';

  const toolbar = document.createElement('header');
  toolbar.className = 'rc-toolbar rc-toolbar-faded';

  const pageIndicator = document.createElement('span');
  pageIndicator.className = 'rc-page-indicator';
  pageIndicator.id = 'rc-page-indicator';
  pageIndicator.textContent = formatPageIndicator(0, 1);
  pageIndicator.setAttribute('data-dots', formatDotIndicator(0, 1));

  const menuWrap = document.createElement('div');
  menuWrap.className = 'rc-menu-wrap';

  const menuBtn = document.createElement('button');
  menuBtn.type = 'button';
  menuBtn.className = 'rc-btn rc-menu-btn';
  menuBtn.id = 'rc-menu-btn';
  menuBtn.setAttribute('aria-expanded', 'false');
  menuBtn.setAttribute('aria-haspopup', 'menu');
  menuBtn.setAttribute('aria-label', 'Actions');
  menuBtn.title = 'Actions';
  menuBtn.textContent = '···';

  const menu = document.createElement('div');
  menu.className = 'rc-menu';
  menu.id = 'rc-menu';
  menu.setAttribute('role', 'menu');
  menu.hidden = true;

  function makeMenuItem(id, label, title = '') {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'rc-menu-item';
    btn.id = id;
    btn.setAttribute('role', 'menuitem');
    btn.setAttribute('aria-pressed', 'false');
    if (title) btn.title = title;
    btn.textContent = label;
    return btn;
  }

  const outlineToggleBtn = makeMenuItem('rc-outline-toggle-btn', 'Outline', 'Outline');
  const searchBtn = makeMenuItem('rc-search-btn', 'Find', 'Find (⌘F)');
  const prevPageBtn = makeMenuItem('rc-prev-page-btn', 'Newer page', 'Newer page (⌘[)');
  const nextPageBtn = makeMenuItem('rc-next-page-btn', 'Older page', 'Older page (⌘])');
  const pagesBtn = makeMenuItem(
    'rc-pages-btn',
    'Pages',
    'Swipe or ⌘] / ⌘[ to glide between pages'
  );
  pagesBtn.setAttribute('aria-pressed', 'true');
  const newestFirstMenuBtn = makeMenuItem('rc-newest-first-menu-btn', 'Newest first', 'Order outline newest first');
  const themeBtn = makeMenuItem('rc-theme-btn', 'Light theme', 'Switch theme');

  menu.append(
    outlineToggleBtn,
    searchBtn,
    prevPageBtn,
    nextPageBtn,
    pagesBtn,
    newestFirstMenuBtn,
    themeBtn
  );
  menuWrap.append(menuBtn, menu);
  toolbar.append(pageIndicator, menuWrap);

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

  function updatePageIndicator(state = view ? view.state : null) {
    if (!state) return;
    const cur = currentPage(state);
    const count = pageCount(state);
    pageIndicator.textContent = formatPageIndicator(cur, count);
    pageIndicator.setAttribute('data-dots', formatDotIndicator(cur, count));
  }

  function setToolbarFaded(faded) {
    toolbarFaded = Boolean(faded);
    if (toolbarFaded) {
      toolbar.classList.add('rc-toolbar-faded');
    } else {
      toolbar.classList.remove('rc-toolbar-faded');
    }
  }

  function closeMenu() {
    menuOpen = false;
    menu.hidden = true;
    menuBtn.setAttribute('aria-expanded', 'false');
  }

  function toggleMenu() {
    menuOpen = !menuOpen;
    menu.hidden = !menuOpen;
    menuBtn.setAttribute('aria-expanded', String(menuOpen));
    if (menuOpen) setToolbarFaded(false);
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
      updatePageIndicator(update.state);
      if (update.docChanged) {
        const isExternal = update.transactions.some(tr => Boolean(tr.annotation(externalSetTextAnnotation)));
        if (!isExternal && !menuOpen) {
          setToolbarFaded(true);
        }
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

  attachSwipePaging(view);

  function showOutline() {
    const wasVisible = outlineVisible;
    outlineVisible = true;
    outlinePanel.hidden = false;
    outlineToggleBtn.setAttribute('aria-pressed', 'true');
    if (!wasVisible) postHaptic('open');
  }

  function hideOutline() {
    outlineVisible = false;
    outlinePanel.hidden = true;
    outlineToggleBtn.setAttribute('aria-pressed', 'false');
  }

  function setPages(on) {
    view.dispatch({ effects: setPageMode.of(Boolean(on)) });
    pagesBtn.setAttribute('aria-pressed', String(isPageMode(view.state)));
    if (on) showPage(view, currentPage(view.state));
    updatePageIndicator();
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
    themeBtn.textContent = currentTheme === 'dark' ? 'Light theme' : 'Dark theme';
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
    newestFirstMenuBtn.setAttribute('aria-pressed', String(newestFirst));
    renderOutline();
  }

  let currentInkTool = 'pen';
  const voiceHandlers = {
    swipeLeftToRight: () => (swipeLeftToRight(view, { allowCreate: true }) ? 'ok' : 'bounce'),
    swipeRightToLeft: () => (swipeRightToLeft(view) ? 'ok' : 'bounce'),
    deleteEmptyWindow: () => (deleteEmptyWindow(view) ? 'ok' : 'bounce'),
    toggleOutline: () => {
      if (outlineVisible) hideOutline();
      else showOutline();
    },
    openFind: () => {
      hideOutline();
      return openFindReplace(view);
    },
    setInkTool: tool => {
      currentInkTool = tool;
      const h = typeof window !== 'undefined' && window.webkit?.messageHandlers?.ui;
      if (h && typeof h.postMessage === 'function') h.postMessage({ inkTool: tool });
      return tool;
    },
    summarizeSection: () => {
      const h = typeof window !== 'undefined' && window.webkit?.messageHandlers?.audio;
      if (h && typeof h.postMessage === 'function') h.postMessage({ action: 'summarize' });
      return 'summarize';
    },
    bookmarkAudio: () => {
      const h = typeof window !== 'undefined' && window.webkit?.messageHandlers?.audio;
      if (h && typeof h.postMessage === 'function') h.postMessage({ action: 'bookmark' });
      return 'bookmark';
    }
  };

  const voiceCommand = phrase => executeVoiceMove(phrase, voiceHandlers);

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
      step: delta => (stepPage(view, Number(delta) || 0, { allowCreate: true }) ? 'ok' : 'bounce'),
      swipeLeftToRight: () => (swipeLeftToRight(view, { allowCreate: true }) ? 'ok' : 'bounce'),
      swipeRightToLeft: () => (swipeRightToLeft(view) ? 'ok' : 'bounce'),
      openNewWindowOnLeft: () => (openNewWindowOnLeft(view) ? 'ok' : 'bounce'),
      deleteEmptyWindow: () => (deleteEmptyWindow(view) ? 'ok' : 'bounce'),
      showPage: i => showPage(view, Number(i) || 0),
      currentPage: () => currentPage(view.state),
      pageCount: () => pageCount(view.state),
      setPageMode: on => setPages(on),
      isPageMode: () => isPageMode(view.state),
      setCursor,
      insertBlock,
      voiceCommand,
      getInkTool: () => currentInkTool,
      setInkTool: tool => voiceHandlers.setInkTool(tool)
    }
  });

  menuBtn.addEventListener('click', e => {
    e.stopPropagation();
    toggleMenu();
  });

  toolbar.addEventListener('pointerenter', () => setToolbarFaded(false));
  toolbar.addEventListener('mousemove', () => setToolbarFaded(false));
  toolbar.addEventListener('touchstart', () => setToolbarFaded(false), { passive: true });
  shell.addEventListener('mousemove', e => {
    if (typeof e.clientY === 'number' && e.clientY <= 48) {
      setToolbarFaded(false);
    }
  });
  shell.addEventListener('touchstart', e => {
    const t = e.touches && e.touches[0];
    if (t && typeof t.clientY === 'number' && t.clientY <= 48) {
      setToolbarFaded(false);
    }
  }, { passive: true });

  pageIndicator.addEventListener('click', () => {
    setToolbarFaded(false);
    if (outlineVisible) hideOutline();
    else showOutline();
  });

  outlineToggleBtn.addEventListener('click', () => {
    closeMenu();
    if (outlineVisible) hideOutline();
    else showOutline();
  });

  prevPageBtn.addEventListener('click', () => {
    closeMenu();
    stepPage(view, -1);
  });

  nextPageBtn.addEventListener('click', () => {
    closeMenu();
    stepPage(view, 1);
  });

  pagesBtn.addEventListener('click', () => {
    closeMenu();
    setPages(!isPageMode(view.state));
  });

  searchBtn.addEventListener('click', () => {
    closeMenu();
    const open = toggleFindReplace(view);
    if (open) hideOutline();
    searchBtn.setAttribute('aria-pressed', String(open));
  });

  newestFirstBtn.addEventListener('click', () => {
    setNewestFirst(!newestFirst);
  });

  newestFirstMenuBtn.addEventListener('click', () => {
    closeMenu();
    setNewestFirst(!newestFirst);
  });

  themeBtn.addEventListener('click', () => {
    closeMenu();
    setTheme(currentTheme === 'dark' ? 'light' : 'dark');
  });

  shell.addEventListener('click', e => {
    if (menuOpen && !menuWrap.contains(e.target)) {
      closeMenu();
    }
  });

  shell.addEventListener('keydown', e => {
    if (e.key === 'Escape') {
      if (menuOpen) closeMenu();
      if (outlineVisible) hideOutline();
    }
  });

  attachOutlineGestures(workspace, outlinePanel, {
    isOpen: () => outlineVisible,
    onOpen: () => showOutline(),
    onClose: () => hideOutline()
  });

  attachHapticZones(shell, {
    onZoneEnter(zone) {
      if (zone === 'top') {
        setToolbarFaded(false);
      }
    },
    onZoneLeave(zone) {
      if (zone === 'top' && !menuOpen) {
        setToolbarFaded(true);
      }
    },
    globalObj: typeof window !== 'undefined' ? window : null
  });

  setTheme(currentTheme);
  setFontSize(currentFontSize);
  updatePageIndicator();
  renderOutline();

  return {
    view,
    bridge: bridge.api,
    setTheme,
    setFontSize,
    setNewestFirst,
    showOutline,
    hideOutline,
    isOutlineOpen: () => outlineVisible,
    isToolbarFaded: () => toolbarFaded,
    openSearch: () => {
      hideOutline();
      return openFindReplace(view);
    },
    voiceCommand,
    getInkTool: () => currentInkTool,
    setInkTool: tool => voiceHandlers.setInkTool(tool),
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
