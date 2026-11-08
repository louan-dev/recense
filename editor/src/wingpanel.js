/**
 * wingpanel.js · One wing in a native floating panel on the Mac (strip/wingpanels.swift).
 *
 * The host loads this same page with `window.__RECENSE_WING_SIDE = 'left' | 'right'`; the page then shows that
 * side's wing only (no editor), laid out like macOS Notification Center: no title and no ×, just the grabber at the
 * top of the inner edge, "Show in wing…" and the cards (each with its ··· menu). The host draws the frosted glass behind each
 * card (NSVisualEffectView), so the page reports where every glass shape is and how tall it is.
 *
 * page → host (wings channel): {action:'wing', op:'open'|'close'|'toggle'|'focus'|'unfocus', side} (focus: the
 *   "Show in wing…" field opened, so the panel takes key focus; unfocus: it closed, give it back), {action:'insert', text},
 *   {action:'jumpToLine', line}, {action:'layout', height, width, glass:[[x, y, w, h, opacity, radius], …]}
 *   (width: what the Recense card's line needs, 360–560),
 *   plus wings.js's own saveState / openApp / cite messages.
 * host → page: window.recenseEditor.setText, setWingsState, setCalendarAdded, calendarResult, enableWidget,
 *   setRecenseLine, setTypedLine, setArranging, setTheme (the same names the editor page answers to, so one host class serves both).
 *   setArranging is the host's "the panel just opened" call (wingpanels.swift sends it on every open): the wing then
 *   opens "Show in wing…" by itself when nothing plays. No Arrange pill any more (W2).
 * The wing stays open until its grabber is slid toward the edge (or pressed), the trackpad's three-finger swipe or the menu:
 * no Esc, no click outside.
 */

import { createDualWings, createCalendarScanner } from './wings.js';

/** The side this page shows, or null for the editor itself. */
export function wingSideFrom(globalObj) {
  const s = globalObj?.__RECENSE_WING_SIDE;
  if (s === 'left' || s === 'right') return s;
  const m = /^#wings=(left|right)$/.exec(String(globalObj?.location?.hash || ''));
  return m ? m[1] : null;
}

function el(doc, tag, cls, text, attrs = {}) {
  const e = doc.createElement(tag);
  if (cls) e.className = cls;
  if (text) e.textContent = text;
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  return e;
}

const GLASS = '.rc-wing-card, .rc-wing-find-pill, .rc-wing-find-box, .rc-wing-find-results, .rc-wing-menu, .rc-wing-toast';

export function mountWingPanel(root, side, { globalObj = typeof window !== 'undefined' ? window : null } = {}) {
  const doc = root.ownerDocument || document;
  const post = msg => globalObj?.webkit?.messageHandlers?.wings?.postMessage?.(msg);
  doc.documentElement.classList.add('rc-wings-page');

  // No visible title (owner, W2); VoiceOver still names the wing.
  const shell = el(doc, 'div', `rc-wings-only rc-wings-only-${side}`, '', {
    role: 'region', 'aria-label': side === 'left' ? 'Left wing' : 'Right wing'
  });
  const body = el(doc, 'div', 'rc-wingpanel-body');
  shell.append(body);
  root.appendChild(shell);

  const scanner = createCalendarScanner({ globalObj });
  const wings = createDualWings(body, {
    onInsertToPage: text => post({ action: 'insert', text: String(text ?? '') }),
    onJumpToLine: line => post({ action: 'jumpToLine', line: Number(line) || 1 }),
    onAddEvent: ev => scanner.requestAdd(ev),
    gestures: false,
    onFindChange: (s, open) => post({ action: 'wing', op: open ? 'focus' : 'unfocus', side: s }),
    globalObj
  });
  wings.setNativeWings((op, s) => post({ action: 'wing', op, side: s }));
  wings.reveal(side);

  // The host's "this panel just opened" (it sends setArranging(false) on every open; the name is kept for it).
  function setArranging() {
    const open = wings.wingShown(side);
    schedule();
    return open;
  }

  // Where the glass goes: every card, "Show in wing…" (pill, field, list), an open ··· menu and the Undo toast.
  function glassShapes() {
    const shown = side === 'left' ? wings.leftEl : wings.rightEl;
    const nodes = [...shell.querySelectorAll('.rc-glass'), ...shown.querySelectorAll(GLASS)];
    const out = [];
    for (const n of nodes) {
      const r = n.getBoundingClientRect();
      if (r.width < 1 || r.height < 1) continue;
      const cs = globalObj.getComputedStyle ? globalObj.getComputedStyle(n) : null;
      const radius = cs ? parseFloat(cs.borderTopLeftRadius) || 0 : 0;
      const opacity = cs ? Number(cs.opacity) : 1;
      out.push([r.left, r.top, r.width, r.height, Number.isFinite(opacity) ? opacity : 1, Math.min(radius, r.height / 2)]);
    }
    return out;
  }
  let lastReport = '';
  function report() {
    const msg = {
      action: 'layout',
      height: Math.ceil(shell.getBoundingClientRect().height),
      width: wings.preferredWidth(),
      glass: glassShapes()
    };
    const key = JSON.stringify(msg);
    if (key !== lastReport) {
      lastReport = key;
      post(msg);
    }
  }
  let frame = 0;
  function schedule() {
    if (frame) return;
    frame = globalObj.requestAnimationFrame(() => {
      frame = 0;
      report();
    });
  }
  if (globalObj.ResizeObserver) new globalObj.ResizeObserver(schedule).observe(shell);
  globalObj.addEventListener('scroll', schedule, { passive: true });
  globalObj.addEventListener('resize', schedule);

  const rescan = text => wings.setCalendarEvents(scanner.scanText(String(text ?? '')));
  let docText = '';
  const api = {
    // The pad's text, so the Agenda card lists its dates (scanning only proposes; Add is the confirm step).
    setText(s) {
      docText = typeof s === 'string' ? s : String(s ?? '');
      rescan(docText);
      schedule();
    },
    getText: () => docText,
    focus() {},
    setTheme(mode) {
      doc.documentElement.setAttribute('data-theme', mode === 'light' ? 'light' : 'dark');
    },
    setFontSize() {},
    setInk() {},
    voiceCommand() {},
    setWingsState(state) {
      wings.setState(state);
      wings.reveal(side);
      schedule();
    },
    getWingsState: () => wings.getState(),
    setCalendarAdded(data) {
      const ids = typeof data === 'string' ? JSON.parse(data) : data;
      if (Array.isArray(ids)) scanner.markSynced(ids);
      rescan(docText);
      schedule();
    },
    calendarResult(id, ok, message) {
      if (ok) scanner.markSynced(id);
      wings.setCalendarStatus(id, ok ? 'added' : 'error', message || '');
      schedule();
    },
    enableWidget(id) {
      wings.enableHostWidget(id);
      schedule();
    },
    // The line on Recense's screen: the card shows it, and the panel widens to fit it.
    setRecenseLine(original, translation) {
      const w = wings.setRecenseLine(original, translation);
      schedule();
      return w;
    },
    // While you write with the Recense layer on: your text's lens line, its source under it (null: the media's again).
    setTypedLine(card) {
      const on = wings.setTypedLine(card);
      schedule();
      return on;
    },
    setArranging,
    layout: () => ({ height: Math.ceil(shell.getBoundingClientRect().height), width: wings.preferredWidth(), glass: glassShapes() })
  };
  if (globalObj) globalObj.recenseEditor = api;
  schedule();
  return { api, wings, shell, setArranging };
}
