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
  isFindReplaceOpen,
  setInkSearch
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
import { embedsExtension, formatDroppedEmbed } from './embeds.js';
import { linksExtension } from './links.js';
import {
  formatDotIndicator,
  detectHapticZone,
  attachHapticZones,
  executeVoiceMove,
  HAPTIC_ZONES
} from './gestures.js';
import {
  INK_TOOLS,
  INK_COLORS,
  anchorStrokeToDoc,
  resolveStrokeAnchor,
  mergeInkDocuments,
  snapUnderlineStroke,
  detectAndSnapShape,
  eraseWholeStrokes,
  erasePartialStrokes,
  createInkLayer
} from './ink.js';
import {
  activeCueIndexAt,
  bookmarkCue,
  toggleBookmarkCue,
  annotateCue,
  createTranscriptPane,
  createAudioSidecar,
  extractDocumentSections,
  summarizeSectionOffline,
  summarizeAllSections,
  speakSectionSummary
} from './audio.js';
import {
  DEFAULT_WIDGETS,
  hashEventId,
  formatTimestamp,
  extractCalendarEvents,
  createCalendarScanner,
  createDualWings
} from './wings.js';
import { mountWingPanel, wingSideFrom } from './wingpanel.js';
import { createLibraryUI } from './libraryui.js';
import { createSpeaker } from './speech.js';
import { createCalendarSheet } from './calsheet.js';
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
  HAPTIC_ZONES,
  INK_TOOLS,
  INK_COLORS,
  anchorStrokeToDoc,
  resolveStrokeAnchor,
  mergeInkDocuments,
  snapUnderlineStroke,
  detectAndSnapShape,
  eraseWholeStrokes,
  erasePartialStrokes,
  createInkLayer,
  activeCueIndexAt,
  bookmarkCue,
  toggleBookmarkCue,
  annotateCue,
  createTranscriptPane,
  createAudioSidecar,
  extractDocumentSections,
  summarizeSectionOffline,
  summarizeAllSections,
  speakSectionSummary,
  formatDroppedEmbed,
  DEFAULT_WIDGETS,
  hashEventId,
  formatTimestamp,
  extractCalendarEvents,
  createCalendarScanner,
  createDualWings
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
  pageIndicator.textContent = formatDotIndicator(0, 1);
  pageIndicator.setAttribute('data-dots', formatDotIndicator(0, 1));
  pageIndicator.setAttribute('data-label', formatPageIndicator(0, 1));

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
    const dots = formatDotIndicator(cur, count);
    pageIndicator.textContent = dots;
    pageIndicator.setAttribute('data-dots', dots);
    pageIndicator.setAttribute('data-label', formatPageIndicator(cur, count));
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

  let inkLayer = null;
  let library = null;
  let audioSidecar = null;
  let dualWings = null;
  let calendarScanner = null;

  // The agenda rescans once typing settles (0.8 s), never mid-word; scanning only proposes (E2 review #1).
  let calendarScanTimer = null;
  function scheduleCalendarScan() {
    if (calendarScanTimer) clearTimeout(calendarScanTimer);
    calendarScanTimer = setTimeout(() => {
      calendarScanTimer = null;
      if (view && calendarScanner && dualWings) {
        dualWings.setCalendarEvents(calendarScanner.scanText(view.state.doc.toString()));
      }
    }, 800);
    scheduleCalendarOffer();
  }

  // The calendar sheet (calsheet.js) asks about each new future event once typing has paused 3 s. In the apps it
  // waits for the host's list of events already added or refused, so it never asks twice.
  let calSheet = null;
  let calendarReady = !(typeof window !== 'undefined' && window.webkit?.messageHandlers?.calendar);
  let calendarOfferTimer = null;
  function scheduleCalendarOffer(ms = 3000) {
    if (!calSheet) return;
    if (calendarOfferTimer) clearTimeout(calendarOfferTimer);
    calendarOfferTimer = setTimeout(() => {
      calendarOfferTimer = null;
      if (!calSheet || !calendarReady || !view || !calendarScanner) return;
      calSheet.offer(calendarScanner.scanText(view.state.doc.toString()));
    }, ms);
    calendarOfferTimer?.unref?.();
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
        if (calendarScanner && dualWings) scheduleCalendarScan();
        if (isExternal) scheduleExpiry();
        else if (library) library.noteEdit();
      }
      if (update.docChanged || update.transactions.some(tr => tr.effects.length > 0)) {
        renderOutline();
        if (inkLayer) inkLayer.relayout();
      }
      if (library && (update.docChanged || update.selectionSet || update.transactions.some(tr => tr.effects.length > 0))) {
        library.refresh();
      }
    }
  });

  // Expired pages leave once the host's text is in (5 s after it arrives) and then every hour; never mid-typing.
  let expiryTimer = null;
  function scheduleExpiry(ms = 5000) {
    if (expiryTimer) clearTimeout(expiryTimer);
    expiryTimer = setTimeout(() => { expiryTimer = null; if (library) library.runExpiry(); }, ms);
  }
  if (typeof setInterval === 'function') setInterval(() => scheduleExpiry(0), 3_600_000)?.unref?.();   // unref: never holds a test run open

  view = new EditorView({
    state,
    parent: editorHost
  });

  attachSwipePaging(view);

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

  inkLayer = createInkLayer(view, {
    getPageIndex: () => (view ? currentPage(view.state) : 0),
    globalObj: typeof window !== 'undefined' ? window : null,
    mount: editorHost,
    onToolChange: tool => {
      const h = typeof window !== 'undefined' && window.webkit?.messageHandlers?.ui;
      if (h && typeof h.postMessage === 'function') h.postMessage({ inkTool: tool });
    }
  });

  const speaker = createSpeaker(typeof window !== 'undefined' ? window : null);
  library = createLibraryUI({
    getView: () => view,
    toolbar,
    before: menuWrap,
    panel: outlinePanel,
    header: outlineHeader,
    title: outlineTitle,
    outlineOnly: [newestFirstBtn],
    list: outlineList,
    showPanel: showOutline,
    hidePanel: hideOutline,
    ink: inkLayer,
    speaker
  });
  library.refresh();

  // Find also looks in handwriting (read on this device; ink.js + the host's recogniser).
  setInkSearch({
    find: q => (inkLayer ? inkLayer.findInk(q) : []),
    mark: ids => { if (inkLayer) inkLayer.markInk(ids); },
    reveal: m => {
      if (!view || !m) return;
      if (currentPage(view.state) !== m.pageIndex) showPage(view, m.pageIndex);
      view.scrollDOM.scrollTo({ top: Math.max(0, m.y - 80), behavior: 'smooth' });
    }
  });

  audioSidecar = createAudioSidecar({
    container: workspace,
    onInsertToPage: insertBlock,
    globalObj: typeof window !== 'undefined' ? window : null
  });

  dualWings = createDualWings(workspace, {
    onInsertToPage: insertBlock,
    onJumpToLine: lineNum => {
      if (!view) return;
      const safeLine = Math.max(1, Math.min(view.state.doc.lines, Number(lineNum) || 1));
      const line = view.state.doc.line(safeLine);
      jumpToOffset(view, line.from);
    },
    onAddEvent: ev => {
      if (calendarScanner) calendarScanner.requestAdd(ev);
    },
    globalObj: typeof window !== 'undefined' ? window : null
  });

  calendarScanner = createCalendarScanner({
    globalObj: typeof window !== 'undefined' ? window : null
  });
  if (typeof window !== 'undefined' && !window.__RECENSE_WING_SIDE && typeof document !== 'undefined') {
    calSheet = createCalendarSheet({
      layer: workspace,
      onAdd: ev => calendarScanner.requestAdd(ev),
      onDismiss: id => window.webkit?.messageHandlers?.calendar?.postMessage?.({ action: 'dismiss', ids: [id] })
    });
    scheduleCalendarOffer();
  }

  if (initialDoc) {
    dualWings.setCalendarEvents(calendarScanner.scanText(initialDoc));
  }

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

  function normalizeInkToolName(tool) {
    const t = String(tool ?? 'pen').trim().toLowerCase();
    if (t === 'whole eraser' || t === 'eraser') return 'eraser-whole';
    if (t === 'partial eraser') return 'eraser-partial';
    return t;
  }

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
      // The layer reports the change back through onToolChange (state + host message).
      if (inkLayer) inkLayer.setTool(normalizeInkToolName(tool));
      return tool;
    },
    summarizeSection: idx => {
      const secs = extractDocumentSections(view.state.doc.toString(), currentPage(view.state));
      const sec = secs[idx ?? 0] || { title: '', text: view.state.doc.toString() };
      return speakSectionSummary(sec);
    },
    bookmarkAudio: (idx, note = '') => {
      const targetIdx = typeof idx === 'number' ? idx : Math.max(0, audioSidecar.getActiveCueIndex());
      return audioSidecar.bookmarkCue(targetIdx, note);
    },
    openWing: side => (dualWings ? dualWings.openWing(side) : null),
    closeWing: side => (dualWings ? dualWings.closeWing(side) : null),
    swapWings: () => (dualWings ? dualWings.swapWings() : null)
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
      getInk: () => (inkLayer ? inkLayer.getInk() : { version: 1, strokes: [], removed: [] }),
      setInk: data => {
        if (!inkLayer) return;
        const parsed = typeof data === 'string' ? JSON.parse(data) : data;
        inkLayer.setInk(parsed);
        inkLayer.relayout();
      },
      mergeInk: remote => {
        if (!inkLayer) return null;
        const parsed = typeof remote === 'string' ? JSON.parse(remote) : remote;
        const merged = mergeInkDocuments(inkLayer.getInk(), parsed);
        inkLayer.setInk(merged);
        inkLayer.relayout();
        return merged;
      },
      getInkTool: () => (inkLayer ? inkLayer.getTool() : 'select'),
      setInkTool: tool => voiceHandlers.setInkTool(tool),
      getInkColor: () => (inkLayer ? inkLayer.getColor() : INK_COLORS[0]),
      setInkColor: color => {
        if (inkLayer) inkLayer.setColor(color);
        return inkLayer ? inkLayer.getColor() : color;
      },
      toggleEraser: () => (inkLayer ? inkLayer.toggleEraser() : 'eraser-whole'),
      // The host's eyedropper answer (macOS's sampler, iOS's colour picker): it waits under the wheel's check mark.
      // The host's reading of a handwriting group (shared/inkocr.swift): kept with its strokes for Find.
      setInkText: (id, text) => (inkLayer ? inkLayer.setInkText(String(id), String(text ?? '')) : 0),
      setPickedColor: hex => (inkLayer ? inkLayer.offerColor(String(hex)) : null),
      // Page library: draftpad.playlists.json from the host, the archive's answer, a tab of the side panel.
      setSidecar: (name, json) => (library ? library.setSidecar(String(name), String(json)) : null),
      pagesArchived: (token, ok) => (library ? library.pagesArchived(String(token), Boolean(ok)) : 0),
      openLibrary: tabName => (library ? library.openTab(String(tabName || 'saved')) : null),
      // Pencil double-tap or squeeze wakes the palette under the pill (or puts it back to sleep).
      onPencilAction: action => {
        if ((action === 'squeeze' || action === 'doubleTap') && inkLayer) {
          postHaptic('squeeze');
          return inkLayer.toggleMenu() ? 'awake' : 'asleep';
        }
        return inkLayer && inkLayer.isAwake() ? 'awake' : 'asleep';
      },
      setAudioTranscript: data => {
        const parsed = typeof data === 'string' ? JSON.parse(data) : data;
        audioSidecar.setAudioTranscript(parsed);
      },
      // The host's report on one calendar add: saved, or the reason it wasn't.
      calendarResult: (id, ok, message) => {
        if (ok && calendarScanner) calendarScanner.markSynced(id);
        if (dualWings) dualWings.setCalendarStatus(id, ok ? 'added' : 'error', message || '');
      },
      // At load: the ids the host already saved (draftpad.events.json), so they show as added.
      setCalendarAdded: data => {
        const all = typeof data === 'string' ? JSON.parse(data) : data;
        const ids = Array.isArray(all) ? all.filter(id => !String(id).startsWith('x:')) : all;
        // "x:<id>": events refused in the calendar sheet (kept in the same file as the ones added).
        if (calSheet && Array.isArray(all)) calSheet.setDismissed(all.filter(id => String(id).startsWith('x:')).map(id => String(id).slice(2)));
        if (!calendarReady) { calendarReady = true; scheduleCalendarOffer(); }
        if (calendarScanner && Array.isArray(ids)) calendarScanner.markSynced(ids);
        if (view && calendarScanner && dualWings) {
          dualWings.setCalendarEvents(calendarScanner.scanText(view.state.doc.toString()));
        }
      },
      // A widget only this host can run (the Mac: 'iphone').
      enableWidget: id => (dualWings ? dualWings.enableHostWidget(id) : null),
      updateAudioTime: sec => audioSidecar.updateTime(sec),
      bookmarkAudioCue: (idx, note) => voiceHandlers.bookmarkAudio(idx, note),
      annotateAudioCue: (idx, text) => {
        const targetIdx = typeof idx === 'number' ? idx : Math.max(0, audioSidecar.getActiveCueIndex());
        return audioSidecar.annotateCue(targetIdx, text);
      },
      summarizeSection: idx => voiceHandlers.summarizeSection(idx),
      summarizeAllSections: () => summarizeAllSections(view.state.doc.toString(), { pageIndex: currentPage(view.state) }),
      dropFile: (pathOrUri, caption) => {
        const md = formatDroppedEmbed(pathOrUri, caption);
        if (md) insertBlock(md);
        return md;
      },
      openWing: side => (dualWings ? dualWings.openWing(side) : null),
      closeWing: side => (dualWings ? dualWings.closeWing(side) : null),
      toggleWing: side => (dualWings ? dualWings.toggleWing(side) : null),
      isWingOpen: side => (dualWings ? dualWings.isWingOpen(side) : false),
      swapWings: () => (dualWings ? dualWings.swapWings() : null),
      moveWidget: (id, side) => (dualWings ? dualWings.moveWidget(id, side) : null),
      getWingLayout: () => (dualWings ? dualWings.getWingLayout() : { left: [], right: [], leftOpen: false, rightOpen: false }),
      setPreviewTarget: (src, caption) => (dualWings ? dualWings.setPreviewTarget(src, caption) : null),
      setRecenseLine: (original, translation) => (dualWings ? dualWings.setRecenseLine(original, translation) : null),
      setMediaSource: (src, title) => (dualWings ? dualWings.setMediaSource(src, title) : null),
      setPlaybackRate: rate => (dualWings ? dualWings.setPlaybackRate(rate) : null),
      setLoopRange: (start, end) => (dualWings ? dualWings.setLoopRange(start, end) : null),
      setFindMyItems: items => (dualWings ? dualWings.setFindMyItems(typeof items === 'string' ? JSON.parse(items) : items) : null),
      setMailMessages: msgs => (dualWings ? dualWings.setMailMessages(typeof msgs === 'string' ? JSON.parse(msgs) : msgs) : null),
      extractCalendarEvents: (text, opts) => extractCalendarEvents(typeof text === 'string' ? text : view.state.doc.toString(), opts),
      getCalendarEvents: () => (calendarScanner ? calendarScanner.getEvents() : []),
      setWingsState: state => (dualWings ? dualWings.setState(state) : null),
      getWingsState: () => (dualWings ? dualWings.getState() : null),
      // The Mac shows the wings in native panels (strip/wingpanels.swift): open / close / toggle go to the host.
      setNativeWings: on => {
        if (!dualWings) return false;
        const h = typeof window !== 'undefined' ? window.webkit?.messageHandlers?.wings : null;
        dualWings.setNativeWings(on && h ? (op, side) => h.postMessage({ action: 'wing', op, side }) : null);
        return Boolean(on && h);
      },
      // A wing panel's card puts text in the page (a citation) or jumps to a line (the Agenda).
      insertBlock: text => insertBlock(text),
      jumpToLine: lineNum => {
        const safeLine = Math.max(1, Math.min(view.state.doc.lines, Number(lineNum) || 1));
        jumpToOffset(view, view.state.doc.line(safeLine).from);
      }
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
      if (dualWings && dualWings.isWingOpen()) dualWings.closeWing('both');
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
    inkLayer,
    audioSidecar,
    dualWings,
    calendarScanner,
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
    getInkTool: () => (inkLayer ? inkLayer.getTool() : 'select'),
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
    const wingSide = wingSideFrom(window);
    if (wingSide) mountWingPanel(host, wingSide);
    else mountEditor(host, initial);
  };
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot, { once: true });
  } else {
    boot();
  }
}
