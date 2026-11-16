// Derived from Spec: UI-04 P9–P12 — the Lasso tool's selection: Freeform | Boxed lasso, a dashed box with a scale
// handle (right side) and a rotate handle (on a stem above), the selection menu (Style · Duplicate · Cut · Copy ·
// Paste · Delete · › Group, Mirror Horizontally, Mirror Vertically) and the Stroke | Fill style panel.
// Geometry lives in inkshapes.js; this file is the pointer state machine and the DOM.

import {
  selectInLasso, strokesBounds, translate, scaleAbout, rotateAbout, mirrorH, mirrorV,
  transformStroke, duplicateStrokes, toggleGroup, applyStyle, isClosedShape, newStrokeId, STROKE_STYLES
} from './inkshapes.js';

export const LASSO_MODES = ['freeform', 'boxed'];
export const SELECTION_PAD = 8;
export const HANDLE_HIT = 16;
export const ROTATE_STEM = 28;
export const LONG_PRESS_MS = 500;
export const LONG_PRESS_SLOP = 6;
export const PASTE_OFFSET = 16;
const MODE_KEY = 'rc-ink-lasso-mode';
const SVG = 'http://www.w3.org/2000/svg';

/** Where a press at (x, y) lands on a selection box: 'rotate' | 'scale' | 'move' | null. Pure. */
export function selectionHit(box, x, y) {
  if (!box) return null;
  const midX = (box.minX + box.maxX) / 2, midY = (box.minY + box.maxY) / 2;
  if (Math.hypot(x - midX, y - (box.minY - ROTATE_STEM)) <= HANDLE_HIT) return 'rotate';
  if (Math.hypot(x - box.maxX, y - midY) <= HANDLE_HIT) return 'scale';
  if (x >= box.minX && x <= box.maxX && y >= box.minY && y <= box.maxY) return 'move';
  return null;
}

/**
 * The drag's transform from its start (x0, y0) to (x, y). Pure.
 * move: translate; scale: uniform about the box's left-side midpoint (min 0.1×); rotate: about the box centre.
 */
export function dragMatrix(kind, box, x0, y0, x, y) {
  const midX = (box.minX + box.maxX) / 2, midY = (box.minY + box.maxY) / 2;
  if (kind === 'move') return translate(x - x0, y - y0);
  if (kind === 'scale') {
    const w0 = Math.max(1, box.maxX - box.minX);
    const s = Math.max(0.1, (box.maxX - box.minX + (x - x0)) / w0);
    return scaleAbout(s, box.minX, midY);
  }
  if (kind === 'rotate') {
    const a = Math.atan2(y - midY, x - midX) - Math.atan2(y0 - midY, x0 - midX);
    return rotateAbout(a, midX, midY);
  }
  return [1, 0, 0, 1, 0, 0];
}

/**
 * host: {
 *   doc, svg, globalObj,
 *   strokes()             → the strokes on the current page,
 *   replace(list, commit) → put these (same ids) in place; commit re-anchors and saves,
 *   add(list)             → new strokes (anchored, saved),
 *   remove(ids)           → delete with tombstones,
 *   toClient(x, y)        → viewport point for a content point,
 *   colors()              → the palette's eight colours,
 *   haptic(kind)
 * }
 */
export function createInkSelection(host) {
  const { doc, svg, globalObj } = host;
  let mode = (() => {
    try { const m = globalObj?.localStorage?.getItem(MODE_KEY); if (LASSO_MODES.includes(m)) return m; } catch { /* none */ }
    return 'freeform';
  })();
  let ids = [];
  let lasso = null;        // [[x, y], ...] while drawing
  let drag = null;         // { kind, box, x0, y0, originals }
  let press = null;        // { x, y, timer } long-press probe on empty page
  let clipboard = [];
  let menu = null, panel = null, group = null;

  if (svg && doc && typeof doc.createElementNS === 'function') {
    group = doc.createElementNS(SVG, 'g');
    group.setAttribute('class', 'rc-ink-selection');
    svg.appendChild(group);
  }

  const byId = () => new Map(host.strokes().map(s => [s.id, s]));
  const selected = () => { const m = byId(); return ids.map(id => m.get(id)).filter(Boolean); };
  function box() {
    const sel = selected();
    if (!sel.length) return null;
    const b = strokesBounds(sel);
    return { minX: b.minX - SELECTION_PAD, minY: b.minY - SELECTION_PAD, maxX: b.maxX + SELECTION_PAD, maxY: b.maxY + SELECTION_PAD };
  }

  function el(name, attrs) {
    const e = doc.createElementNS(SVG, name);
    for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, String(v));
    return e;
  }

  function draw() {
    if (!group) return;
    group.innerHTML = '';
    if (lasso && lasso.length > 1) {
      let pts = lasso;
      if (mode === 'boxed') {
        const [a, b] = [lasso[0], lasso[lasso.length - 1]];
        pts = [a, [b[0], a[1]], b, [a[0], b[1]], a];
      }
      group.appendChild(el('path', {
        d: pts.map((p, i) => `${i ? 'L' : 'M'} ${p[0].toFixed(1)} ${p[1].toFixed(1)}`).join(' '),
        class: 'rc-ink-lasso', fill: 'none', 'stroke-width': 1.5, 'stroke-dasharray': '4 4'
      }));
      return;
    }
    const b = box();
    if (!b) return;
    const midX = (b.minX + b.maxX) / 2, midY = (b.minY + b.maxY) / 2;
    group.appendChild(el('rect', {
      x: b.minX, y: b.minY, width: b.maxX - b.minX, height: b.maxY - b.minY,
      class: 'rc-ink-selbox', fill: 'none', 'stroke-width': 1, 'stroke-dasharray': '4 3'
    }));
    group.appendChild(el('line', { x1: midX, y1: b.minY, x2: midX, y2: b.minY - ROTATE_STEM, class: 'rc-ink-selstem', 'stroke-width': 1 }));
    group.appendChild(el('circle', { cx: midX, cy: b.minY - ROTATE_STEM, r: 6, class: 'rc-ink-handle rc-ink-handle-rotate' }));
    group.appendChild(el('circle', { cx: b.maxX, cy: midY, r: 6, class: 'rc-ink-handle rc-ink-handle-scale' }));
    for (const [x, y] of [[b.minX, b.minY], [b.maxX, b.minY], [b.minX, b.maxY], [b.maxX, b.maxY]]) {
      group.appendChild(el('circle', { cx: x, cy: y, r: 3.5, class: 'rc-ink-handle rc-ink-handle-corner' }));
    }
  }

  // ---- menu ----
  function button(label, fn, cls = '') {
    const b = doc.createElement('button');
    b.setAttribute('type', 'button');
    b.className = `rc-ink-selmenu-btn ${cls}`.trim();
    b.textContent = label;
    b.setAttribute('aria-label', label);
    b.addEventListener('click', e => { e?.preventDefault?.(); e?.stopPropagation?.(); fn(); });
    return b;
  }

  function placeAt(node, x, y) {
    const [cx, cy] = host.toClient(x, y);
    const vw = Number(globalObj?.innerWidth) || 1024;
    node.style.left = `${Math.max(8, Math.min(vw - 8, cx))}px`;
    node.style.top = `${Math.max(8, cy)}px`;
  }

  function hideMenu() { if (menu) { menu.remove?.(); menu = null; } }
  function hidePanel() { if (panel) { panel.remove?.(); panel = null; } }

  function showMenu(at = null) {
    hideMenu();
    if (!doc || typeof doc.createElement !== 'function') return;
    const b = box();
    menu = doc.createElement('div');
    menu.className = 'rc-ink-selmenu';
    menu.setAttribute('role', 'menu');
    menu.setAttribute('aria-label', 'Selection');
    if (b && !at) {
      menu.appendChild(button('Style', showPanel));
      menu.appendChild(button('Duplicate', duplicate));
      menu.appendChild(button('Cut', cut));
      menu.appendChild(button('Copy', copy));
      if (clipboard.length) menu.appendChild(button('Paste', () => paste()));
      menu.appendChild(button('Delete', del));
      menu.appendChild(button('›', showMore, 'rc-ink-selmenu-more'));
      placeAt(menu, (b.minX + b.maxX) / 2, b.minY - ROTATE_STEM - 16);
    } else if (at) {
      menu.appendChild(button('Paste', () => paste(at), clipboard.length ? '' : 'rc-disabled'));
      placeAt(menu, at[0], at[1] - 16);
    }
    (doc.body || svg?.parentNode)?.appendChild?.(menu);
  }

  function showMore() {
    if (!menu) return;
    menu.innerHTML = '';
    const sel = selected();
    const grouped = sel.length > 0 && sel.every(s => s.group && s.group === sel[0].group);
    menu.appendChild(button(grouped ? 'Ungroup' : 'Group', group_));
    menu.appendChild(button('Mirror Horizontally', () => mirror('h')));
    menu.appendChild(button('Mirror Vertically', () => mirror('v')));
  }

  // ---- actions ----
  function commit(list) { host.replace(list, true); draw(); }
  function duplicate() {
    const copies = duplicateStrokes(selected(), PASTE_OFFSET, PASTE_OFFSET);
    host.add(copies);
    ids = copies.map(s => s.id);
    draw(); showMenu();
  }
  function copy() { clipboard = selected().map(s => transformStroke(s, translate(0, 0))); hideMenu(); showMenu(); }
  function cut() { copy(); del(); }
  function del() {
    host.remove(ids);
    ids = [];
    hideMenu(); hidePanel(); draw();
  }
  function paste(at = null) {
    if (!clipboard.length) { hideMenu(); return; }
    let dx = PASTE_OFFSET, dy = PASTE_OFFSET;
    if (at) {
      const b = strokesBounds(clipboard);
      dx = at[0] - b.minX; dy = at[1] - b.minY;
    }
    const copies = duplicateStrokes(clipboard, dx, dy);
    host.add(copies);
    clipboard = copies.map(s => transformStroke(s, translate(0, 0)));   // the next paste cascades
    ids = copies.map(s => s.id);
    draw(); showMenu();
  }
  function group_() { commit(toggleGroup(selected(), `group-${newStrokeId()}`)); showMenu(); }
  function mirror(axis) {
    const b = box();
    if (!b) return;
    const m = axis === 'h' ? mirrorH((b.minX + b.maxX) / 2) : mirrorV((b.minY + b.maxY) / 2);
    commit(selected().map(s => transformStroke(s, m)));
    showMenu();
  }

  // ---- style panel (P12) ----
  function showPanel() {
    hideMenu(); hidePanel();
    if (!doc || typeof doc.createElement !== 'function') return;
    const sel = selected();
    if (!sel.length) return;
    panel = doc.createElement('div');
    panel.className = 'rc-ink-stylepanel';
    panel.setAttribute('role', 'dialog');
    panel.setAttribute('aria-label', 'Style');
    let tab = 'stroke';
    const apply = change => { commit(applyStyle(selected(), change)); };
    const fill = () => {
      panel.innerHTML = '';
      const tabs = doc.createElement('div');
      tabs.className = 'rc-ink-tabs';
      for (const t of ['stroke', 'fill']) {
        const b = button(t === 'stroke' ? 'Stroke' : 'Fill', () => { tab = t; fill(); }, tab === t ? 'rc-active' : '');
        b.setAttribute('aria-pressed', String(tab === t));
        tabs.appendChild(b);
      }
      panel.appendChild(tabs);
      if (tab === 'stroke') {
        const w = doc.createElement('input');
        w.setAttribute('type', 'range');
        w.setAttribute('min', '0.5'); w.setAttribute('max', '12'); w.setAttribute('step', '0.5');
        w.setAttribute('aria-label', 'Width');
        w.value = String(selected()[0]?.width || 2.5);
        w.className = 'rc-ink-width';
        w.addEventListener('input', () => apply({ width: Number(w.value) }));
        panel.appendChild(w);
        const styles = doc.createElement('div');
        styles.className = 'rc-ink-styles';
        for (const st of STROKE_STYLES) {
          styles.appendChild(button(st[0].toUpperCase() + st.slice(1), () => apply({ style: st }), `rc-ink-style-${st}`));
        }
        panel.appendChild(styles);
      }
      const sw = doc.createElement('div');
      sw.className = 'rc-ink-swatches';
      if (tab === 'fill') {
        const none = button('None', () => apply({ fill: null }), 'rc-ink-swatch-none');
        sw.appendChild(none);
      }
      for (const c of host.colors()) {
        const b = button('', () => apply(tab === 'stroke' ? { color: c } : { fill: c }), 'rc-ink-swatch');
        b.setAttribute('aria-label', c);
        b.style.background = c;
        sw.appendChild(b);
      }
      panel.appendChild(sw);
      if (tab === 'fill' && !selected().some(isClosedShape)) {
        const note = doc.createElement('div');
        note.className = 'rc-ink-note';
        note.textContent = 'Only closed shapes take a fill.';
        panel.appendChild(note);
      }
      panel.appendChild(button('Done', () => { hidePanel(); showMenu(); }, 'rc-ink-done'));
    };
    fill();
    const b = box();
    if (b) placeAt(panel, (b.minX + b.maxX) / 2, b.maxY + 12);
    (doc.body || svg?.parentNode)?.appendChild?.(panel);
  }

  // ---- pointer state machine (content coordinates) ----
  function stopPress() {
    if (press?.timer != null) (globalObj?.clearTimeout || clearTimeout)(press.timer);
    press = null;
  }

  function down(x, y) {
    hidePanel();
    const hit = selectionHit(box(), x, y);
    if (hit) {
      hideMenu();
      drag = { kind: hit, box: box(), x0: x, y0: y, originals: selected() };
      return;
    }
    clear();
    lasso = [[x, y]];
    const set = globalObj?.setTimeout || setTimeout;
    press = { x, y, timer: set(() => {
      // A long press on empty page (no lasso drawn): the Paste menu.
      if (!press) return;
      press = null;
      lasso = null;
      draw();
      host.haptic?.('snap');
      showMenu([x, y]);
    }, LONG_PRESS_MS) };
  }

  function move(x, y) {
    if (drag) {
      const m = dragMatrix(drag.kind, drag.box, drag.x0, drag.y0, x, y);
      host.replace(drag.originals.map(s => transformStroke(s, m)), false);
      draw();
      return;
    }
    if (lasso) {
      if (press && Math.hypot(x - press.x, y - press.y) > LONG_PRESS_SLOP) stopPress();
      lasso.push([x, y]);
      draw();
    }
  }

  function up(x, y) {
    if (drag) {
      const m = dragMatrix(drag.kind, drag.box, drag.x0, drag.y0, x, y);
      const moved = Math.hypot(x - drag.x0, y - drag.y0) > 1;
      if (moved) host.replace(drag.originals.map(s => transformStroke(s, m)), true);
      drag = null;
      draw();
      showMenu();
      return;
    }
    if (!lasso) return;   // the long press already opened its menu
    stopPress();
    lasso.push([x, y]);
    const pts = mode === 'boxed' ? [lasso[0], lasso[lasso.length - 1]] : lasso;
    ids = selectInLasso(host.strokes(), pts, mode);
    lasso = null;
    draw();
    if (ids.length) { host.haptic?.('snap'); showMenu(); }
  }

  function cancel() {
    if (drag) { host.replace(drag.originals, false); drag = null; }
    stopPress();
    lasso = null;
    draw();
  }

  function clear() {
    ids = [];
    lasso = null;
    stopPress();
    hideMenu(); hidePanel();
    draw();
  }

  return {
    down, move, up, cancel, clear, draw,
    select(list) { ids = [...list]; draw(); if (ids.length) showMenu(); },
    selectedIds: () => [...ids],
    mode: () => mode,
    setMode(m) {
      if (!LASSO_MODES.includes(m)) return;
      mode = m;
      try { globalObj?.localStorage?.setItem(MODE_KEY, m); } catch { /* none */ }
    },
    isBusy: () => Boolean(drag || lasso),
    isDragging: () => Boolean(drag),
    // Menu actions, also for keyboard and tests.
    duplicate, copy, cut, paste, del, mirror, group: group_, showPanel,
    menuElement: () => menu, panelElement: () => panel,
    contains(node) {
      for (let n = node; n; n = n.parentNode) if (n === menu || n === panel) return true;
      return false;
    }
  };
}
