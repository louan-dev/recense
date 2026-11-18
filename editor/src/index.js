import { deviceLayout, layoutVars } from './devicelayout.js';
import { isMixed } from './lenses.js';
import { LANGS, LANG_NAMES } from './langs.js';
import { EditorState } from '@codemirror/state';
import { EditorView, keymap, drawSelection, highlightSpecialChars } from '@codemirror/view';
import { defaultKeymap, history, historyKeymap } from '@codemirror/commands';
import { markdown } from '@codemirror/lang-markdown';
import { pageMarkersExtension, controlCharFilter, inspectDraftpadPages, isWindowEmpty } from './pages.js';
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
import { createRecense, recenseField, LENS_NAMES } from './recense.js';
import { chapterEntries } from './chapters.js';
import { createEditorBridge, externalSetTextAnnotation, postHaptic } from './bridge.js';
import { canPlayFiles, createFilePlayer } from './fileplayer.js';
import { removedRecordExtension, getRemoved } from './removed.js';
import {
  pageModeExtension,
  attachSwipePaging,
  setPagesLocked,
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
  computeEffectiveDrag,
  goToPage,
  newPage,
  promotePage,
  movePage,
  dropIndex,
  setPageSlot,
  pageSlots,
  slotPage,
  reopenTarget,
  reopenMemo
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
  createInkLayer,
  toolLocksPages
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
import { squeezeHost } from './pencilstate.js';
import * as matterCore from './matter.js';
import { createMatterMenu } from './mattermenu.js';
import { logEvent } from './logevent.js';
import { passageOfStrokes } from './inkselection.js';
import {
  DEFAULT_FONT_SIZE,
  createThemeCompartments,
  buildThemeExtension,
  buildFontSizeExtension,
  normalizeThemeName,
  normalizeFontSize,
  stepFontSize
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
  'playFile',
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
    // T-0090 · raw control characters (0x04 …) as measured widgets, so a click among them lands where it is aimed.
    highlightSpecialChars({ render: renderControlChar }),
    history(),
    drawSelection(),
    // BUG-22 · no band behind the caret's line (owner 2026-11-16: "remove the blue line guide").
    EditorView.lineWrapping,
    markdown(),
    searchExtension({ onOpen: onOpenFind }),
    headingFoldExtension(),
    legalNumberingExtension(),
    removedRecordExtension(),
    keymap.of([...defaultKeymap, ...historyKeymap]),
    pageMarkersExtension(),
    controlCharFilter(),
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

/** T-0090 · A control character shows as a small muted dot; the character itself stays in the file (BUG-18 A3). */
export function renderControlChar(code, _description, _placeholder, doc = document) {
  const el = doc.createElement('span');
  el.className = 'cm-control-char';
  el.textContent = '·';
  el.setAttribute('title', `Control character U+${code.toString(16).toUpperCase().padStart(4, '0')}`);
  return el;
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
  let userFontSize = false;
  let newestFirst = false;
  let outlineVisible = false;
  let menuOpen = false;
  let toolbarFaded = true;

  const shell = document.createElement('div');
  shell.className = 'rc-shell';

  const toolbar = document.createElement('header');
  toolbar.className = 'rc-toolbar rc-toolbar-faded';

  // Derived from Spec: UI-06 · ＋ new page · ‹ newer · page dots (tap / drag to front / hold) · › older · slot dots.
  const nav = document.createElement('nav');
  nav.className = 'rc-nav';
  nav.setAttribute('aria-label', 'Pages');
  function navButton(cls, label, glyph) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = `rc-btn rc-nav-btn ${cls}`;
    b.setAttribute('aria-label', label);
    b.title = label;
    b.textContent = glyph;
    return b;
  }
  const newPageNavBtn = navButton('rc-nav-new', 'New page', '＋');
  const newerNavBtn = navButton('rc-nav-newer', 'Newer page', '‹');
  const olderNavBtn = navButton('rc-nav-older', 'Older page', '›');
  const pageIndicator = document.createElement('span');
  pageIndicator.className = 'rc-page-indicator';
  pageIndicator.id = 'rc-page-indicator';
  pageIndicator.setAttribute('role', 'group');
  pageIndicator.setAttribute('data-dots', formatDotIndicator(0, 1));
  pageIndicator.setAttribute('data-label', formatPageIndicator(0, 1));
  const slotRow = document.createElement('span');
  slotRow.className = 'rc-slot-row';
  slotRow.setAttribute('role', 'group');
  slotRow.setAttribute('aria-label', 'Slots');
  const dotSheet = document.createElement('div');
  dotSheet.className = 'rc-dot-sheet';
  dotSheet.setAttribute('role', 'menu');
  dotSheet.hidden = true;
  nav.append(newPageNavBtn, newerNavBtn, pageIndicator, olderNavBtn, slotRow, dotSheet);

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

  const outlineToggleBtn = makeMenuItem('rc-outline-toggle-btn', 'Chapters', 'Chapters, Saved and Playlists');
  // Recense what you typed (recense.js): the layer, its lens, and recensing now. Translate into: the Source lens's
  // language for this page (Auto: English → Vietnamese, anything else → English).
  const recenseLayerBtn = makeMenuItem('rc-recense-layer-btn', 'Recense layer', 'Show recensed lines under your text');
  const recenseLensBtn = makeMenuItem('rc-recense-lens-btn', 'Lens: Gist', 'Change the lens: Gist, Retell, Reformat, Ask, Reapply, Source');
  const recenseNowBtn = makeMenuItem('rc-recense-now-btn', 'Recense now', 'Recense every section not yet recensed');
  const recenseReadBtn = makeMenuItem('rc-recense-read-btn', 'Read lens aloud', 'Hear the lens lines of the section you are in');
  const recenseIntoBtn = makeMenuItem('rc-recense-into-btn', 'Translate into: Auto', 'The Source lens’s language for this page');
  const searchBtn = makeMenuItem('rc-search-btn', 'Find', 'Find (⌘F)');
  const newPageMenuBtn = makeMenuItem('rc-new-page-btn', 'New page', 'A new page at the front');
  const prevPageBtn = makeMenuItem('rc-prev-page-btn', 'Newer page', 'One page to the left');
  const nextPageBtn = makeMenuItem('rc-next-page-btn', 'Older page', 'One page to the right');
  const promoteMenuBtn = makeMenuItem('rc-promote-btn', 'Promote to front', 'Move this page to the front');
  // Derived from Spec: UI-06 / UI-07 · every page action the bar offers by gesture also has a menu item
  // (delete = the empty-page swipe, slot = holding a page dot), and the text size has one too.
  const deletePageMenuBtn = makeMenuItem('rc-delete-page-btn', 'Delete empty page', 'Delete this page (only when it is empty)');
  const slotMenuBtn = makeMenuItem('rc-slot-btn', 'Put in slot…', 'Put this page in slot 1–9');
  const largerTextBtn = makeMenuItem('rc-larger-text-btn', 'Larger text', 'Make the text bigger');
  const smallerTextBtn = makeMenuItem('rc-smaller-text-btn', 'Smaller text', 'Make the text smaller');
  const pagesBtn = makeMenuItem('rc-pages-btn', 'Pages', 'Swipe to glide between pages');
  pagesBtn.setAttribute('aria-pressed', 'true');
  const newestFirstMenuBtn = makeMenuItem('rc-newest-first-menu-btn', 'Newest first', 'Order outline newest first');
  // FEAT-19 P4 · browser only: a sound or video file from this device, on the Lock Screen (the app has its own).
  const playFileBtn = makeMenuItem('rc-play-file-btn', 'Play a file…', 'Play a sound or video file from this device');
  playFileBtn.hidden = !canPlayFiles();
  const filePlayer = createFilePlayer();
  const themeBtn = makeMenuItem('rc-theme-btn', 'Light theme', 'Switch theme');

  menu.append(
    outlineToggleBtn,
    recenseLayerBtn,
    recenseLensBtn,
    recenseNowBtn,
    recenseReadBtn,
    recenseIntoBtn,
    searchBtn,
    newPageMenuBtn,
    prevPageBtn,
    nextPageBtn,
    promoteMenuBtn,
    deletePageMenuBtn,
    slotMenuBtn,
    pagesBtn,
    largerTextBtn,
    smallerTextBtn,
    newestFirstMenuBtn,
    playFileBtn,
    themeBtn
  );
  menuWrap.append(menuBtn, menu);
  toolbar.append(nav, menuWrap);

  const workspace = document.createElement('div');
  workspace.className = 'rc-workspace';

  const outlinePanel = document.createElement('aside');
  outlinePanel.className = 'rc-outline';
  outlinePanel.id = 'rc-outline-panel';
  outlinePanel.setAttribute('aria-label', 'Chapters');
  outlinePanel.hidden = true;

  const outlineHeader = document.createElement('div');
  outlineHeader.className = 'rc-outline-header';

  const outlineTitle = document.createElement('span');
  outlineTitle.textContent = 'Chapters';

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

  shell.append(toolbar, filePlayer.panel, workspace);
  root.innerHTML = '';
  root.appendChild(shell);

  let view = null;
  let bridge = null;

  // ── Chapters: the side panel's first tab (chapters.js). Your headings live; recensed titles held while it's open. ──
  let chapterActionsFor = -1;   // the entry (by offset) whose Play / Make heading / Copy gist row is open
  function playFrom(from, to) {
    const parts = view.state.doc.sliceString(from, to).split(/\n\s*\n/)
      .map(t => t.replace(/<!--[\s\S]*?-->/g, '').replace(/^#+\s+|^§\s+/gm, '').trim()).filter(Boolean);
    if (parts.length && speaker) speaker.speak(parts, {});
  }

  function renderEntryRow(e, page) {
    const wrap = document.createElement('div');
    const row = document.createElement('div');
    row.className = `rc-outline-item rc-chapter rc-chapter-${e.kind}${e.level > 1 ? ' rc-chapter-nested' : ''}`;
    if (e.current) row.setAttribute('aria-current', 'true');

    const foldBtn = document.createElement('button');
    foldBtn.type = 'button';
    foldBtn.className = 'rc-outline-fold-btn';
    const h = e.heading;
    if (h && h.foldFrom !== null && h.foldTo !== null) {
      const folded = isHeadingFolded(view.state, h);
      foldBtn.textContent = folded ? '▸' : '▾';
      foldBtn.title = folded ? 'Unfold heading' : 'Fold heading';
      foldBtn.addEventListener('click', ev => { ev.stopPropagation(); toggleHeadingFold(view, h); renderOutline(); });
    } else {
      foldBtn.textContent = e.kind === 'recensed' ? '✦' : '·';
      if (e.kind === 'recensed') foldBtn.title = 'Recensed: a title Recense wrote; it is not in your page';
      foldBtn.disabled = true;
    }

    const jumpBtn = document.createElement('button');
    jumpBtn.type = 'button';
    jumpBtn.className = 'rc-outline-jump-btn';
    const title = document.createElement('span');
    title.className = 'rc-chapter-title';
    title.textContent = e.title;
    jumpBtn.appendChild(title);
    if (e.gist) jumpBtn.appendChild(Object.assign(document.createElement('span'), { className: 'rc-chapter-gist', textContent: e.gist }));
    if (e.listen) jumpBtn.appendChild(Object.assign(document.createElement('span'), { className: 'rc-chapter-time', textContent: e.listen }));
    let held = false, holdTimer = null;
    jumpBtn.addEventListener('pointerdown', () => {
      held = false;
      holdTimer = setTimeout(() => { held = true; chapterActionsFor = e.from; renderOutline(); }, 500);
    });
    const cancelHold = () => { if (holdTimer) clearTimeout(holdTimer); holdTimer = null; };
    jumpBtn.addEventListener('pointerup', cancelHold);
    jumpBtn.addEventListener('pointerleave', cancelHold);
    jumpBtn.addEventListener('click', () => {
      if (held) return;
      jumpToOffset(view, e.from);
      hideOutline();
    });

    const moreBtn = document.createElement('button');
    moreBtn.type = 'button';
    moreBtn.className = 'rc-chapter-more';
    moreBtn.textContent = '···';
    moreBtn.setAttribute('aria-label', `More for ${e.title}`);
    moreBtn.setAttribute('aria-expanded', String(chapterActionsFor === e.from));
    moreBtn.addEventListener('click', ev => {
      ev.stopPropagation();
      chapterActionsFor = chapterActionsFor === e.from ? -1 : e.from;
      renderOutline();
    });

    row.append(foldBtn, jumpBtn, moreBtn);
    wrap.appendChild(row);
    if (chapterActionsFor === e.from) {
      const acts = document.createElement('div');
      acts.className = 'rc-chapter-actions';
      const act = (label, fn) => {
        const b = document.createElement('button');
        b.type = 'button';
        b.className = 'rc-chapter-action';
        b.textContent = label;
        b.addEventListener('click', ev => { ev.stopPropagation(); chapterActionsFor = -1; fn(); });
        acts.appendChild(b);
      };
      act('Play from here', () => playFrom(e.from, page.to));
      if (e.kind === 'recensed' && recense) {
        act('Make heading', () => { if (recense.makeHeading(e.section.key)) library?.toast('Heading added to your page'); });
      }
      if (e.gist) {
        act('Copy gist', () => {
          try { navigator.clipboard?.writeText(e.gist); } catch { /* no clipboard here */ }
          library?.toast('Gist copied');
        });
      }
      wrap.appendChild(acts);
    }
    return wrap;
  }

  function renderOutline() {
    if (!view || !outlineVisible) return;
    const docText = view.state.doc.toString();
    outlineList.innerHTML = '';
    const pages = chapterEntries(docText, {
      sections: recense ? recense.sections() : [],
      titles: recense ? recense.titles() : new Map(),
      lastDone: recense ? recense.lastDone() : 0,
      caret: view.state.selection.main.head,
      newestFirst
    });
    if (!pages.some(p => p.entries.length) && pages.length <= 1) {
      const empty = document.createElement('div');
      empty.className = 'rc-outline-empty';
      empty.textContent = 'No chapters yet';
      outlineList.appendChild(empty);
      return;
    }
    for (const { page, entries } of pages) {
      const pageBlock = document.createElement('div');
      pageBlock.className = 'rc-outline-page';
      if (pages.length > 1 || newestFirst) {
        const pageBtn = document.createElement('button');
        pageBtn.type = 'button';
        pageBtn.className = 'rc-outline-page-btn';
        pageBtn.textContent = page.dateLine || page.title;
        pageBtn.addEventListener('click', () => { jumpToOffset(view, page.from); hideOutline(); });
        pageBlock.appendChild(pageBtn);
      }
      for (const e of entries) pageBlock.appendChild(renderEntryRow(e, page));
      outlineList.appendChild(pageBlock);
    }
  }

  function updatePageIndicator(state = view ? view.state : null) {
    if (!state) return;
    const cur = currentPage(state);
    const count = pageCount(state);
    const dots = formatDotIndicator(cur, count);
    pageIndicator.setAttribute('data-dots', dots);
    pageIndicator.setAttribute('data-label', formatPageIndicator(cur, count));
    const size = 8;
    const start = count <= size ? 0 : Math.max(0, Math.min(count - size, cur - Math.floor(size / 2)));
    const end = Math.min(count, start + size);
    const key = `${start}:${end}:${cur}`;
    if (pageIndicator.getAttribute('data-key') !== key) {
      pageIndicator.setAttribute('data-key', key);
      clearEl(pageIndicator);
      for (let i = start; i < end; i++) {
        const d = document.createElement('button');
        d.type = 'button';
        d.className = `rc-dot${i === cur ? ' is-current' : ''}`;
        d.setAttribute('data-page', String(i));
        d.setAttribute('aria-label', formatPageIndicator(i, count));
        d.setAttribute('aria-current', i === cur ? 'page' : 'false');
        d.textContent = i === cur ? '●' : '○';
        attachDotGestures(d, i);
        pageIndicator.appendChild(d);
      }
    }
    const slots = pageSlots(state.doc.toString());
    const skey = JSON.stringify(slots) + cur;
    if (slotRow.getAttribute('data-key') !== skey) {
      slotRow.setAttribute('data-key', skey);
      clearEl(slotRow);
      for (const n of Object.keys(slots).map(Number).sort((a, b) => a - b)) {
        const b = document.createElement('button');
        b.type = 'button';
        b.className = `rc-slot${slots[n] === cur ? ' is-current' : ''}`;
        b.setAttribute('aria-label', `Slot ${n}`);
        b.textContent = String(n);
        b.addEventListener('click', e => { e.stopPropagation(); slotPage(view, n); });
        slotRow.appendChild(b);
      }
    }
    newerNavBtn.disabled = cur <= 0;
    olderNavBtn.disabled = cur >= count - 1 && !isWindowEmpty(inspectDraftpadPages(state.doc.toString())[cur]?.rawContent);
    deletePageMenuBtn.disabled = !isWindowEmpty(inspectDraftpadPages(state.doc.toString())[cur]?.rawContent);
    saveReopenMemo(state);
  }

  function clearEl(el) { while (el.firstChild) el.removeChild(el.firstChild); }

  // R1 · reopen on the page you were last on (this device only).
  const REOPEN_KEY = 'recense.draftpad.reopen';
  let reopenReady = false;
  function saveReopenMemo(state) {
    if (!reopenReady) return;
    try { localStorage.setItem(REOPEN_KEY, JSON.stringify(reopenMemo(state))); } catch (_) { /* storage blocked */ }
  }
  function reopen() {
    let saved = null;
    try { saved = JSON.parse(localStorage.getItem(REOPEN_KEY) || 'null'); } catch (_) { saved = null; }
    const i = reopenTarget(view.state.doc.toString(), saved);
    reopenReady = true;
    if (i !== currentPage(view.state)) showPage(view, i, { preserveMemory: false });
    updatePageIndicator();
    return i;
  }

  // G3 tap · G4 drag a dot to any place (T-0089) · G5 hold 500 ms (moving < 8 px).
  const HOLD_MS = 500;
  const TAP_SLOP_PX = 8;
  function attachDotGestures(dot, index) {
    let x0 = 0, t0 = 0, dragging = false, held = false, timer = null, id = null;
    const reset = () => {
      clearTimeout(timer); timer = null; dragging = false; id = null;
      dot.classList.remove('is-dragging');
      for (const d of pageIndicator.children) d.style.transform = '';
      centres = null;
    };
    // T-0089 · while a dot is dragged, the dots it passes slide one place the other way, so the gap shows where it lands.
    let centres = null, pitch = 0;
    const measure = () => {
      const dots = [...pageIndicator.children];
      centres = dots.map(d => { const r = d.getBoundingClientRect(); return r.left + r.width / 2; });
      pitch = centres.length > 1 ? (centres[centres.length - 1] - centres[0]) / (centres.length - 1) : 0;
    };
    const preview = x => {
      const to = dropIndex(centres, index, x);
      [...pageIndicator.children].forEach((d, i) => {
        if (i === index) return;
        const shift = index < to && i > index && i <= to ? -pitch : index > to && i >= to && i < index ? pitch : 0;
        d.style.transform = shift ? `translateX(${shift}px)` : '';
      });
      return to;
    };
    dot.addEventListener('pointerdown', e => {
      e.stopPropagation();
      x0 = e.clientX; t0 = Date.now(); held = false; dragging = false; id = e.pointerId;
      try { dot.setPointerCapture(e.pointerId); } catch (_) { /* not capturable */ }
      timer = setTimeout(() => { if (!dragging) { held = true; openDotSheet(index, dot); } }, HOLD_MS);
    });
    dot.addEventListener('pointermove', e => {
      if (id !== e.pointerId) return;
      const dx = e.clientX - x0;
      if (!dragging && Math.abs(dx) >= TAP_SLOP_PX && !held) {
        dragging = true; clearTimeout(timer); dot.classList.add('is-dragging'); measure();
      }
      if (dragging) { dot.style.transform = `translateX(${dx}px)`; preview(e.clientX); }
    });
    dot.addEventListener('pointerup', e => {
      if (id !== e.pointerId) return;
      const wasDrag = dragging, wasHeld = held;
      const to = wasDrag && centres ? dropIndex(centres, index, e.clientX) : index;
      reset();
      if (wasHeld) return;
      if (wasDrag) {
        if (to !== index) movePage(view, index, to);
        return;
      }
      if (Date.now() - t0 < HOLD_MS) goToPage(view, index);
    });
    dot.addEventListener('pointercancel', reset);
    dot.addEventListener('click', e => e.stopPropagation());
  }

  function closeDotSheet() { dotSheet.hidden = true; clearEl(dotSheet); }
  dotSheet.addEventListener('pointerdown', e => e.stopPropagation());
  function openDotSheet(index, anchor) {
    postHaptic('snap');
    clearEl(dotSheet);
    const item = (label, run) => {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'rc-menu-item';
      b.setAttribute('role', 'menuitem');
      b.textContent = label;
      b.addEventListener('click', e => { e.stopPropagation(); closeDotSheet(); run(); });
      dotSheet.appendChild(b);
    };
    if (index > 0) item('Promote to front', () => promotePage(view, index));
    const slots = pageSlots(view.state.doc.toString());
    const mine = Object.keys(slots).find(n => slots[n] === index);
    const grid = document.createElement('div');
    grid.className = 'rc-slot-grid';
    for (let n = 1; n <= 9; n++) {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = `rc-slot${String(n) === mine ? ' is-current' : ''}`;
      b.setAttribute('aria-label', `Put in slot ${n}`);
      b.textContent = String(n);
      b.addEventListener('click', e => { e.stopPropagation(); closeDotSheet(); setPageSlot(view, index, n); updatePageIndicator(); });
      grid.appendChild(b);
    }
    dotSheet.appendChild(grid);
    if (mine) item('Clear slot', () => { setPageSlot(view, index, null); updatePageIndicator(); });
    const r = anchor.getBoundingClientRect();
    const nr = nav.getBoundingClientRect();
    dotSheet.style.left = `${Math.max(0, r.left - nr.left - 40)}px`;
    dotSheet.hidden = false;
  }

  function setToolbarFaded(faded) {
    if (faded && dotSheet && !dotSheet.hidden) return;   // UI-06 G5: the bar stays while its sheet is open
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
  let matterMenu = null;   // FEAT-08
  let selectionMatterItems = () => [];   // UI-04 P11: FEAT-08 matter actions for lasso-selected strokes
  let radialOuterItems = () => [];   // UI-04 P2 outer ring: FEAT-08 matter actions for the text selection
  let pencilSqueeze = null;   // UI-04 P1: built on the first squeeze phase
  let library = null;
  let recense = null;
  let recenseActions = null;
  let speaker = null;
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
    extraExtensions: [recenseField],
    onUpdate(update) {
      const findOpen = isFindReplaceOpen(update.state);
      searchBtn.setAttribute('aria-pressed', String(findOpen));
      if (findOpen && outlineVisible) {
        hideOutline();
      }
      updatePageIndicator(update.state);
      if (update.docChanged) {
        const isExternal = update.transactions.some(tr => Boolean(tr.annotation(externalSetTextAnnotation)));
        // UI-06: page actions (new, delete, promote, slot) come from the bar itself; only writing fades it.
        const pageAction = update.transactions.every(tr =>
          ['move.page', 'delete.page', 'input.page', 'input.slot'].some(ev => tr.isUserEvent(ev)));
        if (!isExternal && !menuOpen && !pageAction) {
          setToolbarFaded(true);
        }
        if (bridge) bridge.notifyDocChanged(update.transactions);
        if (calendarScanner && dualWings) scheduleCalendarScan();
        if (isExternal) scheduleExpiry();
        else if (library) library.noteEdit();
        if (recense) recense.docChanged();
      }
      if (recense && (update.selectionSet || update.focusChanged)) recense.updateCard();
      if (matterMenu && update.selectionSet) matterMenu.selectionChanged();
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
  // FEAT-08 · the sidecar of the one page. A crossing runs on (body, ink, sidecar) together, then lands the body
  // change as one ordinary edit (so the host saves it through its 3-way merge) and the ink through setInk.
  let matterSide = { version: 1, passages: {}, log: [] };
  // This device's name for seeds and per-device undo; the host names it at load (setMatterDevice, FEAT-08 P5).
  const matterDevice = matterCore.createMatterDevice(typeof navigator !== 'undefined'
    ? { userAgent: navigator.userAgent || '', maxTouchPoints: navigator.maxTouchPoints || 0 } : {});
  let matterInput = 'keys';
  // Derived from Spec: FEAT-08 P6 — a passage born in a media note keeps that item's second (its playhead, when the
  // host has given one for the same key). Never on draftpad.md in this phase (Q-B1).
  let noteKeyNow = () => null;     // set by the media note (FEAT-23)
  let playheadKey = '';            // the key whose playhead updateAudioTime reports
  const mediaOf = () => {
    const key = noteKeyNow();
    if (!key || !audioSidecar || playheadKey !== key) return null;
    const t = matterCore.noteTime(audioSidecar.getState().currentTime);
    return t === null ? null : { key, t };
  };
  const matterSeed = () => {
    const media = mediaOf();
    return media ? { device: matterDevice.get(), input: matterInput, time: Date.now(), media: { key: media.key, t: matterCore.noteTime(media.t) } }
      : { device: matterDevice.get(), input: matterInput, time: Date.now() };
  };
  function postMatter() {
    const h = window.webkit?.messageHandlers?.matter;
    if (h && typeof h.postMessage === 'function') h.postMessage(JSON.stringify(matterSide));
  }
  function applyMatter(fn) {
    if (!view) return { ok: false, error: 'no editor' };
    const before = matterCore.createMatter({
      text: view.state.doc.toString(),
      ink: inkLayer ? inkLayer.getInk() : null,
      side: matterSide
    });
    let after;
    try { after = fn(before); } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
    if (after.text !== before.text) {
      const a = before.text, b = after.text;
      let i = 0;
      while (i < a.length && i < b.length && a[i] === b[i]) i++;
      let j = 0;
      while (j < a.length - i && j < b.length - i && a[a.length - 1 - j] === b[b.length - 1 - j]) j++;
      view.dispatch({ changes: { from: i, to: a.length - j, insert: b.slice(i, b.length - j) } });
    }
    if (inkLayer && JSON.stringify(after.ink) !== JSON.stringify(before.ink)) {
      inkLayer.setInk(after.ink);
      inkLayer.relayout();
      window.webkit?.messageHandlers?.ink?.postMessage?.(JSON.stringify(after.ink));   // setInk alone does not save
    }
    const sideChanged = JSON.stringify(after.side) !== JSON.stringify(matterSide);
    matterSide = after.side;
    if (sideChanged) postMatter();
    return { ok: true };
  }

  // FEAT-23 rule 5 / A1 rule 7 · one way to ask the host to play an item from a second (a moment link, a passage,
  // a stroke, a backlink). The host pauses another item first.
  function playMedia(key, t, from) {
    const h = window.webkit?.messageHandlers?.audio;
    const sec = Math.max(0, Number(t) || 0);
    logEvent('media-notes.play', { key, t: sec, from, found: h ? 'here' : 'missing' });
    if (h && typeof h.postMessage === 'function') { h.postMessage({ action: 'play', key, t: sec, from }); return { ok: true }; }
    return { ok: false, error: 'no player here' };
  }

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
    radialOuter: () => radialOuterItems(),
    selectionExtras: ids => selectionMatterItems(ids),
    onToolChange: tool => {
      const h = typeof window !== 'undefined' && window.webkit?.messageHandlers?.ui;
      if (h && typeof h.postMessage === 'function') h.postMessage({ inkTool: tool });
      // Derived from Spec: BUG-31 — pages hold still while annotating; the host turns its edge swipes off too.
      const locked = setPagesLocked(view, toolLocksPages(tool));
      if (h && typeof h.postMessage === 'function') h.postMessage({ pagesLocked: locked });
    },
    // FEAT-08 #2 · a stroke drawn over a frozen passage attaches to the word under its start.
    onStrokeAdded: stroke => {
      if (!Object.values(matterSide.passages).some(p => p.forms.ink && p.forms.ink.surface)) return;
      const p0 = stroke.points && stroke.points[0];
      const sd = view.scrollDOM;
      if (!p0 || !sd || !sd.getBoundingClientRect) return;
      const r = sd.getBoundingClientRect();
      const pos = view.posAtCoords({ x: r.left + p0[0] - sd.scrollLeft, y: r.top + p0[1] - sd.scrollTop });
      if (pos != null) applyMatter(m => matterCore.attachStrokeToWord(m, stroke.id, pos));
    }
  });

  // FEAT-08 · the Matter menu on a selection (pill, right-click, long-press).
  view.dom.addEventListener('pointerdown', e => {
    matterInput = e.pointerType === 'pen' ? 'pencil' : e.pointerType === 'touch' ? 'touch' : 'keys';
  }, true);
  view.dom.addEventListener('keydown', () => { matterInput = 'keys'; }, true);
  const matterMenuFor = (from, to) => matterCore.menuForSelection(
    matterCore.createMatter({ text: view.state.doc.toString(), ink: inkLayer ? inkLayer.getInk() : null, side: matterSide }), from, to);
  const runMatter = action => {
    // FEAT-08 P6 · "Play from mm:ss": the host plays the item from there; the matter is unchanged.
    if (action && action.play) return playMedia(action.key, action.t, 'passage');
    return applyMatter(m => action.run(m, { seed: matterSeed() }));
  };
  matterMenu = createMatterMenu({ mount: editorHost, view, getMenu: matterMenuFor, onRun: runMatter });
  // UI-04 P2 · the radial menu's outer ring places the same matter actions for the text selection (one list).
  radialOuterItems = () => {
    const r = view.state.selection.main;
    if (r.empty) return [];
    const menu = matterMenuFor(r.from, r.to);
    return (menu && menu.actions ? menu.actions : []).map(a => ({ id: a.id, label: a.label, pick: () => runMatter(a) }));
  };
  // UI-04 P11 (coordinator 2026-11-16) · lasso-selected strokes attached to exactly one passage: that passage's actions.
  selectionMatterItems = ids => {
    const pid = passageOfStrokes(matterSide.passages, ids);
    if (!pid) return [];
    const m = matterCore.createMatter({ text: view.state.doc.toString(), ink: inkLayer ? inkLayer.getInk() : null, side: matterSide });
    return matterCore.matterActions(m, pid).map(a => ({ id: a.id, label: a.label, pick: () => runMatter(a) }));
  };

  speaker = createSpeaker(typeof window !== 'undefined' ? window : null);
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

  // Recense what you typed (recense.js). Off until turned on (menu, toolbar's ✦, voice); recensing itself runs at rest
  // for the Chapters tab either way: a section quiet for 60 s, on power or battery above 30 %, or "Recense now".
  const uiHost = () => (typeof window !== 'undefined' ? window.webkit?.messageHandlers?.ui : null);
  let storage = null;
  try { storage = typeof localStorage !== 'undefined' ? localStorage : null; } catch { storage = null; }
  recense = createRecense({
    getText: () => view.state.doc.toString(),
    dispatch: spec => view.dispatch(spec),
    getCaret: () => view.state.selection.main.head,
    hasFocus: () => view.hasFocus,
    post: uiHost() ? m => uiHost().postMessage(m) : null,
    storage,
    // In-page wings (iOS, the browser) take the typed line directly; the Mac's wing panels get it from the host.
    wingCard: card => (dualWings ? dualWings.setTypedLine(card) : null),
    onChaptersChanged: () => { if (!outlineVisible) renderOutline(); },
    speak: (parts, handlers) => speaker?.speak(parts, handlers),
    stopSpeaking: () => speaker?.stop(),
    root: editorHost
  });
  const recenseBtn = document.createElement('button');
  recenseBtn.type = 'button';
  recenseBtn.className = 'rc-btn rc-recense-btn';
  recenseBtn.textContent = '✦';
  recenseBtn.title = 'Recense layer';
  recenseBtn.setAttribute('aria-label', 'Recense layer');
  toolbar.insertBefore(recenseBtn, menuWrap);
  const INTO = ['', ...LANGS];
  const INTO_NAMES = { '': 'Auto', ...LANG_NAMES };
  function syncRecenseControls() {
    const on = recense.isEnabled();
    recenseBtn.setAttribute('aria-pressed', String(on));
    recenseLayerBtn.setAttribute('aria-pressed', String(on));
    recenseLensBtn.textContent = `Lens: ${LENS_NAMES[recense.getLens()]}`;
    recenseLensBtn.hidden = !on;
    recenseIntoBtn.hidden = !on || recense.getLens() !== 'source';
    recenseReadBtn.hidden = !on || recense.getLens() === 'source';
    recenseIntoBtn.textContent = `Translate into: ${INTO_NAMES[recense.getTarget(currentPage(view.state))] || 'Auto'}`;
  }
  recenseActions = {
    toggle: on => { recense.setEnabled(on ?? !recense.isEnabled()); syncRecenseControls(); return recense.isEnabled(); },
    lens: name => { if (!recense.isEnabled()) recense.setEnabled(true); const l = name ? recense.setLens(name) : recense.nextLens(); syncRecenseControls(); return l; },
    readAloud: () => {
      if (recense.isPlaying()) { recense.stopReading(); return false; }      // the same command again stops it
      if (!recense.isEnabled()) { recense.setEnabled(true); syncRecenseControls(); }
      const ok = recense.readAloudAt(view.state.selection.main.head);
      if (!ok && !recense.isPlaying()) library?.toast('Nothing recensed here yet');
      return ok;
    },
    now: () => { const id = recense.recenseNow(); library?.toast(id ? 'Recensing in the background' : 'Everything is recensed'); return id; },
    into: () => {
      const i = currentPage(view.state);
      const next = INTO[(INTO.indexOf(recense.getTarget(i)) + 1) % INTO.length];
      recense.setTarget(i, next);
      syncRecenseControls();
      return next;
    }
  };
  recenseBtn.addEventListener('click', () => recenseActions.toggle());
  recenseLayerBtn.addEventListener('click', () => { closeMenu(); recenseActions.toggle(); });
  recenseLensBtn.addEventListener('click', () => { closeMenu(); recenseActions.lens(); });
  recenseNowBtn.addEventListener('click', () => { closeMenu(); recenseActions.now(); });
  recenseReadBtn.addEventListener('click', () => { closeMenu(); recenseActions.readAloud(); });
  recenseIntoBtn.addEventListener('click', () => { closeMenu(); recenseActions.into(); });
  syncRecenseControls();
  recense.redraw();
  // Every 15 s, at rest: if a section has been quiet for a minute, ask the host about power, then recense.
  if (typeof setInterval === 'function') {
    setInterval(() => {
      if (!recense.due().length) return;
      if (uiHost()) uiHost().postMessage({ powerState: true });
      else recense.tick();
    }, 15_000)?.unref?.();
  }

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
    if (!wasVisible && recense) recense.freeze();   // titles hold still while the panel is open
    outlinePanel.hidden = false;
    outlineToggleBtn.setAttribute('aria-pressed', 'true');
    if (!wasVisible) renderOutline();
    if (!wasVisible) postHaptic('open');
  }

  function hideOutline() {
    outlineVisible = false;
    chapterActionsFor = -1;
    if (recense) recense.unfreeze();
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

  // UI-07 · a size the person (or a host) picks wins over the device default until reload.
  function setFontSize(px) {
    userFontSize = true;
    applyFontSize(px);
  }

  function applyFontSize(px) {
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
    newPage: () => (newPage(view) ? 'ok' : 'bounce'),
    promotePage: () => (promotePage(view, currentPage(view.state)) ? 'ok' : 'bounce'),
    slotPage: n => (slotPage(view, n) ? 'ok' : 'bounce'),
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
    swapWings: () => (dualWings ? dualWings.swapWings() : null),
    recenseNow: () => recenseActions?.now(),
    readRecenseLens: () => recenseActions?.readAloud(),
    toggleRecense: on => recenseActions?.toggle(on),
    setRecenseLens: name => recenseActions?.lens(name)
  };

  const voiceCommand = phrase => executeVoiceMove(phrase, voiceHandlers);

  // Derived from Spec: BUG-08. True while the owner holds the pointer down over the text: a drag-selection in
  // progress. The host's setText (autosave, a merge from another device) waits for it to end, so the document never
  // moves under their hand mid-highlight.
  let dragSelecting = false;

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
    isSelecting: () => dragSelecting,
    extra: {
      step: delta => (stepPage(view, Number(delta) || 0, { allowCreate: true }) ? 'ok' : 'bounce'),
      swipeLeftToRight: () => (swipeLeftToRight(view, { allowCreate: true }) ? 'ok' : 'bounce'),
      swipeRightToLeft: () => (swipeRightToLeft(view) ? 'ok' : 'bounce'),
      openNewWindowOnLeft: () => (openNewWindowOnLeft(view) ? 'ok' : 'bounce'),
      deleteEmptyWindow: () => (deleteEmptyWindow(view) ? 'ok' : 'bounce'),
      showPage: i => showPage(view, Number(i) || 0),
      reopen: () => reopen(),
      goToPage: i => (goToPage(view, Number(i)) ? 'ok' : 'bounce'),
      newPage: () => (newPage(view) ? 'ok' : 'bounce'),
      promotePage: i => (promotePage(view, i == null ? currentPage(view.state) : Number(i)) ? 'ok' : 'bounce'),
      setPageSlot: (i, n) => (setPageSlot(view, Number(i), n == null ? null : Number(n)) ? 'ok' : 'bounce'),
      slotPage: n => (slotPage(view, Number(n)) ? 'ok' : 'bounce'),
      currentPage: () => currentPage(view.state),
      pageCount: () => pageCount(view.state),
      setPageMode: on => setPages(on),
      // Mac host: native trackpad swipe (strip/editorhost.swift EditorWebView.scrollWheel); turns off the web wheel pager.
      // Derived from Spec: BUG-08 — a trackpad swipe while the owner is dragging a selection moved the page under
      // the pointer, so the drag ended on a different character than they were pointing at.
      nativeSwipe: (dx, ended) => {
        if (dragSelecting) return 'selecting';
        view.__nativeWheel = true;
        return view.__hostSwipe ? view.__hostSwipe(dx, ended) : 'off';
      },
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
      // FEAT-08 · one matter: draftpad.matter.json beside draftpad.md and draftpad.ink.json (src/matter.js).
      getMatter: () => JSON.stringify(matterSide),
      setMatter: data => {
        matterSide = matterCore.fromFiles({ [matterCore.FILES.side]: typeof data === 'string' ? data : JSON.stringify(data || {}) }).side;
      },
      mergeMatter: remote => {
        const r = typeof remote === 'string' ? JSON.parse(remote) : remote;
        matterSide = matterCore.mergeMatter(matterSide, r);
        postMatter();
        return JSON.stringify(matterSide);
      },
      seedPassage: (state, args) => applyMatter(m => {
        const a = typeof args === 'string' ? JSON.parse(args) : args;
        if (state === 'ink') return matterCore.seedInkPassage(m, a);
        if (state === 'voice') return matterCore.seedVoicePassage(m, a);
        return matterCore.seedTypePassage(m, a);
      }),
      cross: (n, pid, opts) => applyMatter(m => matterCore.cross(m, Number(n), String(pid), typeof opts === 'string' ? JSON.parse(opts) : opts || {})),
      reverseCrossing: () => applyMatter(m => matterCore.reverseLast(m, { device: matterDevice.get() })),   // per device
      // FEAT-08 P2 · spoken words from the host land at the end as their own voice passage; the caret stays.
      appendVoice: (text, id) => applyMatter(m => matterCore.appendVoicePassage(m, {
        id: String(id || `vo-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`),
        text,
        seed: { ...matterSeed(), input: 'voice' }   // FEAT-08 P6: in a media note, with the item's second
      })),
      setMatterDevice: name => matterDevice.set(name),
      // The Matter menu as data (any menu, radial or voice can place it): [{ id, label, from, to }].
      matterMenu: (from, to) => {
        const m = matterCore.createMatter({ text: view.state.doc.toString(), ink: inkLayer ? inkLayer.getInk() : null, side: matterSide });
        return matterCore.menuForSelection(m, Number(from), Number(to)).actions.map(({ id, label, from: f, to: t }) => ({ id, label, from: f, to: t }));
      },
      runMatterAction: (id, from, to) => {
        const m = matterCore.createMatter({ text: view.state.doc.toString(), ink: inkLayer ? inkLayer.getInk() : null, side: matterSide });
        const a = matterCore.menuForSelection(m, Number(from), Number(to)).actions.find(x => x.id === id);
        return a ? applyMatter(mm => a.run(mm, { seed: matterSeed() })) : { ok: false, error: 'not available here' };
      },
      openMatterMenu: () => (matterMenu ? matterMenu.open() : false),
      crossings: () => matterCore.CROSSINGS.map(c => ({ ...c })),
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
      // Recense what you typed: the host's answers (shared/recensetext.swift).
      setRecenseSection: (id, json) => (recense ? recense.setSection(String(id), json) : false),
      recenseDone: id => (recense ? recense.recenseDone(String(id)) : null),
      setRecenseSource: (id, json) => (recense ? recense.setSource(String(id), json) : 0),
      setRecensedList: () => null,
      setPowerState: (onPower, percent) => {
        if (!recense) return null;
        recense.setPowerState(onPower, percent);
        return recense.tick();
      },
      recenseNow: () => recenseActions?.now(),
      readRecenseLens: () => recenseActions?.readAloud(),
      // Read-aloud word reports and the end, from the host's voice (shared/draftpadlibrary.swift ReadAloud). Both hosts
      // call `window.recenseEditor.<fn>`, so speech.js's window hooks are reached through here; without this the spoken
      // word was never lit and a read never ended on the page (Chapters' Play, playlists, lenses).
      speechProgress: (id, part, from, len) => (typeof window !== 'undefined' ? window.speechProgress?.(id, part, from, len) : undefined),
      speechDone: id => (typeof window !== 'undefined' ? window.speechDone?.(id) : undefined),
      setRecenseLayer: on => recenseActions?.toggle(Boolean(on)),
      setRecenseLens: name => recenseActions?.lens(String(name || '')),
      // For checks (`recense draftpad-check`): how far recensing has got, and the wing card for a caret offset.
      recenseStatus: () => (recense ? {
        sections: recense.sections().length,
        recensed: recense.sections().filter(s => recense.results.has(s.key)).length,
        inflight: recense.inflight.size,
        engines: [...new Set(recense.sections().map(s => recense.results.get(s.key)?.engine).filter(Boolean))],
        lens: recense.getLens(), on: recense.isEnabled(), missing: recense.missing()
      } : null),
      // Per section: paragraphs, Gist lines, page-gist lines, filled extracts, dropped lines, lines in two languages.
      recenseShape: () => (recense ? recense.sections().map(s => {
        const r = recense.results.get(s.key);
        const all = r ? [...(r.page || []), ...r.gist, ...r.reformat.lines] : [];
        return { paras: new Set(s.sentences.map(x => x.p)).size, sentences: s.sentences.length, lang: r?.lang || '',
          gist: r?.gist.length ?? -1, page: r?.page?.length ?? -1, extract: all.filter(l => l.extract).length,
          dropped: r?.dropped ?? 0, droppedLines: r?.droppedLines || [], mixed: all.filter(l => !l.extract && isMixed({ ...l, lang: r.lang },
            s.sentences.filter(x => l.from.includes(x.key)).map(x => x.text), r.glossary)).map(l => l.text) };
      }) : null),
      recenseCardAt: offset => {
        const card = recense ? recense.cardFor(Number(offset)) : null;
        if (dualWings) dualWings.setTypedLine(card);
        return card;
      },
      // Derived from Spec: UI-04 P1 — the host sends every squeeze phase with the hover point:
      // released before 250 ms toggles the palette; held opens the radial menu (UI-04 P2) at the hover point.
      onPencilSqueeze: (phase, x, y) => {
        if (!inkLayer) return 'idle';
        if (!pencilSqueeze) {
          pencilSqueeze = squeezeHost({
            toggle: () => { postHaptic('squeeze'); return inkLayer.toggleMenu(); },
            radial: () => (typeof inkLayer.radialMenu === 'function' ? inkLayer.radialMenu() : null)
          });
        }
        return pencilSqueeze(String(phase), Number(x), Number(y));
      },
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
      updateAudioTime: sec => {
        playheadKey = audioSidecar.getState().sourceKey;   // FEAT-08 P6: whose second this is
        return audioSidecar.updateTime(sec);
      },
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

  // UI-06 R1 · the host's first text is the file opening: land on the page last used on this device.
  {
    const hostSetText = bridge.api.setText;
    let first = true;
    bridge.api.setText = text => {
      const r = hostSetText(text);
      if (first && view) { first = false; reopen(); }
      return r;
    };
  }

  menuBtn.addEventListener('click', e => {
    e.stopPropagation();
    toggleMenu();
  });

  toolbar.addEventListener('pointerenter', () => setToolbarFaded(false));
  toolbar.addEventListener('mousemove', () => setToolbarFaded(false));
  toolbar.addEventListener('touchstart', () => setToolbarFaded(false), { passive: true });
  // UI-06 · lifting a finger on the bar is not leaving it: without this the haptic-zone pointerup faded the bar
  // after every tap, so the next tap on touch landed on the page behind (T-0024 "top strip fails mobile").
  toolbar.addEventListener('pointerup', e => e.stopPropagation());
  toolbar.addEventListener('touchend', e => e.stopPropagation(), { passive: true });
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

  document.addEventListener('pointerdown', e => { if (!dotSheet.hidden && !dotSheet.contains(e.target)) closeDotSheet(); });
  newPageNavBtn.addEventListener('click', () => { setToolbarFaded(false); newPage(view); });
  newerNavBtn.addEventListener('click', () => { setToolbarFaded(false); swipeLeftToRight(view, { allowCreate: false }); });
  olderNavBtn.addEventListener('click', () => { setToolbarFaded(false); swipeRightToLeft(view); });
  newPageMenuBtn.addEventListener('click', () => { closeMenu(); newPage(view); });
  promoteMenuBtn.addEventListener('click', () => { closeMenu(); promotePage(view, currentPage(view.state)); });
  deletePageMenuBtn.addEventListener('click', () => { closeMenu(); deleteEmptyWindow(view); updatePageIndicator(); });
  slotMenuBtn.addEventListener('click', e => {
    e.stopPropagation();
    closeMenu();
    const i = currentPage(view.state);
    openDotSheet(i, pageIndicator.querySelector(`[data-page="${i}"]`) || menuBtn);
  });
  largerTextBtn.addEventListener('click', () => { setFontSize(stepFontSize(currentFontSize, 1)); });
  smallerTextBtn.addEventListener('click', () => { setFontSize(stepFontSize(currentFontSize, -1)); });

  outlineToggleBtn.addEventListener('click', () => {
    closeMenu();
    if (outlineVisible) hideOutline();
    else showOutline();
  });

  prevPageBtn.addEventListener('click', () => {
    closeMenu();
    swipeLeftToRight(view, { allowCreate: false });
  });

  nextPageBtn.addEventListener('click', () => {
    closeMenu();
    swipeRightToLeft(view);
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

  playFileBtn.addEventListener('click', () => {
    closeMenu();
    filePlayer.pick();
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

  // Derived from Spec: BUG-08. A drag-selection is in progress from pointerdown in the text until the pointer comes
  // up (anywhere — the owner often releases outside the text). Whatever the host sent meanwhile lands then, once.
  if (view && view.contentDOM && typeof view.contentDOM.addEventListener === 'function') {
    view.contentDOM.addEventListener('pointerdown', e => {
      if (e && e.button !== undefined && e.button !== 0) return;      // only a plain press selects
      dragSelecting = true;
    }, true);
  }
  const endDragSelection = () => {
    if (!dragSelecting) return;
    dragSelecting = false;
    if (bridge && typeof bridge.applyDeferredText === 'function') bridge.applyDeferredText();
  };
  if (typeof window !== 'undefined' && typeof window.addEventListener === 'function') {
    window.addEventListener('pointerup', endDragSelection, true);
    window.addEventListener('pointercancel', endDragSelection, true);
    window.addEventListener('blur', endDragSelection, true);          // the pointer can be lost with the window
  }

  setTheme(currentTheme);
  applyFontSize(currentFontSize);

  // UI-07 · the box for this device and orientation, again on every rotation or resize.
  function applyDeviceLayout() {
    if (typeof window === 'undefined' || !document.documentElement) return;
    const touch = typeof window.matchMedia === 'function' && window.matchMedia('(any-pointer: coarse)').matches;
    const layout = deviceLayout(window.innerWidth, window.innerHeight, touch);
    // An empty value removes the variable, so the Mac box's fallbacks apply again.
    for (const [k, v] of Object.entries(layoutVars(layout))) document.documentElement.style.setProperty(k, v ?? '');
    if (layout && !userFontSize) applyFontSize(layout.fontSize);
    view.requestMeasure();
  }
  applyDeviceLayout();
  if (typeof window !== 'undefined' && window.addEventListener) window.addEventListener('resize', applyDeviceLayout);
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
