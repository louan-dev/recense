import { inspectDraftpadPages, PAGE_MARKER, isFullDateLine } from './pages.js';
import { parseHeadingLine } from './outline.js';

/**
 * Formats a time in seconds to MM:SS or H:MM:SS for audio timestamps.
 */
export function formatTimestamp(seconds) {
  const s = Math.max(0, Number(seconds) || 0);
  const totalSecs = Math.floor(s);
  const hours = Math.floor(totalSecs / 3600);
  const mins = Math.floor((totalSecs % 3600) / 60);
  const secs = totalSecs % 60;
  if (hours > 0) {
    return `${hours}:${String(mins).padStart(2, '0')}:${String(secs).padStart(2, '0')}`;
  }
  return `${String(mins).padStart(2, '0')}:${String(secs).padStart(2, '0')}`;
}

/**
 * Normalizes cue objects to ensure consistent structure.
 */
export function normalizeCues(cues) {
  if (!Array.isArray(cues)) return [];
  return cues.map((c, i) => ({
    id: c.id ? String(c.id) : `cue-${i}-${Math.round((Number(c.start) || 0) * 1000)}`,
    start: Math.max(0, Number(c.start) || 0),
    end: Math.max(0, Number(c.end) || 0),
    text: String(c.text ?? '').trim(),
    speaker: String(c.speaker ?? '').trim(),
    bookmarked: Boolean(c.bookmarked),
    annotation: String(c.annotation ?? '').trim(),
    inkStrokes: Array.isArray(c.inkStrokes) ? c.inkStrokes : []
  }));
}

/**
 * Returns the index of the cue covering `timeSec`, or the latest cue started
 * before `timeSec` while playing for live karaoke-style transcript tracking.
 * Returns -1 if no cue has started yet or cues array is empty.
 */
export function activeCueIndexAt(cues, timeSec) {
  if (!Array.isArray(cues) || cues.length === 0) return -1;
  const t = Number(timeSec) || 0;
  if (t < cues[0].start) return -1;

  // 1. Direct span match: cue.start <= t <= cue.end
  for (let i = 0; i < cues.length; i++) {
    const cue = cues[i];
    if (t >= cue.start && t <= cue.end) {
      return i;
    }
  }

  // 2. Gap between cues or past last cue.end: latest cue started before t
  let latestIdx = -1;
  for (let i = 0; i < cues.length; i++) {
    if (cues[i].start <= t) {
      latestIdx = i;
    } else {
      break;
    }
  }
  return latestIdx;
}

/**
 * Bookmarks a cue, updates state.bookmarks, posts { haptic: 'snap' } to UI bridge,
 * and posts { action: 'bookmark', cueId, time, text, note } to audio bridge.
 */
export function bookmarkCue(
  state,
  cueIndex,
  note = '',
  { globalObj = typeof window !== 'undefined' ? window : null } = {}
) {
  if (!state || !Array.isArray(state.cues)) return null;
  const idx = Number(cueIndex);
  if (idx < 0 || idx >= state.cues.length) return null;

  const cue = state.cues[idx];
  cue.bookmarked = true;

  if (!Array.isArray(state.bookmarks)) {
    state.bookmarks = [];
  }

  const noteStr = String(note ?? '').trim();
  let bookmark = state.bookmarks.find(b => b.cueId === cue.id);
  if (bookmark) {
    bookmark.note = noteStr;
    bookmark.time = cue.start;
    bookmark.text = cue.text;
  } else {
    bookmark = {
      cueId: cue.id,
      time: cue.start,
      text: cue.text,
      note: noteStr,
      createdAt: Date.now()
    };
    state.bookmarks.push(bookmark);
  }

  // Post haptic snap to UI message handler
  if (globalObj?.webkit?.messageHandlers?.ui?.postMessage) {
    globalObj.webkit.messageHandlers.ui.postMessage({ haptic: 'snap' });
  }

  // Post bookmark action to audio message handler
  if (globalObj?.webkit?.messageHandlers?.audio?.postMessage) {
    globalObj.webkit.messageHandlers.audio.postMessage({
      action: 'bookmark',
      cueId: cue.id,
      time: cue.start,
      text: cue.text,
      note: noteStr
    });
  }

  return bookmark;
}

/**
 * Toggles bookmark status of cue: if bookmarked, removes bookmark and posts unbookmark action;
 * if unbookmarked, marks bookmarked and adds to state.bookmarks.
 */
export function toggleBookmarkCue(
  state,
  cueIndex,
  note = '',
  { globalObj = typeof window !== 'undefined' ? window : null } = {}
) {
  if (!state || !Array.isArray(state.cues)) return null;
  const idx = Number(cueIndex);
  if (idx < 0 || idx >= state.cues.length) return null;

  const cue = state.cues[idx];
  if (cue.bookmarked) {
    cue.bookmarked = false;
    if (Array.isArray(state.bookmarks)) {
      state.bookmarks = state.bookmarks.filter(b => b.cueId !== cue.id);
    }
    if (globalObj?.webkit?.messageHandlers?.ui?.postMessage) {
      globalObj.webkit.messageHandlers.ui.postMessage({ haptic: 'snap' });
    }
    if (globalObj?.webkit?.messageHandlers?.audio?.postMessage) {
      globalObj.webkit.messageHandlers.audio.postMessage({
        action: 'unbookmark',
        cueId: cue.id,
        time: cue.start
      });
    }
    return null;
  }

  return bookmarkCue(state, cueIndex, note, { globalObj });
}

/**
 * Attaches annotationText to cues[cueIndex].annotation, optionally inserts
 * a timestamped reference (`[@MM:SS] text — annotation`) into the active
 * Draftpad window via `onInsertToPage`, and posts { action: 'annotate', ... } to audio bridge.
 */
export function annotateCue(
  state,
  cueIndex,
  annotationText,
  { onInsertToPage = null, globalObj = typeof window !== 'undefined' ? window : null } = {}
) {
  if (!state || !Array.isArray(state.cues)) return null;
  const idx = Number(cueIndex);
  if (idx < 0 || idx >= state.cues.length) return null;

  const cue = state.cues[idx];
  const textStr = String(annotationText ?? '').trim();
  cue.annotation = textStr;

  const timestamp = formatTimestamp(cue.start);
  const reference = textStr.length > 0
    ? `[@${timestamp}] ${cue.text} — ${textStr}`
    : `[@${timestamp}] ${cue.text}`;

  if (typeof onInsertToPage === 'function') {
    onInsertToPage(reference);
  }

  if (globalObj?.webkit?.messageHandlers?.audio?.postMessage) {
    globalObj.webkit.messageHandlers.audio.postMessage({
      action: 'annotate',
      cueId: cue.id,
      time: cue.start,
      annotation: textStr
    });
  }

  return { cue, reference };
}

/**
 * Creates lightweight mock element when global document is not available in headless environments.
 */
function createMockElement(tag) {
  const listeners = {};
  const attributes = {};
  const classListSet = new Set();

  const el = {
    tagName: tag.toUpperCase(),
    hidden: false,
    value: '',
    textContent: '',
    innerHTML: '',
    children: [],
    style: {},
    classList: {
      add(...classes) {
        for (const c of classes) if (c) classListSet.add(c);
      },
      remove(...classes) {
        for (const c of classes) classListSet.delete(c);
      },
      contains(c) {
        return classListSet.has(c);
      },
      toggle(c, force) {
        if (force === true) classListSet.add(c);
        else if (force === false) classListSet.delete(c);
        else if (classListSet.has(c)) classListSet.delete(c);
        else classListSet.add(c);
        return classListSet.has(c);
      }
    },
    setAttribute(k, v) {
      attributes[k] = String(v);
      if (k === 'hidden') el.hidden = true;
      if (k === 'class') {
        classListSet.clear();
        String(v).split(/\s+/).forEach(c => {
          if (c) classListSet.add(c);
        });
      }
    },
    getAttribute(k) {
      return attributes[k] ?? null;
    },
    removeAttribute(k) {
      delete attributes[k];
      if (k === 'hidden') el.hidden = false;
    },
    hasAttribute(k) {
      return k in attributes;
    },
    appendChild(child) {
      el.children.push(child);
      child.parentElement = el;
      return child;
    },
    removeChild(child) {
      const idx = el.children.indexOf(child);
      if (idx !== -1) {
        el.children.splice(idx, 1);
        child.parentElement = null;
      }
      return child;
    },
    replaceChildren(...newChildren) {
      el.children = [];
      for (const c of newChildren) {
        el.appendChild(c);
      }
    },
    addEventListener(type, fn) {
      if (!listeners[type]) listeners[type] = [];
      listeners[type].push(fn);
    },
    removeEventListener(type, fn) {
      if (!listeners[type]) return;
      listeners[type] = listeners[type].filter(f => f !== fn);
    },
    dispatchEvent(event) {
      const type = event?.type || 'click';
      const fns = [...(listeners[type] || [])];
      for (const fn of fns) {
        fn(event);
      }
    },
    scrollIntoView() {},
    focus() {}
  };

  Object.defineProperty(el, 'className', {
    get() {
      return Array.from(classListSet).join(' ');
    },
    set(v) {
      classListSet.clear();
      if (typeof v === 'string') {
        v.split(/\s+/).forEach(c => {
          if (c) classListSet.add(c);
        });
      }
    }
  });

  return el;
}

function makeDomElement(doc, tag, props = {}, attrs = {}) {
  const isSvg = tag === 'svg' || tag === 'path' || tag === 'circle' || tag === 'line' || tag === 'ellipse';
  let el;
  if (doc && typeof doc.createElementNS === 'function' && isSvg) {
    el = doc.createElementNS('http://www.w3.org/2000/svg', tag);
  } else if (doc && typeof doc.createElement === 'function') {
    el = doc.createElement(tag);
  } else {
    el = createMockElement(tag);
  }

  for (const [k, v] of Object.entries(props)) {
    if (k === 'style' && typeof v === 'object') {
      if (el.style) Object.assign(el.style, v);
    } else {
      el[k] = v;
    }
  }

  for (const [k, v] of Object.entries(attrs)) {
    if (v !== undefined && v !== null) {
      if (typeof el.setAttribute === 'function') {
        el.setAttribute(k, String(v));
      } else {
        el[k] = String(v);
      }
    }
  }

  return el;
}

function strokeToPathData(stroke) {
  if (stroke?.d) return stroke.d;
  const pts = stroke?.points || [];
  if (pts.length === 0) return '';
  const getX = p => (Array.isArray(p) ? p[0] : (p?.x ?? 0));
  const getY = p => (Array.isArray(p) ? p[1] : (p?.y ?? 0));
  let d = `M ${getX(pts[0])} ${getY(pts[0])}`;
  for (let i = 1; i < pts.length; i++) {
    d += ` L ${getX(pts[i])} ${getY(pts[i])}`;
  }
  return d;
}

function renderCueInkStroke(doc, stroke) {
  const d = strokeToPathData(stroke);
  if (!d) return null;
  const path = makeDomElement(doc, 'path', {}, {
    d,
    fill: 'none',
    stroke: stroke.color || '#38bdf8',
    'stroke-width': String(stroke.width || 2),
    'stroke-linecap': 'round',
    'stroke-linejoin': 'round'
  });
  return path;
}

/**
 * Creates the DOM side panel beside the editor page for live audio transcripts.
 * Zero buttons, zero words, and zero icons at rest: renders only timestamp, text,
 * quiet dot (.rc-transcript-cue-dot, '●' when bookmarked), note text (.rc-transcript-cue-note, hidden when empty),
 * and ink SVG (.rc-cue-ink-svg). Progressive disclosure reveals borderless placeholder-free annotation input.
 */
export function createTranscriptPane(container, options = {}) {
  const globalObj = options.globalObj ?? (typeof window !== 'undefined' ? window : null);
  const doc = options.doc ?? container?.ownerDocument ?? (typeof document !== 'undefined' ? document : null);
  const onInsertToPage = options.onInsertToPage ?? null;
  const onSeek = options.onSeek ?? null;
  const onClose = options.onClose ?? null;
  const sidecar = options.sidecar ?? null;

  const pane = makeDomElement(doc, 'aside', { className: 'rc-transcript-pane', hidden: true }, {
    'aria-label': 'Live audio transcript',
    role: 'complementary'
  });

  const header = makeDomElement(doc, 'header', { className: 'rc-transcript-header' });
  const titleEl = makeDomElement(doc, 'h3', {
    className: 'rc-transcript-title',
    textContent: 'Live Transcript'
  });
  // Close control without button element and without close button text (✕)
  const closeControl = makeDomElement(doc, 'span', {
    className: 'rc-transcript-close',
    textContent: ''
  }, {
    'aria-label': 'Close transcript',
    role: 'button',
    tabindex: '0'
  });

  header.appendChild(titleEl);
  header.appendChild(closeControl);
  pane.appendChild(header);

  const cuesContainer = makeDomElement(doc, 'div', { className: 'rc-transcript-cues' }, {
    role: 'feed',
    'aria-label': 'Transcript cues'
  });
  pane.appendChild(cuesContainer);

  let activeIndex = -1;
  let currentCues = [];
  let cueElements = [];

  function handleSeek(timeSec) {
    if (typeof onSeek === 'function') {
      onSeek(timeSec);
    }
    if (sidecar && typeof sidecar.seek === 'function') {
      sidecar.seek(timeSec);
    } else if (globalObj?.webkit?.messageHandlers?.audio?.postMessage) {
      globalObj.webkit.messageHandlers.audio.postMessage({ action: 'seek', time: timeSec });
    }
  }

  function handleBookmarkToggle(cueIndex, note = '') {
    if (sidecar && typeof sidecar.toggleBookmarkCue === 'function') {
      sidecar.toggleBookmarkCue(cueIndex, note);
    } else if (sidecar && typeof sidecar.bookmarkCue === 'function') {
      const st = sidecar.getState();
      toggleBookmarkCue(st, cueIndex, note, { globalObj });
      updateCue(cueIndex);
    } else if (options.state) {
      toggleBookmarkCue(options.state, cueIndex, note, { globalObj });
      updateCue(cueIndex);
    }
  }

  function handleAnnotate(cueIndex, text, insert = false) {
    const insertFn = insert ? onInsertToPage : null;
    if (sidecar && typeof sidecar.annotateCue === 'function') {
      sidecar.annotateCue(cueIndex, text, { onInsertToPage: insertFn });
    } else if (options.state) {
      annotateCue(options.state, cueIndex, text, { onInsertToPage: insertFn, globalObj });
      updateCue(cueIndex);
    }
  }

  function buildCueElement(cue, index) {
    const cueEl = makeDomElement(doc, 'article', {
      className: `rc-transcript-cue${cue.bookmarked ? ' is-bookmarked' : ''}`
    }, {
      'data-cue-index': index,
      'data-cue-id': cue.id,
      tabindex: '0'
    });

    // 1. Timestamp
    const timeEl = makeDomElement(doc, 'time', {
      className: 'rc-transcript-cue-time',
      textContent: formatTimestamp(cue.start)
    }, {
      'data-start': cue.start
    });
    cueEl.appendChild(timeEl);

    // Speaker if present
    if (cue.speaker) {
      const speakerEl = makeDomElement(doc, 'span', {
        className: 'rc-transcript-cue-speaker',
        textContent: `${cue.speaker}: `
      });
      cueEl.appendChild(speakerEl);
    }

    // 2. Spoken text
    const textEl = makeDomElement(doc, 'span', {
      className: 'rc-transcript-cue-text',
      textContent: cue.text
    });
    cueEl.appendChild(textEl);

    // 3. Quiet dot: ● only when bookmarked, empty "" when not bookmarked
    const dotEl = makeDomElement(doc, 'span', {
      className: 'rc-transcript-cue-dot',
      textContent: cue.bookmarked ? '●' : ''
    }, {
      'aria-hidden': 'true'
    });
    cueEl.appendChild(dotEl);

    // 4. Existing note text: hidden when empty
    const noteEl = makeDomElement(doc, 'span', {
      className: 'rc-transcript-cue-note',
      textContent: cue.annotation || '',
      hidden: !cue.annotation
    }, {
      ...(cue.annotation ? {} : { hidden: 'true' })
    });
    cueEl.appendChild(noteEl);

    // 5. SVG for ink strokes
    const inkSvg = makeDomElement(doc, 'svg', {
      className: 'rc-cue-ink-svg'
    });
    if (Array.isArray(cue.inkStrokes)) {
      for (const stroke of cue.inkStrokes) {
        const path = renderCueInkStroke(doc, stroke);
        if (path) inkSvg.appendChild(path);
      }
    }
    cueEl.appendChild(inkSvg);

    // 6. Progressively disclosed borderless placeholder-free annotation input
    const annotInput = makeDomElement(doc, 'input', {
      className: 'rc-transcript-annot-input',
      type: 'text',
      value: cue.annotation || '',
      hidden: true
    }, {
      hidden: 'true',
      'aria-label': 'Cue annotation'
    });
    cueEl.appendChild(annotInput);

    function revealInput() {
      annotInput.hidden = false;
      annotInput.removeAttribute('hidden');
      annotInput.focus();
    }

    function commitAnnotation() {
      const val = annotInput.value.trim();
      annotInput.hidden = true;
      annotInput.setAttribute('hidden', 'true');
      handleAnnotate(index, val, true);
      noteEl.textContent = val;
      if (val) {
        noteEl.hidden = false;
        noteEl.removeAttribute('hidden');
      } else {
        noteEl.hidden = true;
        noteEl.setAttribute('hidden', 'true');
      }
    }

    // Pen ink stroke drawing capture
    let activePenPoints = null;
    let activePathEl = null;

    cueEl.addEventListener('pointerdown', e => {
      if (e?.pointerType === 'pen') {
        const x = e.clientX ?? 0;
        const y = e.clientY ?? 0;
        const p = e.pressure ?? 0.5;
        activePenPoints = [[x, y, p, Date.now()]];
        activePathEl = makeDomElement(doc, 'path', {}, {
          d: `M ${x} ${y}`,
          fill: 'none',
          stroke: '#38bdf8',
          'stroke-width': '2',
          'stroke-linecap': 'round',
          'stroke-linejoin': 'round'
        });
        inkSvg.appendChild(activePathEl);
        return;
      }
      startDwellTimer();
    });

    cueEl.addEventListener('pointermove', e => {
      if (activePenPoints && e?.pointerType === 'pen') {
        const x = e.clientX ?? 0;
        const y = e.clientY ?? 0;
        const p = e.pressure ?? 0.5;
        activePenPoints.push([x, y, p, Date.now()]);
        let d = `M ${activePenPoints[0][0]} ${activePenPoints[0][1]}`;
        for (let i = 1; i < activePenPoints.length; i++) {
          d += ` L ${activePenPoints[i][0]} ${activePenPoints[i][1]}`;
        }
        activePathEl?.setAttribute('d', d);
        return;
      }
    });

    cueEl.addEventListener('pointerup', e => {
      if (activePenPoints && e?.pointerType === 'pen') {
        const stroke = {
          id: `cue-ink-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
          points: activePenPoints,
          tool: 'pen',
          color: '#38bdf8',
          width: 2,
          device: 'pen',
          at: Date.now()
        };
        if (!Array.isArray(cue.inkStrokes)) {
          cue.inkStrokes = [];
        }
        cue.inkStrokes.push(stroke);
        activePenPoints = null;
        activePathEl = null;

        // Mark cue annotated
        if (!cue.annotation) {
          cue.annotation = '[ink annotation]';
          noteEl.textContent = cue.annotation;
          noteEl.hidden = false;
          noteEl.removeAttribute('hidden');
        }
        handleAnnotate(index, cue.annotation, false);
        return;
      }
      clearDwellTimer();
    });

    cueEl.addEventListener('pointercancel', () => {
      activePenPoints = null;
      activePathEl = null;
      clearDwellTimer();
    });

    // Progressive disclosure: dwell timer (>= 280ms)
    let dwellTimer = null;
    let didDwell = false;

    function startDwellTimer() {
      didDwell = false;
      if (dwellTimer !== null) clearTimeout(dwellTimer);
      dwellTimer = setTimeout(() => {
        didDwell = true;
        revealInput();
      }, 280);
    }

    function clearDwellTimer() {
      if (dwellTimer !== null) {
        clearTimeout(dwellTimer);
        dwellTimer = null;
      }
    }

    // Right-click reveals input
    cueEl.addEventListener('contextmenu', e => {
      e?.preventDefault?.();
      revealInput();
    });

    // Enter on cue reveals input; Enter inside input commits annotation
    cueEl.addEventListener('keydown', e => {
      if (e?.key === 'Enter') {
        if (e.target === annotInput) {
          e.preventDefault?.();
          commitAnnotation();
        } else {
          e.preventDefault?.();
          revealInput();
        }
      }
    });

    annotInput.addEventListener('blur', () => {
      commitAnnotation();
    });

    // Click/tap seeks audio (unless input was revealed or dwelling occurred)
    cueEl.addEventListener('click', e => {
      if (e?.target === annotInput || didDwell) {
        didDwell = false;
        return;
      }
      handleSeek(cue.start);
    });

    // Double-click toggles bookmark
    cueEl.addEventListener('dblclick', () => {
      handleBookmarkToggle(index);
    });

    // Touch gestures: swiping left-to-right (dx >= 36) or double-tap toggles bookmark
    let touchStartX = null;
    let touchStartY = null;
    let lastTap = 0;

    cueEl.addEventListener('touchstart', e => {
      const t = e.touches && e.touches[0];
      if (t) {
        touchStartX = t.clientX;
        touchStartY = t.clientY;
      }
      startDwellTimer();
    });

    cueEl.addEventListener('touchend', e => {
      clearDwellTimer();
      const now = Date.now();
      if (now - lastTap < 350) {
        handleBookmarkToggle(index);
        lastTap = 0;
        return;
      }
      lastTap = now;

      if (touchStartX !== null) {
        const t = e.changedTouches && e.changedTouches[0];
        if (t) {
          const dx = t.clientX - touchStartX;
          const dy = t.clientY - (touchStartY ?? t.clientY);
          // Swipe left-to-right (dx >= 36) toggles bookmark
          if (dx >= 36 && Math.abs(dy) < 30) {
            handleBookmarkToggle(index);
          }
        }
      }
      touchStartX = null;
      touchStartY = null;
    });

    cueEl.addEventListener('touchcancel', () => {
      clearDwellTimer();
      touchStartX = null;
      touchStartY = null;
    });

    return cueEl;
  }

  function updateCue(index) {
    if (index < 0 || index >= currentCues.length) return;
    const cue = currentCues[index];
    const el = cueElements[index];
    if (!el) return;

    if (cue.bookmarked) {
      el.classList.add('is-bookmarked');
    } else {
      el.classList.remove('is-bookmarked');
    }

    const dotEl = el.children?.find?.(c => c.classList?.contains('rc-transcript-cue-dot'))
      || (el.querySelector ? el.querySelector('.rc-transcript-cue-dot') : null);
    if (dotEl) {
      dotEl.textContent = cue.bookmarked ? '●' : '';
    }

    const noteEl = el.children?.find?.(c => c.classList?.contains('rc-transcript-cue-note'))
      || (el.querySelector ? el.querySelector('.rc-transcript-cue-note') : null);
    if (noteEl) {
      noteEl.textContent = cue.annotation || '';
      if (cue.annotation) {
        noteEl.hidden = false;
        noteEl.removeAttribute('hidden');
      } else {
        noteEl.hidden = true;
        noteEl.setAttribute('hidden', 'true');
      }
    }
  }

  function highlightCue(index) {
    if (index === activeIndex) return;
    if (activeIndex >= 0 && cueElements[activeIndex]) {
      cueElements[activeIndex].classList.remove('rc-transcript-cue-active');
      cueElements[activeIndex].removeAttribute('aria-current');
    }
    activeIndex = index;
    if (activeIndex >= 0 && cueElements[activeIndex]) {
      cueElements[activeIndex].classList.add('rc-transcript-cue-active');
      cueElements[activeIndex].setAttribute('aria-current', 'true');
      if (typeof cueElements[activeIndex].scrollIntoView === 'function') {
        cueElements[activeIndex].scrollIntoView({ block: 'nearest', behavior: 'smooth' });
      }
    }
  }

  function update(state) {
    if (!state) return;
    if (state.title && titleEl) {
      titleEl.textContent = state.title;
    }

    currentCues = Array.isArray(state.cues) ? state.cues : [];

    // Auto un-hide when playing with cues; hide when cues are empty or cleared
    if (state.playing && currentCues.length > 0) {
      pane.hidden = false;
      pane.removeAttribute('hidden');
    } else if (currentCues.length === 0) {
      pane.hidden = true;
      pane.setAttribute('hidden', 'true');
    }

    // Render cues list
    if (typeof cuesContainer.replaceChildren === 'function') {
      cueElements = currentCues.map((c, i) => buildCueElement(c, i));
      cuesContainer.replaceChildren(...cueElements);
    } else {
      cuesContainer.children = [];
      cueElements = currentCues.map((c, i) => {
        const el = buildCueElement(c, i);
        cuesContainer.appendChild(el);
        return el;
      });
    }

    // Reapply active highlight if in range
    const active = activeCueIndexAt(currentCues, state.currentTime || 0);
    highlightCue(active);
  }

  closeControl.addEventListener('click', () => {
    pane.hidden = true;
    pane.setAttribute('hidden', 'true');
    if (typeof onClose === 'function') {
      onClose();
    }
  });

  if (container && typeof container.appendChild === 'function') {
    container.appendChild(pane);
  }

  return {
    element: pane,
    update,
    updateCue,
    highlightCue,
    show() {
      pane.hidden = false;
      pane.removeAttribute('hidden');
    },
    hide() {
      pane.hidden = true;
      pane.setAttribute('hidden', 'true');
    },
    destroy() {
      if (pane.parentElement && typeof pane.parentElement.removeChild === 'function') {
        pane.parentElement.removeChild(pane);
      }
    }
  };
}

/**
 * Creates the full audio sidecar instance managing transcript state,
 * active cue tracking, native bridge messaging, and side panel DOM.
 */
export function createAudioSidecar(options = {}) {
  const globalObj = options.globalObj ?? (typeof window !== 'undefined' ? window : null);
  const onInsertToPage = options.onInsertToPage ?? null;

  const state = {
    playing: false,
    currentTime: 0,
    title: String(options.title || ''),
    sourceKey: String(options.sourceKey || ''),
    cues: normalizeCues(options.cues),
    bookmarks: Array.isArray(options.bookmarks) ? [...options.bookmarks] : []
  };

  let pane = null;

  function setAudioTranscript(data = {}) {
    if (typeof data.playing === 'boolean') {
      state.playing = data.playing;
    }
    if (typeof data.currentTime === 'number') {
      state.currentTime = data.currentTime;
    }
    if (typeof data.title === 'string') {
      state.title = data.title;
    }
    if (typeof data.sourceKey === 'string') {
      state.sourceKey = data.sourceKey;
    }
    if (Array.isArray(data.cues)) {
      state.cues = normalizeCues(data.cues);
    }
    if (Array.isArray(data.bookmarks)) {
      state.bookmarks = [...data.bookmarks];
    }

    if (pane) {
      pane.update(state);
    }
  }

  function updateTime(timeSec) {
    state.currentTime = Number(timeSec) || 0;
    const activeIdx = activeCueIndexAt(state.cues, state.currentTime);
    if (pane) {
      pane.highlightCue(activeIdx);
    }
    return activeIdx;
  }

  function bookmark(cueIndex, note = '') {
    const res = bookmarkCue(state, cueIndex, note, { globalObj });
    if (pane) {
      pane.updateCue(cueIndex);
    }
    return res;
  }

  function toggleBookmark(cueIndex, note = '') {
    const res = toggleBookmarkCue(state, cueIndex, note, { globalObj });
    if (pane) {
      pane.updateCue(cueIndex);
    }
    return res;
  }

  function annotate(cueIndex, annotationText, opts = {}) {
    const insertFn = opts.onInsertToPage !== undefined ? opts.onInsertToPage : onInsertToPage;
    const res = annotateCue(state, cueIndex, annotationText, {
      onInsertToPage: insertFn,
      globalObj
    });
    if (pane) {
      pane.updateCue(cueIndex);
    }
    return res;
  }

  function seek(time) {
    if (globalObj?.webkit?.messageHandlers?.audio?.postMessage) {
      globalObj.webkit.messageHandlers.audio.postMessage({ action: 'seek', time });
    }
    updateTime(time);
  }

  const sidecarApi = {
    getState: () => state,
    setAudioTranscript,
    updateTime,
    bookmarkCue: bookmark,
    toggleBookmarkCue: toggleBookmark,
    annotateCue: annotate,
    seek,
    activeCueIndexAt: (t) => activeCueIndexAt(state.cues, t !== undefined ? t : state.currentTime),
    getActiveCueIndex: () => activeCueIndexAt(state.cues, state.currentTime),
    get pane() {
      return pane;
    },
    createTranscriptPane(container) {
      pane = createTranscriptPane(container, {
        sidecar: sidecarApi,
        globalObj,
        onInsertToPage
      });
      pane.update(state);
      return pane;
    }
  };

  if (options.container) {
    sidecarApi.createTranscriptPane(options.container);
  }

  return sidecarApi;
}

/* ==========================================================================
 * On-Device Per-Section Audio Summaries (Pure Offline, Multilingual)
 * ========================================================================== */

/**
 * Splits a Draftpad window or entire document into logical sections by
 * Markdown headings (`#`..`######`), legal sections (`§ ...`), or topic paragraphs.
 */
export function extractDocumentSections(docText, pageIndex = null) {
  const source = typeof docText === 'string' ? docText : '';
  if (!source.trim()) return [];

  // If pageIndex is provided, extract only from that page of the Draftpad document
  if (pageIndex !== null) {
    const pages = inspectDraftpadPages(source);
    const targetPage = pages.find(p => p.index === pageIndex);
    if (!targetPage) return [];
    return extractSectionsFromText(targetPage.rawContent, targetPage.index);
  }

  // If source contains page dividers and pageIndex was null, extract sections from all pages
  if (source.includes(PAGE_MARKER)) {
    const pages = inspectDraftpadPages(source);
    const allSections = [];
    for (const page of pages) {
      const pageSections = extractSectionsFromText(page.rawContent, page.index);
      allSections.push(...pageSections);
    }
    return allSections;
  }

  return extractSectionsFromText(source, 0);
}

function extractSectionsFromText(rawText, pageIndex) {
  const lines = rawText.split('\n');
  const headings = [];

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trimEnd();
    const parsed = parseHeadingLine(line);
    if (parsed) {
      headings.push({
        lineIndex: i,
        ...parsed
      });
    }
  }

  // If document/window has explicit headings
  if (headings.length > 0) {
    const sections = [];

    // Optional preamble before first heading (excluding standalone date lines)
    if (headings[0].lineIndex > 0) {
      const preambleLines = lines.slice(0, headings[0].lineIndex)
        .filter(l => !isFullDateLine(l.trim()));
      const preambleText = preambleLines.join('\n').trim();
      if (preambleText.length > 0) {
        sections.push({
          id: `sec-${pageIndex}-preamble`,
          title: 'Introduction',
          level: 1,
          kind: 'preamble',
          text: preambleText,
          pageIndex
        });
      }
    }

    for (let k = 0; k < headings.length; k++) {
      const h = headings[k];
      const nextLineIdx = k + 1 < headings.length ? headings[k + 1].lineIndex : lines.length;
      const bodyLines = lines.slice(h.lineIndex + 1, nextLineIdx);
      const sectionText = bodyLines.join('\n').trim();

      sections.push({
        id: `sec-${pageIndex}-${k}`,
        title: h.title,
        level: h.level,
        kind: h.kind,
        marker: h.marker,
        text: sectionText,
        pageIndex
      });
    }
    return sections;
  }

  // No explicit headings: split by topic paragraphs (excluding standalone date lines)
  const paragraphs = rawText
    .split(/\n\s*\n+/)
    .map(p => p.trim())
    .filter(p => p.length > 0 && !isFullDateLine(p));

  const sections = [];
  for (let pIdx = 0; pIdx < paragraphs.length; pIdx++) {
    const p = paragraphs[pIdx];
    // Derive concise title from first sentence or first 50 chars
    const firstSentenceMatch = p.match(/^([^.!?…\n]+[.!?…])/);
    const firstSentence = firstSentenceMatch ? firstSentenceMatch[1].trim() : p.slice(0, 50).trim();
    const title = firstSentence.length > 60 ? `${firstSentence.slice(0, 57)}…` : firstSentence;

    sections.push({
      id: `sec-${pageIndex}-p${pIdx}`,
      title,
      level: 1,
      kind: 'paragraph',
      text: p,
      pageIndex
    });
  }

  return sections;
}

// Multilingual legal rule and reasoning markers (EN, FR, VI)
const LEGAL_RULE_MARKERS = [
  // English holding, obligation, conclusion
  /\bheld\b/i, /\bhold\b/i, /\bholds\b/i, /\bholding\b/i,
  /\brule\b/i, /\brules\b/i, /\bmust\b/i, /\bshall\b/i,
  /\brequired\b/i, /\bprohibited\b/i, /\bbecause\b/i, /\btherefore\b/i,
  /\bthus\b/i, /\bconcludes\b/i, /\bconcluded\b/i, /\bconclusion\b/i,
  /\bfinding\b/i, /\bfinds\b/i, /\bfound\b/i, /\bliable\b/i, /\bliability\b/i,
  /\baffirmed\b/i, /\breversed\b/i, /\bstatute\b/i, /§/, /\bsection\b/i,
  // French obligation and judicial rulings
  /\btenu\b/i, /\bjugé\b/i, /\brègle\b/i, /\bdoit\b/i, /\bdoivent\b/i,
  /\bobligatoire\b/i, /\bparce que\b/i, /\bdonc\b/i, /\ben conséquence\b/i,
  /\bil résulte\b/i, /\bconclut\b/i, /\bconsidérant\b/i, /\bstipule\b/i,
  /\bresponsabilité\b/i, /\bpréjudice\b/i,
  // Vietnamese statutory obligations and judicial conclusions
  /\bquy định\b/i, /\bphải\b/i, /\bbắt buộc\b/i, /\bkhông được\b/i,
  /\bkết luận\b/i, /\bdo đó\b/i, /\bvì vậy\b/i, /\bcho nên\b/i,
  /\bnguyên tắc\b/i, /\btrách nhiệm\b/i, /\btòa án\b/i, /\bbồi thường\b/i,
  /\bvi phạm\b/i, /\btheo đó\b/i, /\báp dụng\b/i, /\bkhoản\b/i, /\bđiều\b/i
];

const STOP_WORDS = new Set([
  // EN
  'the', 'a', 'an', 'and', 'or', 'but', 'in', 'on', 'at', 'to', 'for', 'of', 'with', 'by',
  'from', 'as', 'is', 'was', 'are', 'were', 'been', 'be', 'have', 'has', 'had', 'do',
  'does', 'did', 'will', 'would', 'should', 'can', 'could', 'may', 'might', 'that',
  'this', 'these', 'those', 'it', 'its', 'they', 'their', 'we', 'our', 'you', 'your',
  // FR
  'le', 'la', 'les', 'un', 'une', 'des', 'et', 'ou', 'mais', 'dans', 'en', 'sur', 'à',
  'pour', 'avec', 'par', 'de', 'du', 'ce', 'cette', 'ces', 'est', 'sont', 'été', 'être',
  'qui', 'que', 'il', 'ils', 'elle', 'elles',
  // VI
  'và', 'hoặc', 'nhưng', 'trong', 'trên', 'tại', 'cho', 'của', 'với', 'bởi', 'từ', 'là',
  'đã', 'đang', 'sẽ', 'có', 'được', 'bị', 'này', 'đó', 'những', 'các', 'một', 'khi', 'để'
]);

function tokenizeWords(text) {
  if (!text) return [];
  const words = text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s§]/gu, ' ')
    .split(/\s+/)
    .filter(w => w.length > 1 && !STOP_WORDS.has(w));
  return words;
}

function cleanSpokenSentence(raw) {
  let s = raw
    // Markdown links: [anchor](url) -> anchor
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    // Images: ![alt](url) -> ''
    .replace(/!\[([^\]]*)\]\([^)]+\)/g, '')
    // Bold & italic
    .replace(/[*_]{1,3}([^*_]+)[*_]{1,3}/g, '$1')
    // Inline code
    .replace(/`([^`]+)`/g, '$1')
    // List prefixes
    .replace(/^(\s*[-*•]\s+|\s*\d+\.\s+|\s*\([a-zA-Z0-9]+\)\s+)/, '')
    // Heading hashes
    .replace(/^#+\s+/, '')
    // Page/HTML comments
    .replace(/<!--[\s\S]*?-->/g, '')
    // Extra spaces
    .replace(/\s+/g, ' ')
    .trim();

  if (s.length > 0 && !/[.!?…]$/.test(s)) {
    s += '.';
  }
  return s;
}

/**
 * Pure on-device extractive & structural summarizer (zero network calls,
 * works 100% offline in airplane mode, supports multilingual English/French/Vietnamese text).
 * Supports input as string or object with { title, text } or { title, content } or { title, body }.
 * Scores sentences by heading relevance, legal rule markers, term frequency,
 * and position (opening thesis + key conclusion).
 */
export function summarizeSectionOffline(sectionInput, { maxSentences = 2 } = {}) {
  let title = '';
  let text = '';

  if (typeof sectionInput === 'string') {
    text = sectionInput.trim();
    // Check if first line is a heading
    const firstLineEnd = text.indexOf('\n');
    const firstLine = firstLineEnd !== -1 ? text.slice(0, firstLineEnd).trim() : text;
    const parsedHeading = parseHeadingLine(firstLine);
    if (parsedHeading) {
      title = parsedHeading.title;
      text = firstLineEnd !== -1 ? text.slice(firstLineEnd).trim() : '';
    }
  } else if (sectionInput && typeof sectionInput === 'object') {
    title = String(sectionInput.title || '').trim();
    text = String(sectionInput.text ?? sectionInput.content ?? sectionInput.body ?? '').trim();
  }

  if (!text && !title) {
    return { summary: '', bullets: [] };
  }

  // Split into candidate sentences
  const rawParagraphs = text.split(/\n\s*\n+/);
  const candidateSentences = [];

  for (const para of rawParagraphs) {
    const trimmedPara = para.trim();
    if (!trimmedPara) continue;
    // Sentence segmentation respecting multilingual punctuation
    const tokens = trimmedPara
      .replace(/([.!?…])\s+(?=[A-ZÀ-ỸÁ-Ỵ\d"“'§])/g, '$1\n')
      .split('\n');
    for (const t of tokens) {
      const s = t.trim();
      if (s.length > 0) {
        candidateSentences.push(s);
      }
    }
  }

  if (candidateSentences.length === 0) {
    const single = cleanSpokenSentence(title);
    return {
      summary: single,
      bullets: single ? [single.replace(/[.!?…]$/, '')] : []
    };
  }

  // Calculate term frequency across the section
  const allWords = tokenizeWords(`${title} ${text}`);
  const wordFreq = new Map();
  for (const w of allWords) {
    wordFreq.set(w, (wordFreq.get(w) || 0) + 1);
  }

  const titleWords = new Set(tokenizeWords(title));
  const totalSentences = candidateSentences.length;

  const scored = candidateSentences.map((rawSentence, index) => {
    const cleaned = cleanSpokenSentence(rawSentence);
    const sentWords = tokenizeWords(cleaned);

    // 1. Term frequency score
    let tfScore = 0;
    for (const w of sentWords) {
      tfScore += (wordFreq.get(w) || 0) / (allWords.length || 1);
    }
    const normalizedTf = sentWords.length > 0 ? tfScore / Math.sqrt(sentWords.length) : 0;

    // 2. Heading relevance score
    let headingMatches = 0;
    for (const w of sentWords) {
      if (titleWords.has(w)) headingMatches++;
    }
    const headingScore = headingMatches * 1.2;

    // 3. Legal rule & reasoning markers
    let markerMatches = 0;
    for (const marker of LEGAL_RULE_MARKERS) {
      if (marker.test(cleaned)) markerMatches++;
    }
    const markerScore = markerMatches * 1.8;

    // 4. Structural position score: opening thesis and key conclusion
    let positionScore = 0.5;
    if (index === 0) {
      positionScore = 1.4; // Opening thesis
    } else if (index === totalSentences - 1 && totalSentences > 1) {
      positionScore = 1.2; // Final conclusion
    } else {
      positionScore = 1.0 / (1 + 0.15 * index);
    }

    const totalScore = normalizedTf + headingScore + markerScore + positionScore;

    return {
      index,
      raw: rawSentence,
      cleaned,
      score: totalScore
    };
  });

  // Pick top N highest-scoring sentences
  const limit = Math.max(1, Number(maxSentences) || 2);
  const topScored = [...scored].sort((a, b) => b.score - a.score).slice(0, limit);

  // Restore chronological document order for natural spoken flow
  topScored.sort((a, b) => a.index - b.index);

  const summary = topScored.map(s => s.cleaned).join(' ');
  const bullets = topScored.map(s => s.cleaned.replace(/[.!?…]$/, ''));

  return {
    summary,
    bullets
  };
}

/**
 * Extracts and summarizes all sections in a Draftpad document or page window.
 */
export function summarizeAllSections(docText, options = {}) {
  const sections = extractDocumentSections(docText, options.pageIndex ?? null);
  return sections.map(sec => {
    const res = summarizeSectionOffline(sec, options);
    return {
      ...sec,
      summary: res.summary,
      bullets: res.bullets
    };
  });
}

/**
 * Generates section summary and posts { action: 'speakSummary', ... } to native
 * Mac/iOS audio bridge, with SpeechSynthesisUtterance fallback in WebKit.
 * Reads text from section.text ?? section.content ?? section.body.
 */
export function speakSectionSummary(
  section,
  { globalObj = typeof window !== 'undefined' ? window : null, lang = 'en-US' } = {}
) {
  if (!section) return null;

  let summaryText = section.summary;
  let titleText = section.title || '';
  let sectionId = section.id || 'sec-0';

  if (!summaryText) {
    const rawBody = section.text ?? section.content ?? section.body;
    const res = summarizeSectionOffline(
      rawBody !== undefined ? { ...section, text: rawBody } : section
    );
    summaryText = res.summary;
  }

  if (!summaryText) return null;

  let spokenVia = 'none';

  // 1. Post to native Recense audio bridge (Mac NSSpeechSynthesizer / iOS AVSpeechSynthesizer)
  if (globalObj?.webkit?.messageHandlers?.audio?.postMessage) {
    globalObj.webkit.messageHandlers.audio.postMessage({
      action: 'speakSummary',
      sectionId,
      title: titleText,
      text: summaryText
    });
    spokenVia = 'native';
  } else if (globalObj?.speechSynthesis && typeof globalObj.SpeechSynthesisUtterance === 'function') {
    // 2. Standalone WebKit offline SpeechSynthesis fallback
    try {
      const utterance = new globalObj.SpeechSynthesisUtterance(summaryText);
      utterance.lang = lang;

      const voices = globalObj.speechSynthesis.getVoices?.() || [];
      const localVoice = voices.find(v => v.localService === true && (!lang || v.lang?.startsWith(lang.slice(0, 2))))
        || voices.find(v => v.localService === true)
        || voices[0];

      if (localVoice) {
        utterance.voice = localVoice;
      }
      globalObj.speechSynthesis.speak(utterance);
      spokenVia = 'speechSynthesis';
    } catch {
      spokenVia = 'none';
    }
  }

  return {
    sectionId,
    title: titleText,
    text: summaryText,
    spokenVia
  };
}
