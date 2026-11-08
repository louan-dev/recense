/**
 * wingpanel.js · One wing in a native floating panel on the Mac (strip/wingpanels.swift).
 *
 * The host loads this same page with `window.__RECENSE_WING_SIDE = 'left' | 'right'`; the page then shows that
 * side's wing only (no editor), laid out like macOS Notification Center: a title with a close (×) control, the
 * cards, and an "Arrange" pill that shows each card's Move control. The host draws the frosted glass behind each
 * card (NSVisualEffectView), so the page reports where every glass shape is and how tall it is.
 *
 * page → host (wings channel): {action:'wing', op:'open'|'close'|'toggle', side}, {action:'insert', text},
 *   {action:'jumpToLine', line}, {action:'layout', height, width, glass:[[x, y, w, h, opacity, radius], …]}
 *   (width: what the Recense card's line needs, 360–560),
 *   plus wings.js's own saveState / openApp / cite messages.
 * host → page: window.recenseEditor.setText, setWingsState, setCalendarAdded, calendarResult, enableWidget,
 *   setRecenseLine, setTypedLine, setArranging, setTheme (the same names the editor page answers to, so one host class serves both).
 * The wing stays open until its ×, its grabber slid toward the edge, the trackpad's three-finger swipe or the menu:
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

/** A div that acts as a button: click, Enter or Space (the wings use no <button> chrome). */
function pressable(node, fn) {
  node.addEventListener('click', fn);
  node.addEventListener('keydown', e => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      fn(e);
    }
  });
  return node;
}

export function mountWingPanel(root, side, { globalObj = typeof window !== 'undefined' ? window : null } = {}) {
  const doc = root.ownerDocument || document;
  const post = msg => globalObj?.webkit?.messageHandlers?.wings?.postMessage?.(msg);
  doc.documentElement.classList.add('rc-wings-page');

  const shell = el(doc, 'div', `rc-wings-only rc-wings-only-${side}`);
  const head = el(doc, 'div', 'rc-wingpanel-head');
  const title = el(doc, 'span', 'rc-wingpanel-title', side === 'left' ? 'Left Wing' : 'Right Wing');
  const close = pressable(
    el(doc, 'div', 'rc-wingpanel-close rc-glass', '×', { role: 'button', tabindex: '0', 'aria-label': 'Close wing' }),
    () => post({ action: 'wing', op: 'close', side })
  );
  // The close control sits at the outer edge, as Notification Center's does; the left panel mirrors it.
  if (side === 'left') head.append(close, title);
  else head.append(title, close);
  const body = el(doc, 'div', 'rc-wingpanel-body');
  const foot = el(doc, 'div', 'rc-wingpanel-foot');
  const arrange = el(doc, 'div', 'rc-wingpanel-arrange rc-glass', 'Arrange', {
    role: 'button', tabindex: '0', 'aria-pressed': 'false', 'aria-label': 'Arrange cards: show Move to the other side'
  });
  foot.append(arrange);
  shell.append(head, body, foot);
  root.appendChild(shell);

  const scanner = createCalendarScanner({ globalObj });
  const wings = createDualWings(body, {
    onInsertToPage: text => post({ action: 'insert', text: String(text ?? '') }),
    onJumpToLine: line => post({ action: 'jumpToLine', line: Number(line) || 1 }),
    onAddEvent: ev => scanner.requestAdd(ev),
    gestures: false,
    globalObj
  });
  wings.setNativeWings((op, s) => post({ action: 'wing', op, side: s }));
  wings.reveal(side);

  let arranging = false;
  function setArranging(on) {
    arranging = wings.setArranging(on);
    arrange.textContent = arranging ? 'Done' : 'Arrange';
    arrange.setAttribute('aria-pressed', String(arranging));
    schedule();
    return arranging;
  }
  pressable(arrange, () => setArranging(!arranging));

  // Where the glass goes: every card, every shown Move control, the close control and the pill.
  function glassShapes() {
    const shown = side === 'left' ? wings.leftEl : wings.rightEl;
    const nodes = [...shell.querySelectorAll('.rc-glass'), ...shown.querySelectorAll('.rc-wing-card, .rc-wing-move')];
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
      wings.setArranging(arranging);
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
