/**
 * wings.js · Ambidextrous Dual Notification-Center Sidebars, Feathery Offline Widgets,
 * and 24/7 Multilingual Time & Date Calendar Extractor for Draftpad.
 *
 * Supports English, French, and Vietnamese date/time parsing, continuous calendar
 * scanning with deterministic deduplication, zero-chrome collapsible sidebars,
 * and ambidextrous bilateral gestures.
 */

export const PAGE_MARKER = '<!-- page -->';

export const DEFAULT_WIDGETS = [
  'preview',
  'quicktime',
  'findmy',
  'mail',
  'calendar'
];

const EN_MONTHS = {
  january: 0, jan: 0,
  february: 1, feb: 1,
  march: 2, mar: 2,
  april: 3, apr: 3,
  may: 4,
  june: 5, jun: 5,
  july: 6, jul: 6,
  august: 7, aug: 7,
  september: 8, sep: 8, sept: 8,
  october: 9, oct: 9,
  november: 10, nov: 10,
  december: 11, dec: 11
};

const FR_MONTHS = {
  janvier: 0,
  'février': 1, fevrier: 1,
  mars: 2,
  avril: 3,
  mai: 4,
  juin: 5,
  juillet: 6,
  'août': 7, aout: 7,
  septembre: 8,
  octobre: 9,
  novembre: 10,
  'décembre': 11, decembre: 11
};

/**
 * Deterministic hash (`cal-<8hex>`) of `title + startISO` so re-scanning never creates duplicates.
 */
export function hashEventId(title, startISO) {
  const str = `${title ?? ''}${startISO ?? ''}`;
  let h = 0x811c9dc5;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return 'cal-' + (h >>> 0).toString(16).padStart(8, '0');
}

/**
 * Formats seconds into MM:SS or H:MM:SS string.
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

function normalizeHours(h, ampm) {
  let hour = Number(h);
  if (ampm) {
    const p = ampm.toLowerCase();
    if (p === 'pm' && hour < 12) hour += 12;
    if (p === 'am' && hour === 12) hour = 0;
  }
  return hour;
}

function parseTimeStr(str) {
  if (!str) return null;
  const m = str.trim().match(/^(\d{1,2})(?:[:h](\d{2}))?\s*(am|pm|AM|PM)?$/i);
  if (!m) return null;
  return {
    hour: normalizeHours(m[1], m[3]),
    minute: m[2] ? Number(m[2]) : 0
  };
}

function cleanTitle(str) {
  let s = String(str ?? '').trim();
  // Strip Markdown list markers and task checkmarks: - [ ] , * , 1.
  s = s.replace(/^[-*+]\s+(\[[ xX]\]\s+)?/, '');
  s = s.replace(/^\d+[.)]\s+/, '');
  // Strip leading and trailing punctuation & separators: ":", "-", "–", "—", ","
  s = s.replace(/^[:\-–—,\s]+/, '').replace(/[:\-–—,\s]+$/, '');
  return s.trim();
}

/**
 * Pure offline deterministic parser supporting English, French, and Vietnamese date/time expressions.
 *
 * @param {string} docText - Full Draftpad document text
 * @param {object} [options]
 * @param {Date|string} [options.referenceDate] - Baseline date for relative terms ("today", "tomorrow", "demain", "ngày mai")
 * @returns {Array<{ id: string, title: string, startISO: string, endISO: string, lineNumber: number, pageIndex: number, rawLine: string }>}
 */
export function extractCalendarEvents(docText, { referenceDate = new Date() } = {}) {
  if (typeof docText !== 'string' || docText.trim().length === 0) {
    return [];
  }

  const ref = referenceDate instanceof Date ? referenceDate : new Date(referenceDate);
  // Dates are read in the Mac's or iPhone's own time zone: "1pm" means 1 PM here (E2 review #2).
  const base = !Number.isNaN(ref.getTime()) ? ref : new Date();
  const refYear = base.getFullYear();
  const refMonth = base.getMonth();
  const refDay = base.getDate();

  const lines = docText.split(/\r?\n/);
  const events = [];
  const seenIds = new Set();
  let pageIndex = 0;

  // Regex rules
  const reRelEn = /\b(today|tomorrow)\b(?:\s+(?:at\s+)?(\d{1,2}(?:[:h]\d{2})?\s*(?:am|pm|AM|PM)?))?(?:\s*(?:-|–|—|to)\s*(\d{1,2}(?:[:h]\d{2})?\s*(?:am|pm|AM|PM)?))?/i;
  const reRelFr = /\b(demain|aujourd\x27hui)\b(?:\s*(?:à\s*|\s+)(\d{1,2}(?:[h:]\d{2})?))?(?:\s*(?:-|–|—|à)\s*(\d{1,2}(?:[h:]\d{2})?))?/i;
  const reRelVi = /\b(ngày\s+mai|hôm\s+nay)\b(?:\s*(?:lúc\s*|\s+)(\d{1,2}(?:[h:]\d{2})?))?(?:\s*(?:-|–|—|đến)\s*(\d{1,2}(?:[h:]\d{2})?))?/i;
  const reIso = /\b(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})\b(?:\s*(?:at|à|lúc|T|\s)\s*(\d{1,2}(?:[:h]\d{2})?(?::\d{2})?\s*(?:am|pm|AM|PM)?))?(?:\s*(?:-|–|—|to|à|đến)\s*(\d{1,2}(?:[:h]\d{2})?(?::\d{2})?\s*(?:am|pm|AM|PM)?))?/i;
  const reViA = /\b(?:ngày\s+)?(\d{1,2})[\/-](\d{1,2})[\/-](\d{4})\b(?:\s*(?:lúc\s*|\s+)(\d{1,2}(?:[h:]\d{2})?))?(?:\s*(?:-|–|—|đến)\s*(\d{1,2}(?:[h:]\d{2})?))?/i;
  const reViB = /\b(?:ngày\s+)?(\d{1,2})\s+tháng\s+(\d{1,2})(?:\s+năm\s+(\d{4}))?\b(?:\s*(?:lúc\s*|\s+)(\d{1,2}(?:[h:]\d{2})?))?(?:\s*(?:-|–|—|đến)\s*(\d{1,2}(?:[h:]\d{2})?))?/i;
  const reFr = /\b(?:le\s+)?(?:(?:lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche),?\s+)?(\d{1,2})\s+(janvier|février|fevrier|mars|avril|mai|juin|juillet|août|aout|septembre|octobre|novembre|décembre|decembre)(?:\s+(\d{4}))?\b(?:\s*(?:à\s*|\s+)(\d{1,2}(?:[h:]\d{2})?))?(?:\s*(?:-|–|—|à)\s*(\d{1,2}(?:[h:]\d{2})?))?/i;
  const reEn = /\b(?:(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|Mon|Tue|Tues|Wed|Thu|Thur|Thurs|Fri|Sat|Sun),?\s+)?(January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?\b(?:\s*(?:at\s*|\s+)(\d{1,2}(?:[:h]\d{2})?\s*(?:am|pm|AM|PM)?))?(?:\s*(?:-|–|—|to)\s*(\d{1,2}(?:[:h]\d{2})?\s*(?:am|pm|AM|PM)?))?/i;
  const reEnDayFirst = /\b(\d{1,2})(?:st|nd|rd|th)?\s+(January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\.?\s+(\d{4})\b(?:\s*(?:at\s*|\s+)(\d{1,2}(?:[:h]\d{2})?\s*(?:am|pm|AM|PM)?))?(?:\s*(?:-|–|—|to)\s*(\d{1,2}(?:[:h]\d{2})?\s*(?:am|pm|AM|PM)?))?/i;

  for (let lineIdx = 0; lineIdx < lines.length; lineIdx++) {
    const rawLine = lines[lineIdx];
    const lineNumber = lineIdx + 1;

    if (rawLine.includes(PAGE_MARKER)) {
      pageIndex++;
      continue;
    }

    const trimmed = rawLine.trim();
    if (trimmed.length === 0) continue;

    let parsed = null;
    let m;

    if ((m = reRelEn.exec(rawLine))) {
      const isTomorrow = m[1].toLowerCase() === 'tomorrow';
      const d = new Date(refYear, refMonth, refDay + (isTomorrow ? 1 : 0));
      const t = parseTimeStr(m[2]);
      const tEnd = parseTimeStr(m[3]);
      parsed = { year: d.getFullYear(), month: d.getMonth(), day: d.getDate(), time: t, endTime: tEnd, matchText: m[0], matchIdx: m.index, relative: true };
    } else if ((m = reRelFr.exec(rawLine))) {
      const isDemain = m[1].toLowerCase() === 'demain';
      const d = new Date(refYear, refMonth, refDay + (isDemain ? 1 : 0));
      const t = parseTimeStr(m[2]);
      const tEnd = parseTimeStr(m[3]);
      parsed = { year: d.getFullYear(), month: d.getMonth(), day: d.getDate(), time: t, endTime: tEnd, matchText: m[0], matchIdx: m.index, relative: true };
    } else if ((m = reRelVi.exec(rawLine))) {
      const isMai = m[1].toLowerCase().includes('mai');
      const d = new Date(refYear, refMonth, refDay + (isMai ? 1 : 0));
      const t = parseTimeStr(m[2]);
      const tEnd = parseTimeStr(m[3]);
      parsed = { year: d.getFullYear(), month: d.getMonth(), day: d.getDate(), time: t, endTime: tEnd, matchText: m[0], matchIdx: m.index, relative: true };
    } else if ((m = reIso.exec(rawLine))) {
      const y = Number(m[1]);
      const mon = Number(m[2]) - 1;
      const day = Number(m[3]);
      const t = parseTimeStr(m[4]);
      const tEnd = parseTimeStr(m[5]);
      parsed = { year: y, month: mon, day, time: t, endTime: tEnd, matchText: m[0], matchIdx: m.index };
    } else if ((m = reViA.exec(rawLine))) {
      const day = Number(m[1]);
      const mon = Number(m[2]) - 1;
      const y = Number(m[3]);
      const t = parseTimeStr(m[4]);
      const tEnd = parseTimeStr(m[5]);
      parsed = { year: y, month: mon, day, time: t, endTime: tEnd, matchText: m[0], matchIdx: m.index };
    } else if ((m = reViB.exec(rawLine))) {
      const day = Number(m[1]);
      const mon = Number(m[2]) - 1;
      const y = m[3] ? Number(m[3]) : refYear;
      const t = parseTimeStr(m[4]);
      const tEnd = parseTimeStr(m[5]);
      parsed = { year: y, month: mon, day, time: t, endTime: tEnd, matchText: m[0], matchIdx: m.index };
    } else if ((m = reFr.exec(rawLine))) {
      const day = Number(m[1]);
      const mon = FR_MONTHS[m[2].toLowerCase()];
      const y = m[3] ? Number(m[3]) : refYear;
      const t = parseTimeStr(m[4]);
      const tEnd = parseTimeStr(m[5]);
      parsed = { year: y, month: mon, day, time: t, endTime: tEnd, matchText: m[0], matchIdx: m.index };
    } else if ((m = reEn.exec(rawLine))) {
      const mon = EN_MONTHS[m[1].toLowerCase()];
      const day = Number(m[2]);
      const y = m[3] ? Number(m[3]) : refYear;
      const t = parseTimeStr(m[4]);
      const tEnd = parseTimeStr(m[5]);
      parsed = { year: y, month: mon, day, time: t, endTime: tEnd, matchText: m[0], matchIdx: m.index };
    } else if ((m = reEnDayFirst.exec(rawLine))) {
      const day = Number(m[1]);
      const mon = EN_MONTHS[m[2].toLowerCase()];
      const y = Number(m[3]);
      const t = parseTimeStr(m[4]);
      const tEnd = parseTimeStr(m[5]);
      parsed = { year: y, month: mon, day, time: t, endTime: tEnd, matchText: m[0], matchIdx: m.index };
    }

    if (!parsed) continue;

    const before = rawLine.slice(0, parsed.matchIdx);
    const after = rawLine.slice(parsed.matchIdx + parsed.matchText.length);
    const remainder = cleanTitle(before + ' ' + after);

    const hasTime = parsed.time !== null;
    const hasDesc = remainder.length > 0;

    // Ignore standalone Draftpad page header date lines that have no time and no event description!
    if (!hasTime && !hasDesc) {
      continue;
    }
    // "today" / "tomorrow" / "demain" / "ngày mai" turn up in ordinary sentences: only with a time is it an event.
    if (parsed.relative && !hasTime) {
      continue;
    }
    // A field such as "Date: October 9, 2026" (a label, a colon, the date) is a header, not an appointment.
    if (!hasTime && /:\s*$/.test(before) && after.trim() === '' && remainder.split(/\s+/).length <= 2) {
      continue;
    }

    const title = hasDesc ? remainder : cleanTitle(parsed.matchText);
    // No time written means an all-day event, never an invented 9 AM.
    const allDay = !hasTime;
    let startDate;
    let endDate;
    if (allDay) {
      startDate = new Date(parsed.year, parsed.month, parsed.day);
      endDate = new Date(parsed.year, parsed.month, parsed.day + 1);
    } else {
      startDate = new Date(parsed.year, parsed.month, parsed.day, parsed.time.hour, parsed.time.minute, 0);
      if (parsed.endTime) {
        endDate = new Date(parsed.year, parsed.month, parsed.day, parsed.endTime.hour, parsed.endTime.minute, 0);
        if (endDate <= startDate) endDate = new Date(endDate.getTime() + 24 * 60 * 60 * 1000); // "10pm - 1am"
      } else {
        endDate = new Date(startDate.getTime() + 60 * 60 * 1000);
      }
    }
    const startISO = startDate.toISOString();
    const endISO = endDate.toISOString();

    const id = hashEventId(title, startISO);
    if (seenIds.has(id)) continue;
    seenIds.add(id);

    events.push({
      id,
      title,
      startISO,
      endISO,
      allDay,
      lineNumber,
      pageIndex,
      rawLine
    });
  }

  return events;
}

/**
 * Calendar scanner: finds dated lines and proposes them. It never writes to the calendar by itself.
 * An event is saved only through `requestAdd` (the owner's click, tap or voice), and counts as added only once the
 * host reports the save (`markSynced`). Each scan marks events already added with `added: true`.
 */
export function createCalendarScanner(options = {}) {
  const syncedIds = new Set(options.syncedIds || []);
  let latestEvents = [];
  const globalObj = options.globalObj || (typeof window !== 'undefined' ? window : null);

  function scanText(docText, scanOpts = {}) {
    const refDate = scanOpts.referenceDate || options.referenceDate || new Date();
    latestEvents = extractCalendarEvents(docText, { referenceDate: refDate })
      .map(ev => ({ ...ev, added: syncedIds.has(ev.id) }));
    if (typeof options.onScan === 'function') {
      options.onScan(latestEvents);
    }
    return latestEvents;
  }

  /** The owner confirmed this event: ask the host to save it. Returns false if it was already added. */
  function requestAdd(ev) {
    if (!ev || syncedIds.has(ev.id)) return false;
    if (globalObj?.webkit?.messageHandlers?.calendar?.postMessage) {
      globalObj.webkit.messageHandlers.calendar.postMessage({ action: 'addEvents', events: [ev] });
    }
    return true;
  }

  function getEvents() {
    return latestEvents.slice();
  }

  function getSyncedIds() {
    return new Set(syncedIds);
  }

  function markSynced(ids) {
    if (Array.isArray(ids) || ids instanceof Set) {
      for (const id of ids) {
        syncedIds.add(id);
      }
    } else if (typeof ids === 'string') {
      syncedIds.add(ids);
    }
    latestEvents = latestEvents.map(ev => ({ ...ev, added: syncedIds.has(ev.id) }));
  }

  return {
    scanText,
    requestAdd,
    getEvents,
    getSyncedIds,
    markSynced
  };
}

/**
 * Lightweight mock element when headless / test environments lack a complete DOM.
 */
function createMockElement(tag) {
  const listeners = {};
  const attributes = {};
  const classListSet = new Set();
  const children = [];

  const el = {
    tagName: tag.toUpperCase(),
    nodeName: tag.toUpperCase(),
    hidden: false,
    value: '',
    textContent: '',
    children,
    childNodes: children,
    firstChild: null,
    parentElement: null,
    parentNode: null,
    dataset: {},
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
      if (k.startsWith('data-')) {
        const dKey = k.slice(5).replace(/-([a-z])/g, (_, g) => g.toUpperCase());
        el.dataset[dKey] = String(v);
      }
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
      if (k.startsWith('data-')) {
        const dKey = k.slice(5).replace(/-([a-z])/g, (_, g) => g.toUpperCase());
        delete el.dataset[dKey];
      }
    },
    hasAttribute(k) {
      return k in attributes;
    },
    appendChild(child) {
      if (child) {
        children.push(child);
        child.parentElement = el;
        child.parentNode = el;
        el.firstChild = children[0] || null;
      }
      return child;
    },
    removeChild(child) {
      const idx = children.indexOf(child);
      if (idx !== -1) {
        children.splice(idx, 1);
        child.parentElement = null;
        child.parentNode = null;
        el.firstChild = children[0] || null;
      }
      return child;
    },
    replaceChildren(...newChildren) {
      while (children.length > 0) {
        el.removeChild(children[0]);
      }
      for (const c of newChildren) {
        el.appendChild(c);
      }
    },
    addEventListener(type, fn) {
      listeners[type] = listeners[type] || [];
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
    querySelector(sel) {
      return el.querySelectorAll(sel)[0] || null;
    },
    querySelectorAll(sel) {
      const matches = [];
      function walk(node) {
        for (const child of node.children || []) {
          if (matchesSel(child, sel)) {
            matches.push(child);
          }
          walk(child);
        }
      }
      walk(el);
      return matches;
    }
  };

  function matchesSel(target, sel) {
    if (!target || !sel) return false;
    if (sel.startsWith('.')) {
      return target.classList?.contains(sel.slice(1));
    }
    if (sel.startsWith('[') && sel.endsWith(']')) {
      const inner = sel.slice(1, -1);
      const [k, v] = inner.split('=');
      if (!v) return target.hasAttribute?.(k);
      const cleanV = v.replace(/^["']|["']$/g, '');
      return target.getAttribute?.(k) === cleanV;
    }
    return target.tagName === sel.toUpperCase();
  }

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
  let el;
  if (doc && typeof doc.createElement === 'function') {
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

/**
 * Creates ambidextrous dual sidebars (wings) with 4 feathery offline widgets and live agenda.
 *
 * @param {HTMLElement} container
 * @param {object} [options]
 */
export function createDualWings(container, options = {}) {
  const doc = container?.ownerDocument || (typeof document !== 'undefined' ? document : null);
  const globalObj = options.globalObj || (typeof window !== 'undefined' ? window : null);

  let leftWidgets = Array.isArray(options.leftWidgets)
    ? [...options.leftWidgets]
    : ['recense', 'preview', 'quicktime'];
  let rightWidgets = Array.isArray(options.rightWidgets)
    ? [...options.rightWidgets]
    : ['recense', 'calendar'];
  // Widgets only some hosts can run (the Mac's iPhone Mirroring): shown once the host enables them.
  const HOST_WIDGETS = new Set(['iphone']);
  const enabledHostWidgets = new Set();

  // Left Wing aside
  const leftEl = makeDomElement(doc, 'aside', {}, {
    class: 'rc-wing rc-wing-left',
    'data-side': 'left'
  });
  leftEl.hidden = true;

  // Right Wing aside
  const rightEl = makeDomElement(doc, 'aside', {}, {
    class: 'rc-wing rc-wing-right',
    'data-side': 'right'
  });
  rightEl.hidden = true;

  if (container?.appendChild) {
    container.appendChild(leftEl);
    container.appendChild(rightEl);
  }

  function postHaptic(kind) {
    if (globalObj?.webkit?.messageHandlers?.ui?.postMessage) {
      globalObj.webkit.messageHandlers.ui.postMessage({ haptic: kind });
    }
  }

  /**
   * An empty card's one control: choose a file from this device (or drop one on the card). It plays or shows here,
   * offline, from the file itself; nothing is uploaded.
   */
  function filePicker(accept, label, onFile) {
    const wrap = makeDomElement(doc, 'div', {}, { class: 'rc-card-pick' });
    const btn = makeDomElement(doc, 'div', { textContent: label }, {
      class: 'rc-widget-action rc-card-pick-btn', role: 'button', tabindex: '0'
    });
    const input = makeDomElement(doc, 'input', {}, { type: 'file', accept, class: 'rc-card-pick-input', hidden: 'true' });
    const take = file => {
      if (!file) return;
      const url = globalObj?.URL?.createObjectURL ? globalObj.URL.createObjectURL(file) : '';
      if (url) onFile(url, String(file.name || '').replace(/\.[^.]+$/, ''), file);
    };
    input.addEventListener('change', () => take(input.files && input.files[0]));
    const open = e => {
      if (e?.type === 'keydown' && e.key !== 'Enter' && e.key !== ' ') return;
      if (typeof input.click === 'function') input.click();
    };
    btn.addEventListener('click', open);
    btn.addEventListener('keydown', open);
    wrap.appendChild(btn);
    wrap.appendChild(input);
    return { wrap, take };
  }

  /** Drop a file on a card to load it. */
  function acceptDrops(card, onFile) {
    card.addEventListener('dragover', e => {
      if (typeof e.preventDefault === 'function') e.preventDefault();
    });
    card.addEventListener('drop', e => {
      if (typeof e.preventDefault === 'function') e.preventDefault();
      const file = e.dataTransfer?.files?.[0];
      if (!file) return;
      const url = globalObj?.URL?.createObjectURL ? globalObj.URL.createObjectURL(file) : '';
      if (url) onFile(url, String(file.name || '').replace(/\.[^.]+$/, ''), file);
    });
  }

  // Widget Cards & State
  const widgetElements = {};

  // 1. Preview Widget (Offline PDF/Image Exhibit Viewer)
  let previewData = { src: '', caption: '' };
  const previewCard = makeDomElement(doc, 'section', {}, {
    class: 'rc-wing-card rc-widget-preview',
    'data-widget': 'preview',
    role: 'region'
  });
  widgetElements.preview = previewCard;

  function updatePreviewCard() {
    while (previewCard.firstChild) {
      previewCard.removeChild(previewCard.firstChild);
    }
    previewCard.setAttribute('data-src', previewData.src || '');

    const header = makeDomElement(doc, 'div', {}, { class: 'rc-widget-header' });
    const titleSpan = makeDomElement(doc, 'span', { textContent: previewData.caption || 'Exhibit Preview' }, { class: 'rc-widget-title' });
    header.appendChild(titleSpan);
    previewCard.appendChild(header);

    const body = makeDomElement(doc, 'div', {}, { class: 'rc-widget-body rc-preview-body', 'data-src': previewData.src || '' });
    if (previewData.src) {
      if (previewData.kind === 'pdf' || previewData.src.endsWith('.pdf')) {
        // The document itself, readable in the card (the web view's own PDF viewer, offline).
        const frame = makeDomElement(doc, 'iframe', {}, {
          class: 'rc-preview-pdf',
          src: previewData.src,
          title: previewData.caption || 'Exhibit'
        });
        body.appendChild(frame);
      } else {
        const img = makeDomElement(doc, 'img', {}, {
          class: 'rc-preview-img',
          src: previewData.src,
          alt: previewData.caption || 'Exhibit'
        });
        body.appendChild(img);
      }
    } else {
      body.appendChild(filePicker('application/pdf,image/*', 'Choose an exhibit…', loadExhibit).wrap);
    }

    body.addEventListener('click', () => {
      if (!previewData.src) return;
      const snippet = previewData.src.endsWith('.pdf')
        ? `[${previewData.caption || 'Exhibit'}](${previewData.src})\n`
        : `![${previewData.caption || 'Exhibit'}](${previewData.src})\n`;
      if (typeof options.onInsertToPage === 'function') {
        options.onInsertToPage(snippet);
      }
      if (globalObj?.webkit?.messageHandlers?.wings?.postMessage) {
        globalObj.webkit.messageHandlers.wings.postMessage({
          action: 'cite',
          type: 'preview',
          src: previewData.src,
          caption: previewData.caption
        });
      }
    });

    previewCard.appendChild(body);
  }

  function setPreviewTarget(pathOrUrl, caption = '', kind = '') {
    previewData = { src: String(pathOrUrl || ''), caption: String(caption || ''), kind: String(kind || '') };
    updatePreviewCard();
  }
  function loadExhibit(url, name, file) {
    setPreviewTarget(url, name, /pdf/.test(String(file?.type || '')) ? 'pdf' : 'image');
  }
  acceptDrops(previewCard, loadExhibit);
  updatePreviewCard();

  // 2. QuickTime Widget (Offline QuickTime Media Player)
  let qtData = { src: '', title: '', playbackRate: 1.0, loopRange: [0, 0], currentTime: 0 };
  const qtCard = makeDomElement(doc, 'section', {}, {
    class: 'rc-wing-card rc-widget-quicktime',
    'data-widget': 'quicktime',
    role: 'region'
  });
  widgetElements.quicktime = qtCard;

  function updateQuickTimeCard() {
    while (qtCard.firstChild) {
      qtCard.removeChild(qtCard.firstChild);
    }
    qtCard.setAttribute('data-src', qtData.src || '');

    const header = makeDomElement(doc, 'div', {}, { class: 'rc-widget-header' });
    const titleSpan = makeDomElement(doc, 'span', { textContent: qtData.title || 'QuickTime Media' }, { class: 'rc-widget-title' });
    const metaSpan = makeDomElement(doc, 'span', { textContent: `${qtData.playbackRate}x` }, { class: 'rc-widget-meta' });
    header.appendChild(titleSpan);
    header.appendChild(metaSpan);
    qtCard.appendChild(header);

    const body = makeDomElement(doc, 'div', {}, { class: 'rc-widget-body rc-qt-body', 'data-src': qtData.src || '' });
    if (qtData.src) {
      const video = makeDomElement(doc, 'video', { playbackRate: qtData.playbackRate }, {
        class: 'rc-qt-video',
        src: qtData.src,
        playsinline: 'true',
        controls: 'true',
        preload: 'metadata'
      });

      // Loop range handling
      video.addEventListener('timeupdate', () => {
        qtData.currentTime = video.currentTime || 0;
        if (qtData.loopRange[1] > qtData.loopRange[0] && qtData.currentTime >= qtData.loopRange[1]) {
          video.currentTime = qtData.loopRange[0];
          qtData.currentTime = qtData.loopRange[0];
        }
        tsSpan.textContent = `[@${formatTimestamp(qtData.currentTime)}] cite this moment`;
      });

      const controls = makeDomElement(doc, 'div', {}, { class: 'rc-qt-controls' });
      const tsSpan = makeDomElement(doc, 'span', { textContent: `[@${formatTimestamp(qtData.currentTime)}] cite this moment` }, {
        class: 'rc-qt-timestamp', role: 'button', tabindex: '0'
      });
      controls.appendChild(tsSpan);

      body.appendChild(video);
      body.appendChild(controls);
    } else {
      body.appendChild(filePicker('video/*,audio/*', 'Choose a video or recording…', (url, name) => setMediaSource(url, name)).wrap);
    }

    // Citing the moment: the timestamp line under the picture (the picture itself keeps its own play controls).
    body.addEventListener('click', e => {
      if (!qtData.src || !e?.target?.classList?.contains?.('rc-qt-timestamp')) return;
      const ts = formatTimestamp(qtData.currentTime);
      const snippet = `[@${ts}] ${qtData.title || 'Media reference'}\n`;
      if (typeof options.onInsertToPage === 'function') {
        options.onInsertToPage(snippet);
      }
      if (globalObj?.webkit?.messageHandlers?.wings?.postMessage) {
        globalObj.webkit.messageHandlers.wings.postMessage({
          action: 'cite',
          type: 'quicktime',
          src: qtData.src,
          time: qtData.currentTime,
          title: qtData.title
        });
      }
    });

    qtCard.appendChild(body);
  }
  updateQuickTimeCard();

  acceptDrops(qtCard, (url, name) => setMediaSource(url, name));

  function setMediaSource(pathOrUrl, title = '') {
    qtData.src = String(pathOrUrl || '');
    qtData.title = String(title || '');
    updateQuickTimeCard();
  }

  function setPlaybackRate(rate) {
    qtData.playbackRate = Number(rate) || 1.0;
    const vid = qtCard.querySelector?.('video');
    if (vid) vid.playbackRate = qtData.playbackRate;
    updateQuickTimeCard();
  }

  function setLoopRange(startSec, endSec) {
    qtData.loopRange = [Math.max(0, Number(startSec) || 0), Math.max(0, Number(endSec) || 0)];
  }

  // 3. Find My Widget (Offline-first Find My Location Cache)
  let findMyItems = [];
  const findMyCard = makeDomElement(doc, 'section', {}, {
    class: 'rc-wing-card rc-widget-findmy',
    'data-widget': 'findmy',
    role: 'region'
  });
  widgetElements.findmy = findMyCard;

  function updateFindMyCard() {
    while (findMyCard.firstChild) {
      findMyCard.removeChild(findMyCard.firstChild);
    }

    const header = makeDomElement(doc, 'div', {}, { class: 'rc-widget-header' });
    const titleSpan = makeDomElement(doc, 'span', { textContent: 'Find My' }, { class: 'rc-widget-title' });
    header.appendChild(titleSpan);
    findMyCard.appendChild(header);

    const body = makeDomElement(doc, 'div', {}, { class: 'rc-widget-body rc-findmy-list' });
    if (findMyItems.length > 0) {
      for (const item of findMyItems) {
        const itemRow = makeDomElement(doc, 'div', {}, {
          class: 'rc-findmy-item',
          'data-id': item.id,
          role: 'button',
          tabindex: '0'
        });

        const nameEl = makeDomElement(doc, 'div', { textContent: item.name }, { class: 'rc-item-name' });
        const locEl = makeDomElement(doc, 'div', { textContent: item.location }, { class: 'rc-item-location' });
        const metaEl = makeDomElement(doc, 'div', {}, { class: 'rc-item-meta' });
        const batSpan = makeDomElement(doc, 'span', { textContent: item.battery ?? '' }, { class: 'rc-item-battery' });
        const statusSpan = makeDomElement(doc, 'span', { textContent: item.status ?? '' }, { class: 'rc-item-status' });
        const timeSpan = makeDomElement(doc, 'span', { textContent: item.updatedAt ?? '' }, { class: 'rc-item-time' });

        metaEl.appendChild(batSpan);
        metaEl.appendChild(statusSpan);
        metaEl.appendChild(timeSpan);

        itemRow.appendChild(nameEl);
        itemRow.appendChild(locEl);
        itemRow.appendChild(metaEl);

        itemRow.addEventListener('click', () => {
          const snippet = `${item.name}: ${item.location} (as of ${item.updatedAt})\n`;
          if (typeof options.onInsertToPage === 'function') {
            options.onInsertToPage(snippet);
          }
          if (globalObj?.webkit?.messageHandlers?.wings?.postMessage) {
            globalObj.webkit.messageHandlers.wings.postMessage({
              action: 'cite',
              type: 'findmy',
              item
            });
          }
        });

        body.appendChild(itemRow);
      }
    } else {
      const empty = makeDomElement(doc, 'div', { textContent: 'No Find My Devices Cached' }, { class: 'rc-empty-state' });
      body.appendChild(empty);
    }

    findMyCard.appendChild(body);
  }
  updateFindMyCard();

  function setFindMyItems(items) {
    findMyItems = Array.isArray(items) ? [...items] : [];
    updateFindMyCard();
  }

  // 4. Mail Widget (Offline-first Mail Digest)
  let mailMessages = [];
  const mailCard = makeDomElement(doc, 'section', {}, {
    class: 'rc-wing-card rc-widget-mail',
    'data-widget': 'mail',
    role: 'region'
  });
  widgetElements.mail = mailCard;

  function updateMailCard() {
    while (mailCard.firstChild) {
      mailCard.removeChild(mailCard.firstChild);
    }

    const header = makeDomElement(doc, 'div', {}, { class: 'rc-widget-header' });
    const titleSpan = makeDomElement(doc, 'span', { textContent: 'Mail Digest' }, { class: 'rc-widget-title' });
    header.appendChild(titleSpan);
    mailCard.appendChild(header);

    const body = makeDomElement(doc, 'div', {}, { class: 'rc-widget-body rc-mail-list' });
    if (mailMessages.length > 0) {
      for (const msg of mailMessages) {
        const itemRow = makeDomElement(doc, 'div', {}, {
          class: `rc-mail-item ${msg.unread ? 'unread' : ''}`.trim(),
          'data-id': msg.id,
          role: 'button',
          tabindex: '0'
        });

        const mHeader = makeDomElement(doc, 'div', {}, { class: 'rc-mail-header' });
        const fromSpan = makeDomElement(doc, 'span', { textContent: msg.from }, { class: 'rc-mail-from' });
        const dateSpan = makeDomElement(doc, 'span', { textContent: msg.date }, { class: 'rc-mail-date' });
        mHeader.appendChild(fromSpan);
        mHeader.appendChild(dateSpan);

        const subEl = makeDomElement(doc, 'div', { textContent: msg.subject }, { class: 'rc-mail-subject' });
        const snipEl = makeDomElement(doc, 'div', { textContent: msg.snippet }, { class: 'rc-mail-snippet' });

        itemRow.appendChild(mHeader);
        itemRow.appendChild(subEl);
        itemRow.appendChild(snipEl);

        itemRow.addEventListener('click', () => {
          const snippet = `> From: ${msg.from}\n> Subject: ${msg.subject}\n> ${msg.snippet}\n\n`;
          if (typeof options.onInsertToPage === 'function') {
            options.onInsertToPage(snippet);
          }
          if (globalObj?.webkit?.messageHandlers?.wings?.postMessage) {
            globalObj.webkit.messageHandlers.wings.postMessage({
              action: 'cite',
              type: 'mail',
              message: msg
            });
          }
        });

        body.appendChild(itemRow);
      }
    } else {
      const empty = makeDomElement(doc, 'div', { textContent: 'No Mail Messages Cached' }, { class: 'rc-empty-state' });
      body.appendChild(empty);
    }

    mailCard.appendChild(body);
  }
  updateMailCard();

  function setMailMessages(messages) {
    mailMessages = Array.isArray(messages) ? [...messages] : [];
    updateMailCard();
  }

  // 5. Calendar Agenda Widget
  let calendarEvents = [];
  const calendarStatus = new Map(); // id → { status: 'saving' | 'added' | 'error', message }

  function formatEventTime(ev) {
    const d = new Date(ev.startISO);
    if (Number.isNaN(d.getTime())) return '';
    try {
      if (ev.allDay) {
        return new Intl.DateTimeFormat(undefined, { weekday: 'short', day: 'numeric', month: 'short' }).format(d) + ' · all day';
      }
      return new Intl.DateTimeFormat(undefined, { weekday: 'short', day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit' }).format(d);
    } catch {
      return d.toLocaleString();
    }
  }

  /** The host's answer to an add: 'added', or 'error' with the reason in words. */
  function setCalendarStatus(id, status, message = '') {
    calendarStatus.set(id, { status, message });
    if (status === 'added') {
      calendarEvents = calendarEvents.map(ev => (ev.id === id ? { ...ev, added: true } : ev));
    }
    updateCalendarCard();
  }
  const calendarCard = makeDomElement(doc, 'section', {}, {
    class: 'rc-wing-card rc-widget-calendar',
    'data-widget': 'calendar',
    role: 'region'
  });
  widgetElements.calendar = calendarCard;

  function updateCalendarCard() {
    while (calendarCard.firstChild) {
      calendarCard.removeChild(calendarCard.firstChild);
    }

    const header = makeDomElement(doc, 'div', {}, { class: 'rc-widget-header' });
    const titleSpan = makeDomElement(doc, 'span', { textContent: 'Agenda' }, { class: 'rc-widget-title' });
    header.appendChild(titleSpan);
    calendarCard.appendChild(header);

    const body = makeDomElement(doc, 'div', {}, { class: 'rc-widget-body rc-calendar-list' });
    if (calendarEvents.length > 0) {
      for (const ev of calendarEvents) {
        const itemRow = makeDomElement(doc, 'div', {}, {
          class: 'rc-cal-item',
          'data-id': ev.id,
          'data-line': ev.lineNumber,
          role: 'button',
          tabindex: '0'
        });

        const titleEl = makeDomElement(doc, 'div', { textContent: ev.title }, { class: 'rc-cal-title' });
        const timeEl = makeDomElement(doc, 'div', { textContent: formatEventTime(ev) }, { class: 'rc-cal-time' });
        const locEl = makeDomElement(doc, 'div', { textContent: `Line ${ev.lineNumber} (Page ${ev.pageIndex + 1})` }, { class: 'rc-cal-loc' });

        itemRow.appendChild(titleEl);
        itemRow.appendChild(timeEl);
        itemRow.appendChild(locEl);

        // The confirm step: nothing reaches the calendar until this is pressed (or "add it" is said).
        const st = ev.added ? { status: 'added' } : (calendarStatus.get(ev.id) || { status: 'proposed' });
        const label = st.status === 'added' ? 'Added to Calendar'
          : st.status === 'saving' ? 'Adding…'
          : st.status === 'error' ? `Not added: ${st.message || 'unknown error'} · Try again`
          : 'Add to Calendar';
        const addEl = makeDomElement(doc, 'div', { textContent: label }, {
          class: `rc-cal-add rc-cal-${st.status}`,
          'data-id': ev.id,
          role: st.status === 'added' || st.status === 'saving' ? 'status' : 'button',
          tabindex: st.status === 'added' || st.status === 'saving' ? '-1' : '0'
        });
        if (st.status === 'proposed' || st.status === 'error') {
          const add = e => {
            if (e?.stopPropagation) e.stopPropagation();
            if (e?.type === 'keydown' && e.key !== 'Enter' && e.key !== ' ') return;
            calendarStatus.set(ev.id, { status: 'saving' });
            updateCalendarCard();
            if (typeof options.onAddEvent === 'function') options.onAddEvent(ev);
          };
          addEl.addEventListener('click', add);
          addEl.addEventListener('keydown', add);
        }
        itemRow.appendChild(addEl);

        itemRow.addEventListener('click', () => {
          if (typeof options.onJumpToLine === 'function') {
            options.onJumpToLine(ev.lineNumber);
          }
          if (typeof options.onSelectEvent === 'function') {
            options.onSelectEvent(ev);
          }
          if (globalObj?.webkit?.messageHandlers?.calendar?.postMessage) {
            globalObj.webkit.messageHandlers.calendar.postMessage({
              action: 'jumpToLine',
              lineNumber: ev.lineNumber,
              event: ev
            });
          }
        });

        body.appendChild(itemRow);
      }
    } else {
      const empty = makeDomElement(doc, 'div', { textContent: 'No Upcoming Agenda' }, { class: 'rc-empty-state' });
      body.appendChild(empty);
    }

    calendarCard.appendChild(body);
  }
  updateCalendarCard();

  function setCalendarEvents(events) {
    calendarEvents = Array.isArray(events) ? [...events] : [];
    updateCalendarCard();
  }

  function openPersistentSession(service) {
    let url = '';
    if (service === 'findmy') {
      url = 'https://www.icloud.com/find';
    } else if (service === 'mail') {
      url = 'https://www.icloud.com/mail';
    } else {
      url = `https://www.icloud.com/${service}`;
    }

    if (globalObj?.webkit?.messageHandlers?.wings?.postMessage) {
      globalObj.webkit.messageHandlers.wings.postMessage({
        action: 'openSession',
        service,
        url
      });
    }
  }

  // 6. iPhone Mirroring (Mac only): opens macOS's own iPhone Mirroring app; the host enables it.
  const iphoneCard = makeDomElement(doc, 'section', {}, {
    class: 'rc-wing-card rc-widget-iphone',
    'data-widget': 'iphone',
    role: 'region'
  });
  widgetElements.iphone = iphoneCard;
  {
    const header = makeDomElement(doc, 'div', {}, { class: 'rc-widget-header' });
    header.appendChild(makeDomElement(doc, 'span', { textContent: 'iPhone Mirroring' }, { class: 'rc-widget-title' }));
    iphoneCard.appendChild(header);
    const openEl = makeDomElement(doc, 'div', { textContent: 'Open iPhone Mirroring' }, {
      class: 'rc-widget-action rc-iphone-open',
      role: 'button',
      tabindex: '0'
    });
    const open = e => {
      if (e?.type === 'keydown' && e.key !== 'Enter' && e.key !== ' ') return;
      postHaptic('open');
      if (globalObj?.webkit?.messageHandlers?.wings?.postMessage) {
        globalObj.webkit.messageHandlers.wings.postMessage({ action: 'openApp', app: 'iphone-mirroring' });
      }
    };
    openEl.addEventListener('click', open);
    openEl.addEventListener('keydown', open);
    iphoneCard.appendChild(openEl);
  }

  // Recense, in both wings: the line on screen now, its words above, the translation under (one frame, two lines).
  // Each wing has its own card; the host (the Mac) sends the line whenever it changes.
  let recenseLine = { original: '', translation: '' };
  const recenseCards = {};
  for (const side of ['left', 'right']) {
    recenseCards[side] = makeDomElement(doc, 'section', {}, {
      class: 'rc-wing-card rc-widget-recense',
      'data-widget': 'recense',
      role: 'region',
      'aria-label': 'Recense',
      'aria-live': 'polite'
    });
  }
  // While you write with the Recense layer on, a typed line takes the card (the caret paragraph's lens line, its
  // source under it); the media's line comes back when the editor loses focus (recense.js).
  let typedLine = null;
  const cardLine = () => typedLine || recenseLine;
  function setTypedLine(card) {
    typedLine = card && (card.original || card.translation)
      ? { original: String(card.original ?? ''), translation: String(card.translation ?? ''), typed: true } : null;
    updateRecenseCards();
    return Boolean(typedLine);
  }
  function updateRecenseCards() {
    for (const card of Object.values(recenseCards)) {
      while (card.firstChild) card.removeChild(card.firstChild);
      const header = makeDomElement(doc, 'div', {}, { class: 'rc-widget-header' });
      header.appendChild(makeDomElement(doc, 'span', { textContent: typedLine ? 'Recense · your text' : 'Recense' }, { class: 'rc-widget-title' }));
      card.appendChild(header);
      if (cardLine().original || cardLine().translation) {
        card.appendChild(makeDomElement(doc, 'div', { textContent: cardLine().original }, { class: 'rc-recense-original' }));
        if (cardLine().translation) {
          card.appendChild(makeDomElement(doc, 'div', { textContent: cardLine().translation }, { class: 'rc-recense-translation' }));
        }
      } else {
        card.appendChild(makeDomElement(doc, 'div', { textContent: 'Nothing playing' }, { class: 'rc-empty-state' }));
      }
    }
    sizeWings();
  }

  // The wings widen with the line, so each of its two rows sits on one line when it can (the card's own font,
  // measured); between 360 and 560 pt, then the words wrap.
  const WING_MIN = 360;
  const WING_MAX = 560;
  let measureCtx = null;
  function textWidth(text, font) {
    if (!text) return 0;
    if (!measureCtx && doc && typeof doc.createElement === 'function') {
      const c = doc.createElement('canvas');
      measureCtx = c && typeof c.getContext === 'function' ? c.getContext('2d') : null;
    }
    if (!measureCtx) return text.length * 9;
    measureCtx.font = font;
    return measureCtx.measureText(text).width;
  }
  function preferredWidth() {
    const pad = 2 * 16 + 4;
    const w = Math.max(
      textWidth(cardLine().original, '600 19px -apple-system, system-ui, sans-serif'),
      textWidth(cardLine().translation, '400 17px -apple-system, system-ui, sans-serif')
    ) + pad;
    return Math.round(Math.min(WING_MAX, Math.max(WING_MIN, w)));
  }
  function sizeWings() {
    const w = `${preferredWidth()}px`;
    for (const el of [leftEl, rightEl]) el.style?.setProperty?.('--rc-wing-w', w);
  }
  function setRecenseLine(original = '', translation = '') {
    recenseLine = { original: String(original ?? ''), translation: String(translation ?? '') };
    updateRecenseCards();
    return preferredWidth();
  }
  updateRecenseCards();

  // The grabber at the top of each wing's inner edge: slide it toward the screen edge and the wing tucks in.
  function grabberFor(side) {
    const g = makeDomElement(doc, 'div', {}, {
      class: `rc-wing-grabber rc-wing-grabber-${side}`,
      role: 'button',
      tabindex: '0',
      'aria-label': `Tuck the ${side} wing in`
    });
    let startX = null;
    g.addEventListener('pointerdown', e => {
      startX = e.clientX;
      if (typeof g.setPointerCapture === 'function' && e.pointerId !== undefined) {
        try { g.setPointerCapture(e.pointerId); } catch { /* capture is a nicety */ }
      }
      if (typeof e.stopPropagation === 'function') e.stopPropagation();
    });
    g.addEventListener('pointermove', e => {
      if (startX === null) return;
      const outward = side === 'left' ? startX - e.clientX : e.clientX - startX;
      if (outward >= 30) {
        startX = null;
        postHaptic('close');
        closeWing(side);
      }
    });
    const end = () => { startX = null; };
    g.addEventListener('pointerup', end);
    g.addEventListener('pointercancel', end);
    // Keyboard: Enter or Space tucks it in too.
    g.addEventListener('keydown', e => {
      if (e.key === 'Enter' || e.key === ' ') closeWing(side);
    });
    return g;
  }
  const grabbers = { left: grabberFor('left'), right: grabberFor('right') };

  const WIDGET_NAMES = {
    recense: 'Recense', preview: 'Preview', quicktime: 'Player', findmy: 'Find My', mail: 'Mail', calendar: 'Agenda',
    iphone: 'iPhone Mirroring'
  };
  // Everything a wing can show, in the order the "Show in wing…" field lists it.
  const CATALOG = ['recense', 'preview', 'quicktime', 'calendar', 'findmy', 'mail', 'iphone'];
  const otherSide = side => (side === 'left' ? 'right' : 'left');
  const CARD_SWIPE = options.cardSwipeThreshold ?? 96;
  const HOLD_MS = 450;
  const UNDO_MS = 5000;
  const later = (fn, ms) => (globalObj?.setTimeout ? globalObj.setTimeout(fn, ms) : setTimeout(fn, ms));
  const cancelLater = t => (globalObj?.clearTimeout ? globalObj.clearTimeout(t) : clearTimeout(t));
  // add / remove, not toggle(force): some hosts' element shims have only these two.
  const cls = (el, name, on) => (on ? el?.classList?.add?.(name) : el?.classList?.remove?.(name));
  const reduceMotion = () => Boolean(globalObj?.matchMedia?.('(prefers-reduced-motion: reduce)')?.matches);
  // Static icons (no user text), drawn in the text colour.
  const TRASH_ICON = '<svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13M10 11v6M14 11v6"/></svg>';
  const PIN_ICON = '<svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="M9 3h6l-1 6 4 4H6l4-4zM12 13v8"/></svg>';

  function shown(wId) {
    return (wId === 'recense' || Boolean(widgetElements[wId])) && (!HOST_WIDGETS.has(wId) || enabledHostWidgets.has(wId));
  }

  // Pins, per wing: pinned cards stay at the top, in the order they were pinned, and nothing replaces them.
  let pinned = { left: [], right: [] };
  const listOf = side => (side === 'left' ? leftWidgets : rightWidgets);
  function setList(side, list) {
    if (side === 'left') leftWidgets = list;
    else rightWidgets = list;
  }
  const isPinned = (side, id) => pinned[side].includes(id);
  /** Pinned cards first (in pin order), the rest after in their own order. */
  function settle(side) {
    const list = listOf(side);
    pinned[side] = pinned[side].filter(id => list.includes(id));
    setList(side, [...pinned[side], ...list.filter(id => !isPinned(side, id))]);
  }
  function takeOut(side, id) {
    setList(side, listOf(side).filter(x => x !== id));
    pinned[side] = pinned[side].filter(x => x !== id);
  }
  function changed() {
    renderWidgets();
    persistWingsState();
  }

  /** Pin or unpin a card (swipe right, its ··· menu, or the API). Returns whether it is pinned now. */
  function pinWidget(side, id, on) {
    if (!listOf(side).includes(id)) return false;
    const want = on === undefined ? !isPinned(side, id) : Boolean(on);
    pinned[side] = pinned[side].filter(x => x !== id);
    if (want) pinned[side].push(id);
    settle(side);
    postHaptic('snap');
    changed();
    return want;
  }

  // The last removal, kept 5 s for Undo.
  let lastRemoved = null;
  function removeWidget(side, id) {
    const index = listOf(side).indexOf(id);
    if (index < 0) return false;
    if (lastRemoved) cancelLater(lastRemoved.timer);
    lastRemoved = { side, id, index, pinned: isPinned(side, id), timer: null };
    takeOut(side, id);
    lastRemoved.timer = later(() => {
      lastRemoved = null;
      renderWidgets();
    }, UNDO_MS);
    postHaptic('close');
    changed();
    return true;
  }
  /** Undo the last removal: the card comes back to the same wing, place and pin. */
  function undoRemove() {
    const r = lastRemoved;
    if (!r) return false;
    cancelLater(r.timer);
    lastRemoved = null;
    if (r.id !== 'recense') takeOut(otherSide(r.side), r.id);
    const list = listOf(r.side).filter(x => x !== r.id);
    list.splice(Math.min(r.index, list.length), 0, r.id);
    setList(r.side, list);
    if (r.pinned && !isPinned(r.side, r.id)) pinned[r.side].push(r.id);
    settle(r.side);
    postHaptic('snap');
    changed();
    return true;
  }

  /** Move a card one place up (-1) or down (+1) within its group (pinned or not). */
  function moveWidgetBy(side, id, delta) {
    const list = [...listOf(side)];
    const i = list.indexOf(id);
    const j = i + delta;
    if (i < 0 || j < 0 || j >= list.length || isPinned(side, list[j]) !== isPinned(side, id)) return false;
    [list[i], list[j]] = [list[j], list[i]];
    if (isPinned(side, id)) pinned[side] = list.filter(x => isPinned(side, x));
    setList(side, list);
    postHaptic('snap');
    changed();
    return true;
  }

  /** Put a card at an index (hold and drag), kept inside its group so pins stay on top. */
  function reorderWidget(side, id, toIndex) {
    const list = listOf(side).filter(x => x !== id);
    if (list.length === listOf(side).length) return false;
    const pinCount = pinned[side].filter(x => x !== id).length;
    const lo = isPinned(side, id) ? 0 : pinCount;
    const hi = isPinned(side, id) ? pinCount : list.length;
    list.splice(Math.max(lo, Math.min(hi, toIndex)), 0, id);
    if (isPinned(side, id)) pinned[side] = list.filter(x => isPinned(side, x));
    setList(side, list);
    postHaptic('snap');
    changed();
    return true;
  }

  /** What "Show in wing…" can add to this wing: everything not on it, filtered by the typed text. */
  function catalogFor(side, query = '') {
    const q = String(query || '').trim().toLowerCase();
    return CATALOG
      .filter(id => shown(id) && !listOf(side).includes(id))
      .map(id => ({
        id,
        name: WIDGET_NAMES[id] || id,
        from: id !== 'recense' && listOf(otherSide(side)).includes(id) ? otherSide(side) : ''
      }))
      .filter(e => !q || e.name.toLowerCase().includes(q) || e.id.includes(q));
  }

  /** Add a card to a wing (a widget on the other wing moves over; Recense can be in both). */
  function addWidget(side, id) {
    if (!CATALOG.includes(id) || !shown(id) || listOf(side).includes(id)) return false;
    if (id !== 'recense') takeOut(otherSide(side), id);
    setList(side, [...listOf(side), id]);
    settle(side);
    postHaptic('snap');
    changed();
    return true;
  }

  // "Show in wing…": a pill that dissolves into a typing field (Reduce Motion: a plain swap, styles.css).
  function findFor(side) {
    const wrap = makeDomElement(doc, 'div', {}, { class: 'rc-wing-find' });
    const pill = makeDomElement(doc, 'div', { textContent: 'Show in wing…' }, {
      class: 'rc-wing-find-pill', role: 'button', tabindex: '0',
      'aria-label': 'Show in wing: find a widget, an app or the Recense card'
    });
    const box = makeDomElement(doc, 'div', {}, { class: 'rc-wing-find-box' });
    const input = makeDomElement(doc, 'input', {}, {
      class: 'rc-wing-find-input', type: 'search', placeholder: 'Show in wing…', 'aria-label': 'Show in wing',
      autocomplete: 'off', spellcheck: 'false'
    });
    const done = makeDomElement(doc, 'div', { textContent: '✕' }, {
      class: 'rc-wing-find-close', role: 'button', tabindex: '0', 'aria-label': 'Close Show in wing'
    });
    const results = makeDomElement(doc, 'div', {}, { class: 'rc-wing-find-results', role: 'listbox' });
    box.appendChild(input);
    box.appendChild(done);
    wrap.appendChild(pill);
    wrap.appendChild(box);
    wrap.appendChild(results);
    let isOpen = false;

    function choose(id) {
      if (addWidget(side, id)) close();
    }
    function refresh() {
      while (results.firstChild) results.removeChild(results.firstChild);
      if (!isOpen) return;
      const items = catalogFor(side, input.value);
      if (!items.length) {
        results.appendChild(makeDomElement(doc, 'div', {
          textContent: input.value ? 'Nothing by that name' : 'Everything is already in this wing'
        }, { class: 'rc-wing-find-empty' }));
        return;
      }
      for (const item of items) {
        const row = makeDomElement(doc, 'div', {
          textContent: item.from ? `${item.name} · from the ${item.from} wing` : item.name
        }, { class: 'rc-wing-find-item', role: 'option', tabindex: '0', 'data-widget': item.id });
        row.addEventListener('click', () => choose(item.id));
        row.addEventListener('keydown', e => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault?.();
            choose(item.id);
          } else if (e.key === 'Escape') close();
        });
        results.appendChild(row);
      }
    }
    // The host hears when the field opens or closes (the Mac panel takes key focus only while it is open).
    const tell = () => options.onFindChange?.(side, isOpen);
    function open(focus = true) {
      const was = isOpen;
      isOpen = true;
      pill.hidden = true;
      box.hidden = false;
      results.hidden = false;
      wrap.classList.add('rc-wing-find-open');
      refresh();
      if (!was) tell();
      if (focus && typeof input.focus === 'function') input.focus();
    }
    function close() {
      const was = isOpen;
      isOpen = false;
      input.value = '';
      pill.hidden = false;
      box.hidden = true;
      results.hidden = true;
      wrap.classList.remove('rc-wing-find-open');
      refresh();
      if (was) tell();
    }
    pill.addEventListener('click', () => open(true));
    pill.addEventListener('keydown', e => {
      if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault?.();
        open(true);
      }
    });
    done.addEventListener('click', close);
    done.addEventListener('keydown', e => {
      if (e.key === 'Enter' || e.key === ' ') close();
    });
    input.addEventListener('input', refresh);
    input.addEventListener('keydown', e => {
      if (e.key === 'Enter') {
        e.preventDefault?.();
        const first = catalogFor(side, input.value)[0];
        if (first) choose(first.id);
      } else if (e.key === 'Escape') {
        e.preventDefault?.();
        close();
      }
    });
    close();
    return { wrap, input, open, close, refresh, tell, isOpen: () => isOpen };
  }
  const finds = { left: findFor('left'), right: findFor('right') };

  // The Undo toast: 5 s after a removal, in the wing it was removed from.
  function toastFor(side) {
    const t = makeDomElement(doc, 'div', {}, { class: 'rc-wing-toast', role: 'status', 'aria-live': 'polite' });
    const text = makeDomElement(doc, 'span', {}, { class: 'rc-wing-toast-text' });
    const undo = makeDomElement(doc, 'div', { textContent: 'Undo' }, {
      class: 'rc-wing-toast-undo', role: 'button', tabindex: '0', 'aria-label': 'Undo remove'
    });
    undo.addEventListener('click', undoRemove);
    undo.addEventListener('keydown', e => {
      if (e.key === 'Enter' || e.key === ' ') undoRemove();
    });
    t.appendChild(text);
    t.appendChild(undo);
    t.hidden = true;
    return { el: t, text };
  }
  const toasts = { left: toastFor('left'), right: toastFor('right') };

  function closeMenus() {
    for (const side of ['left', 'right']) {
      for (const s of Object.values(slots[side])) s.closeMenu();
    }
  }

  // Each card sits in a slot: what a swipe reveals under it, its pin mark, its ··· control and menu.
  const slots = { left: {}, right: {} };
  function slotFor(side, id) {
    if (slots[side][id]) return slots[side][id];
    const card = id === 'recense' ? recenseCards[side] : widgetElements[id];
    const name = WIDGET_NAMES[id] || id;
    const slot = makeDomElement(doc, 'div', {}, { class: 'rc-wing-slot', 'data-widget': id });
    const under = makeDomElement(doc, 'div', {}, { class: 'rc-wing-under', 'aria-hidden': 'true' });
    const underPin = makeDomElement(doc, 'span', {}, { class: 'rc-wing-under-pin' });
    const underRemove = makeDomElement(doc, 'span', {}, { class: 'rc-wing-under-remove' });
    underPin.innerHTML = `${PIN_ICON}<span class="rc-wing-under-label"></span>`;
    underRemove.innerHTML = `<span class="rc-wing-under-label">Remove</span>${TRASH_ICON}`;
    under.appendChild(underPin);
    under.appendChild(underRemove);
    const mark = makeDomElement(doc, 'div', {}, { class: 'rc-wing-pinmark', 'aria-hidden': 'true' });
    mark.innerHTML = PIN_ICON;
    const more = makeDomElement(doc, 'div', { textContent: '···' }, {
      class: 'rc-wing-more', role: 'button', tabindex: '0', 'aria-haspopup': 'menu', 'aria-expanded': 'false',
      'aria-label': `${name} options`
    });
    const menu = makeDomElement(doc, 'div', {}, { class: 'rc-wing-menu', role: 'menu', 'aria-label': `${name} options` });
    menu.hidden = true;
    slot.appendChild(under);
    if (card) slot.appendChild(card);
    slot.appendChild(mark);
    slot.appendChild(more);
    slot.appendChild(menu);

    function closeMenu() {
      menu.hidden = true;
      more.setAttribute('aria-expanded', 'false');
    }
    function openMenu() {
      closeMenus();
      while (menu.firstChild) menu.removeChild(menu.firstChild);
      const list = listOf(side);
      const i = list.indexOf(id);
      const p = isPinned(side, id);
      const items = [
        ['Move up', () => moveWidgetBy(side, id, -1), i > 0 && isPinned(side, list[i - 1]) === p],
        ['Move down', () => moveWidgetBy(side, id, 1), i < list.length - 1 && isPinned(side, list[i + 1]) === p],
        [`Move to the ${otherSide(side)} wing`, () => moveWidget(id, otherSide(side)), true],
        [p ? 'Unpin' : 'Pin', () => pinWidget(side, id), true],
        ['Remove', () => removeWidget(side, id), true]
      ];
      let first = null;
      for (const [label, fn, enabled] of items) {
        const item = makeDomElement(doc, 'div', { textContent: label }, {
          class: `rc-wing-menu-item${label === 'Remove' ? ' rc-wing-menu-danger' : ''}`,
          role: 'menuitem', tabindex: enabled ? '0' : '-1', 'aria-disabled': enabled ? 'false' : 'true'
        });
        const go = e => {
          if (e?.type === 'keydown' && e.key !== 'Enter' && e.key !== ' ') {
            if (e.key === 'Escape') closeMenu();
            return;
          }
          if (!enabled) return;
          closeMenu();
          fn();
        };
        item.addEventListener('click', go);
        item.addEventListener('keydown', go);
        menu.appendChild(item);
        if (enabled && !first) first = item;
      }
      menu.hidden = false;
      more.setAttribute('aria-expanded', 'true');
      if (first && typeof first.focus === 'function') first.focus();
    }
    const toggleMenu = e => {
      if (e?.type === 'keydown' && e.key !== 'Enter' && e.key !== ' ') return;
      if (menu.hidden) openMenu();
      else closeMenu();
    };
    more.addEventListener('click', toggleMenu);
    more.addEventListener('keydown', toggleMenu);

    // Swipe: left = Remove, right = Pin / Unpin. Past the threshold it acts (with a haptic as it arms).
    function showSwipe(dx) {
      const armed = Math.abs(dx) >= CARD_SWIPE;
      cls(slot, 'rc-wing-swipe-left', dx < 0);
      cls(slot, 'rc-wing-swipe-right', dx > 0);
      cls(slot, 'rc-wing-armed', armed);
      const label = underPin.querySelector?.('.rc-wing-under-label');
      if (label) label.textContent = isPinned(side, id) ? 'Unpin' : 'Pin';
      if (card?.style) {
        if (reduceMotion()) card.style.opacity = String(1 - Math.min(Math.abs(dx) / CARD_SWIPE, 1) * 0.6);
        else card.style.transform = dx ? `translateX(${dx}px)` : '';
      }
      return armed;
    }
    function endSwipe(dx) {
      showSwipe(0);
      slot.classList.remove('rc-wing-swipe-left', 'rc-wing-swipe-right', 'rc-wing-armed');
      if (card?.style) {
        card.style.transform = '';
        card.style.opacity = '';
      }
      if (dx <= -CARD_SWIPE) removeWidget(side, id);
      else if (dx >= CARD_SWIPE) pinWidget(side, id);
    }

    let drag = null;
    const SKIP = 'input, textarea, select, video, audio, iframe, .rc-wing-more, .rc-wing-menu, .rc-card-pick-btn';
    slot.addEventListener('pointerdown', e => {
      if ((e.button ?? 0) > 0 || e.target?.closest?.(SKIP)) return;
      drag = { x: e.clientX, y: e.clientY, pointerId: e.pointerId, mode: null, dx: 0, dy: 0, armed: false };
      drag.hold = later(() => {
        if (drag && !drag.mode) {
          drag.mode = 'reorder';
          slot.classList.add('rc-wing-lifted');
          postHaptic('snap');
        }
      }, HOLD_MS);
    });
    slot.addEventListener('pointermove', e => {
      if (!drag) return;
      drag.dx = e.clientX - drag.x;
      drag.dy = e.clientY - drag.y;
      if (!drag.mode) {
        if (Math.abs(drag.dx) < 10 && Math.abs(drag.dy) < 10) return;
        cancelLater(drag.hold);
        if (Math.abs(drag.dx) <= Math.abs(drag.dy) * 1.3) {
          drag = null; // a vertical move: the wing scrolls
          return;
        }
        drag.mode = 'swipe';
        if (typeof slot.setPointerCapture === 'function' && drag.pointerId !== undefined) {
          try { slot.setPointerCapture(drag.pointerId); } catch { /* capture is a nicety */ }
        }
      }
      // The card's swipe, not the wing's: the wing's own close swipe must not see it.
      e.stopPropagation?.();
      e.preventDefault?.();
      if (drag.mode === 'swipe') {
        const armed = showSwipe(drag.dx);
        if (armed && !drag.armed) postHaptic('edge');
        drag.armed = armed;
      } else if (drag.mode === 'reorder' && card?.style && !reduceMotion()) {
        card.style.transform = `translateY(${drag.dy}px)`;
      }
    });
    const finish = e => {
      if (!drag) return;
      cancelLater(drag.hold);
      const d = drag;
      drag = null;
      if (d.mode === 'swipe') endSwipe(d.dx);
      else if (d.mode === 'reorder') {
        slot.classList.remove('rc-wing-lifted');
        if (card?.style) card.style.transform = '';
        if (e?.type === 'pointerup') reorderWidget(side, id, dropIndex(side, id, e.clientY));
      }
    };
    slot.addEventListener('pointerup', finish);
    slot.addEventListener('pointercancel', finish);
    // iOS also sends touch events: keep a card's swipe away from the wing's own close swipe.
    slot.addEventListener('touchmove', e => {
      if (drag?.mode) e.stopPropagation?.();
    });

    // Mac: a two-finger horizontal swipe on the trackpad does the same (wheel deltaX; fingers left = deltaX > 0).
    let wheel = null;
    slot.addEventListener('wheel', e => {
      const dx = Number(e.deltaX) || 0;
      const dy = Number(e.deltaY) || 0;
      if (!wheel && Math.abs(dx) <= Math.abs(dy)) return;
      e.preventDefault?.();
      e.stopPropagation?.();
      if (!wheel) wheel = { acc: 0, armed: false, timer: null };
      wheel.acc -= dx;
      const armed = showSwipe(wheel.acc);
      if (armed && !wheel.armed) postHaptic('edge');
      wheel.armed = armed;
      cancelLater(wheel.timer);
      wheel.timer = later(() => {
        const acc = wheel.acc;
        wheel = null;
        endSwipe(acc);
      }, 160);
    }, { passive: false });

    const s = { slot, card, mark, more, menu, openMenu, closeMenu, showSwipe, endSwipe };
    slots[side][id] = s;
    return s;
  }

  /** Where a held card lands: the number of other cards whose middle is above the pointer. */
  function dropIndex(side, id, clientY) {
    let n = 0;
    for (const other of listOf(side)) {
      if (other === id) continue;
      const r = slots[side][other]?.slot?.getBoundingClientRect?.();
      if (r && r.top + r.height / 2 < clientY) n += 1;
    }
    return n;
  }

  // Render widget cards into wings: the grabber, "Show in wing…" and the Undo toast stay put; the cards follow.
  function renderWidgets() {
    closeMenus();
    for (const [el, side] of [[leftEl, 'left'], [rightEl, 'right']]) {
      const fixed = [grabbers[side], finds[side].wrap, toasts[side].el];
      for (const child of [...(el.children || el.childNodes || [])]) {
        if (!fixed.includes(child)) el.removeChild(child);
      }
      if (!el.appendChild) continue;
      if (![...(el.children || el.childNodes || [])].includes(grabbers[side])) for (const f of fixed) el.appendChild(f);
      for (const wId of listOf(side)) {
        if (!shown(wId)) continue;
        const s = slotFor(side, wId);
        if (!s.card) continue;
        cls(s.slot, 'rc-wing-pinned', isPinned(side, wId));
        el.appendChild(s.slot);
      }
      const t = toasts[side];
      const mine = lastRemoved && lastRemoved.side === side;
      t.el.hidden = !mine;
      t.text.textContent = mine ? `${WIDGET_NAMES[lastRemoved.id] || lastRemoved.id} removed` : '';
      finds[side].refresh();
    }
  }
  renderWidgets();

  /** A wing just came into view: with nothing playing, "Show in wing…" opens by itself, cursor in it. */
  const nothingPlaying = () => !qtData.src && !recenseLine.original && !recenseLine.translation;
  function wingShown(side) {
    closeMenus();
    const f = finds[side];
    if (!f) return false;
    if (nothingPlaying()) {
      const was = f.isOpen();
      f.open(true);
      if (was) f.tell(); // still open from last time: the host takes focus again for this opening
    } else if (!f.input.value) f.close();
    return f.isOpen();
  }

  /** The host turns on a widget only it can run (the Mac: 'iphone'). First time: it goes in the left wing. */
  function enableHostWidget(wId) {
    if (!HOST_WIDGETS.has(wId)) return;
    enabledHostWidgets.add(wId);
    if (!leftWidgets.includes(wId) && !rightWidgets.includes(wId)) leftWidgets.push(wId);
    renderWidgets();
  }

  // The Mac's native wing panels (strip/wingpanels.swift): while set, open / close / toggle go to the host, which
  // shows the wings in floating panels at the screen edges; the in-page wings stay hidden. iOS never sets it.
  let nativeWings = null;
  function setNativeWings(fn) {
    nativeWings = typeof fn === 'function' ? fn : null;
    if (nativeWings) {
      leftEl.hidden = true;
      rightEl.hidden = true;
    }
  }

  /** A wing panel's own page shows its one side, without asking the host. */
  function reveal(side) {
    leftEl.hidden = side !== 'left';
    rightEl.hidden = side !== 'right';
  }

  // Symmetric ambidextrous controls
  function openWing(side) {
    if (nativeWings) {
      nativeWings('open', side);
      return;
    }
    if (side === 'left' || side === 'both') {
      leftEl.hidden = false;
    }
    if (side === 'right' || side === 'both') {
      rightEl.hidden = false;
    }
    if (side === 'left' || side === 'both') wingShown('left');
    if (side === 'right' || side === 'both') wingShown('right');
    postHaptic('open');
  }

  function closeWing(side) {
    if (nativeWings) {
      nativeWings('close', side);
      return;
    }
    if (side === 'left' || side === 'both') {
      leftEl.hidden = true;
    }
    if (side === 'right' || side === 'both') {
      rightEl.hidden = true;
    }
  }

  function toggleWing(side) {
    if (nativeWings) {
      nativeWings('toggle', side);
      return;
    }
    if (side === 'left') {
      if (leftEl.hidden) openWing('left');
      else closeWing('left');
    } else if (side === 'right') {
      if (rightEl.hidden) openWing('right');
      else closeWing('right');
    } else if (side === 'both') {
      if (leftEl.hidden || rightEl.hidden) openWing('both');
      else closeWing('both');
    }
  }

  function isWingOpen(side) {
    if (side === 'left') return !leftEl.hidden;
    if (side === 'right') return !rightEl.hidden;
    if (side === 'both') return !leftEl.hidden && !rightEl.hidden;
    return !leftEl.hidden || !rightEl.hidden;
  }

  function getState() {
    return {
      version: 2,
      leftWidgets: [...leftWidgets],
      rightWidgets: [...rightWidgets],
      pinned: { left: [...pinned.left], right: [...pinned.right] },
      previewData: { ...previewData },
      qtData: { ...qtData, loopRange: [...qtData.loopRange] },
      findMyItems: [...findMyItems],
      mailMessages: [...mailMessages]
    };
  }

  function persistWingsState() {
    if (globalObj?.webkit?.messageHandlers?.wings?.postMessage) {
      globalObj.webkit.messageHandlers.wings.postMessage({
        action: 'saveState',
        state: JSON.stringify(getState())
      });
    }
  }

  function setState(raw) {
    if (!raw) return;
    let parsed = raw;
    if (typeof raw === 'string') {
      try {
        parsed = JSON.parse(raw);
      } catch {
        return;
      }
    }
    if (!parsed || typeof parsed !== 'object') return;
    // Version 1 had the Recense card fixed at the top of both wings; from version 2 it is a card like the others.
    const v1 = !(Number(parsed.version) >= 2);
    const lists = list => {
      const ids = list.filter(id => typeof id === 'string');
      return v1 && !ids.includes('recense') ? ['recense', ...ids] : ids;
    };
    if (Array.isArray(parsed.leftWidgets)) leftWidgets = lists(parsed.leftWidgets);
    if (Array.isArray(parsed.rightWidgets)) rightWidgets = lists(parsed.rightWidgets);
    const p = parsed.pinned && typeof parsed.pinned === 'object' ? parsed.pinned : {};
    pinned = {
      left: Array.isArray(p.left) ? p.left.filter(id => typeof id === 'string') : [],
      right: Array.isArray(p.right) ? p.right.filter(id => typeof id === 'string') : []
    };
    settle('left');
    settle('right');
    if (parsed.previewData && typeof parsed.previewData === 'object') {
      previewData = {
        src: String(parsed.previewData.src || ''),
        caption: String(parsed.previewData.caption || '')
      };
      updatePreviewCard();
    }
    if (parsed.qtData && typeof parsed.qtData === 'object') {
      qtData = {
        src: String(parsed.qtData.src || ''),
        title: String(parsed.qtData.title || ''),
        playbackRate: Number(parsed.qtData.playbackRate) || 1.0,
        loopRange: Array.isArray(parsed.qtData.loopRange) ? [...parsed.qtData.loopRange] : [0, 0],
        currentTime: Number(parsed.qtData.currentTime) || 0
      };
      updateQuickTimeCard();
    }
    if (Array.isArray(parsed.findMyItems)) {
      findMyItems = [...parsed.findMyItems];
      updateFindMyCard();
    }
    if (Array.isArray(parsed.mailMessages)) {
      mailMessages = [...parsed.mailMessages];
      updateMailCard();
    }
    renderWidgets();
  }

  function swapWings() {
    const temp = leftWidgets;
    leftWidgets = rightWidgets;
    rightWidgets = temp;
    pinned = { left: pinned.right, right: pinned.left };
    renderWidgets();
    postHaptic('snap');
    persistWingsState();
  }

  /** Move a card to the other wing (its ··· menu, voice or API). A pinned card stays pinned there. */
  function moveWidget(widgetId, targetSide) {
    if (targetSide !== 'left' && targetSide !== 'right') return;
    const from = otherSide(targetSide);
    if (listOf(targetSide).includes(widgetId)) {
      // Recense can be in both wings: moving it from one where the other has it already just leaves that one.
      if (widgetId === 'recense' && listOf(from).includes('recense')) {
        takeOut(from, 'recense');
        postHaptic('snap');
        changed();
      }
      return;
    }
    const wasPinned = isPinned(from, widgetId);
    takeOut(from, widgetId);
    setList(targetSide, [...listOf(targetSide), widgetId]);
    if (wasPinned) pinned[targetSide].push(widgetId);
    settle(targetSide);
    postHaptic('snap');
    changed();
  }

  function getWingLayout() {
    return {
      left: [...leftWidgets],
      right: [...rightWidgets],
      leftOpen: !leftEl.hidden,
      rightOpen: !rightEl.hidden
    };
  }

  // Edge-swipe / bilateral pinch gesture kinetics
  const EDGE_THRESHOLD = options.edgeThreshold ?? 24;
  const SWIPE_THRESHOLD = options.swipeThreshold ?? 36;
  const activeTouches = new Map();
  let gestureHandled = false;

  function getContainerWidth() {
    return (
      container?.clientWidth ||
      (typeof container?.getBoundingClientRect === 'function' ? container.getBoundingClientRect().width : 800) ||
      800
    );
  }

  function handleTouchStart(e) {
    gestureHandled = false;
    const touches = e.changedTouches || (e.clientX !== undefined ? [e] : []);
    for (let i = 0; i < touches.length; i++) {
      const t = touches[i];
      const id = t.identifier !== undefined ? t.identifier : (t.pointerId !== undefined ? t.pointerId : 'single');
      activeTouches.set(id, {
        startX: t.clientX,
        startY: t.clientY,
        currentX: t.clientX,
        currentY: t.clientY
      });
    }
  }

  function handleTouchMove(e) {
    const touches = e.changedTouches || (e.clientX !== undefined ? [e] : []);
    for (let i = 0; i < touches.length; i++) {
      const t = touches[i];
      const id = t.identifier !== undefined ? t.identifier : (t.pointerId !== undefined ? t.pointerId : 'single');
      const record = activeTouches.get(id);
      if (record) {
        record.currentX = t.clientX;
        record.currentY = t.clientY;
      }
    }

    if (gestureHandled) return;

    const width = getContainerWidth();

    // Two-touch simultaneous bilateral inward swipe opens both wings
    if (activeTouches.size >= 2) {
      const records = Array.from(activeTouches.values());
      const leftTouch = records.find(r => r.startX <= EDGE_THRESHOLD && (r.currentX - r.startX) >= SWIPE_THRESHOLD);
      const rightTouch = records.find(r => r.startX >= width - EDGE_THRESHOLD && (r.currentX - r.startX) <= -SWIPE_THRESHOLD);

      if (leftTouch && rightTouch) {
        openWing('both');
        gestureHandled = true;
        return;
      }
    }

    // Single-touch edge swipe
    for (const record of activeTouches.values()) {
      const dx = record.currentX - record.startX;

      // Swiping inward from left edge: opens Left Wing
      if (record.startX <= EDGE_THRESHOLD && dx >= SWIPE_THRESHOLD) {
        openWing('left');
        gestureHandled = true;
        return;
      }

      // Swiping inward from right edge: opens Right Wing
      if (record.startX >= width - EDGE_THRESHOLD && dx <= -SWIPE_THRESHOLD) {
        openWing('right');
        gestureHandled = true;
        return;
      }

      // Swiping outward back toward edge: closes that wing
      if (!leftEl.hidden && dx <= -SWIPE_THRESHOLD) {
        closeWing('left');
        gestureHandled = true;
        return;
      }

      if (!rightEl.hidden && dx >= SWIPE_THRESHOLD) {
        closeWing('right');
        gestureHandled = true;
        return;
      }
    }
  }

  function handleTouchEnd(e) {
    const touches = e.changedTouches || (e.clientX !== undefined ? [e] : []);
    for (let i = 0; i < touches.length; i++) {
      const t = touches[i];
      const id = t.identifier !== undefined ? t.identifier : (t.pointerId !== undefined ? t.pointerId : 'single');
      activeTouches.delete(id);
    }
    if (activeTouches.size === 0) {
      gestureHandled = false;
    }
  }

  // A wing panel's page has no edges to swipe from (the trackpad edge opens it natively): gestures: false.
  const listening = options.gestures !== false;
  if (listening && container?.addEventListener) {
    container.addEventListener('touchstart', handleTouchStart);
    container.addEventListener('touchmove', handleTouchMove);
    container.addEventListener('touchend', handleTouchEnd);
    container.addEventListener('touchcancel', handleTouchEnd);

    container.addEventListener('pointerdown', handleTouchStart);
    container.addEventListener('pointermove', handleTouchMove);
    container.addEventListener('pointerup', handleTouchEnd);
    container.addEventListener('pointercancel', handleTouchEnd);
  }

  function destroy() {
    if (container?.removeEventListener) {
      container.removeEventListener('touchstart', handleTouchStart);
      container.removeEventListener('touchmove', handleTouchMove);
      container.removeEventListener('touchend', handleTouchEnd);
      container.removeEventListener('touchcancel', handleTouchEnd);

      container.removeEventListener('pointerdown', handleTouchStart);
      container.removeEventListener('pointermove', handleTouchMove);
      container.removeEventListener('pointerup', handleTouchEnd);
      container.removeEventListener('pointercancel', handleTouchEnd);
    }
    if (leftEl.parentNode?.removeChild) leftEl.parentNode.removeChild(leftEl);
    if (rightEl.parentNode?.removeChild) rightEl.parentNode.removeChild(rightEl);
  }

  return {
    openWing,
    closeWing,
    toggleWing,
    isWingOpen,
    swapWings,
    moveWidget,
    getWingLayout,
    setPreviewTarget,
    setMediaSource,
    setPlaybackRate,
    setLoopRange,
    setFindMyItems,
    setMailMessages,
    setCalendarEvents,
    setCalendarStatus,
    enableHostWidget,
    setNativeWings,
    reveal,
    wingShown,
    addWidget,
    removeWidget,
    undoRemove,
    pinWidget,
    moveWidgetBy,
    reorderWidget,
    catalogFor,
    openFind: side => finds[side]?.open(true),
    closeFind: side => finds[side]?.close(),
    isFindOpen: side => Boolean(finds[side]?.isOpen()),
    getPinned: () => ({ left: [...pinned.left], right: [...pinned.right] }),
    setRecenseLine,
    setTypedLine,
    preferredWidth,
    openPersistentSession,
    getState,
    setState,
    destroy,
    leftEl,
    rightEl,
    container
  };
}
