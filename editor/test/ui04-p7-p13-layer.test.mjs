// Derived from Spec: UI-04 P7–P11 — through the ink layer's own pointer handlers: shape-snap haptic with a point,
// corner handles, hold-to-fill, Lasso select + move + menu actions, and the Lasso button/modes.
// Regression guard: UI-04
import test from 'node:test';
import assert from 'node:assert/strict';

import { createInkLayer, PALETTE_TOOLS } from '../src/ink.js';
import { polygonCorners } from '../src/inkshapes.js';

function el(tag) {
  const e = {
    tag, attributes: {}, style: {}, children: [], hidden: false, innerHTML: '', parentNode: null, _listeners: {},
    setAttribute(k, v) { e.attributes[k] = String(v); },
    getAttribute(k) { return e.attributes[k]; },
    appendChild(c) { e.children.push(c); c.parentNode = e; return c; },
    removeChild(c) { e.children = e.children.filter(x => x !== c); c.parentNode = null; return c; },
    remove() { if (e.parentNode) e.parentNode.removeChild(e); },
    addEventListener(n, fn) { (e._listeners[n] = e._listeners[n] || []).push(fn); }
  };
  return e;
}

function harness() {
  const body = el('body');
  const doc = { createElementNS: (_, t) => el(t), createElement: t => el(t), body };
  const listeners = {};
  const scrollDOM = {
    style: {}, scrollLeft: 0, scrollTop: 0, children: [],
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 800, height: 600 }),
    appendChild(c) { scrollDOM.children.push(c); c.parentNode = scrollDOM; return c; },
    addEventListener(n, fn, cap = false) { if (!cap) (listeners[n] = listeners[n] || []).push(fn); },
    removeEventListener() {}
  };
  const timers = [];
  const haptics = [];
  const win = {
    document: doc,
    innerWidth: 800, innerHeight: 600,
    setTimeout: (fn, ms) => { timers.push({ fn, ms }); return timers.length; },
    clearTimeout: id => { if (timers[id - 1]) timers[id - 1].fn = null; },
    webkit: { messageHandlers: { ui: { postMessage: m => { if (m.haptic) haptics.push(m); } } } }
  };
  const view = { scrollDOM, state: { doc: { toString: () => 'line one\nline two\nline three' } } };
  const layer = createInkLayer(view, { globalObj: win, debounceMs: 5, lineHeight: 28 });
  const fire = (name, ev) => (listeners[name] || []).forEach(fn => fn({ pointerId: 1, pointerType: 'pen', pressure: 0.5, preventDefault() {}, ...ev }));
  const runTimers = () => { const due = timers.splice(0); for (const t of due) if (t.fn) t.fn(); };
  return { layer, fire, runTimers, haptics, body, doc };
}

// Draws a stroke through pts ([x, y]) and holds the last point for holdMs before lifting.
function draw(h, pts, holdMs = 0) {
  let t = 1000;
  h.fire('pointerdown', { clientX: pts[0][0], clientY: pts[0][1], timeStamp: t });
  for (const [x, y] of pts.slice(1)) h.fire('pointermove', { clientX: x, clientY: y, timeStamp: (t += 10) });
  const [lx, ly] = pts[pts.length - 1];
  if (holdMs) h.fire('pointermove', { clientX: lx, clientY: ly, timeStamp: (t += holdMs) });
  h.fire('pointerup', { clientX: lx, clientY: ly, timeStamp: t + 1 });
}

function triangleLoop() {
  const c = [[100, 220], [160, 110], [220, 220]];
  const pts = [];
  for (let i = 0; i < 3; i++) {
    const a = c[i], b = c[(i + 1) % 3];
    for (let k = 0; k < 10; k++) pts.push([a[0] + ((b[0] - a[0]) * k) / 10, a[1] + ((b[1] - a[1]) * k) / 10]);
  }
  pts.push([101, 221]);
  return pts;
}

test('UI-04 P9: the palette has a Lasso button between Highlighter and Eraser', () => {
  assert.deepEqual(PALETTE_TOOLS, ['select', 'pen', 'highlighter', 'lasso', 'eraser-whole']);
  const h = harness();
  h.layer.setTool('lasso');
  assert.equal(h.layer.getTool(), 'lasso');
  const modes = h.layer.dock.children.find(c => c.attributes['aria-label'] === 'Lasso mode');
  assert.equal(modes.hidden, false, 'Freeform | Boxed shows while the Lasso is picked');
  h.layer.setTool('pen');
  assert.equal(modes.hidden, true);
});

test('UI-04 P7 + P3: a held triangle snaps, posts shapeSnap with the lift point, and gets corner handles', () => {
  const h = harness();
  h.layer.setTool('pen');
  draw(h, triangleLoop(), 600);
  const st = h.layer.getInk().strokes[0];
  assert.equal(st.shape.kind, 'polygon');
  assert.equal(st.shape.name, 'triangle');
  const snap = h.haptics.find(m => m.haptic === 'shapeSnap');
  assert.deepEqual(snap, { haptic: 'shapeSnap', x: 101, y: 221 });
  assert.equal(h.layer.handlesFor(), st.id);

  // Drag the apex handle up by 30.
  const apex = polygonCorners(st).reduce((a, b) => (b[1] < a[1] ? b : a));
  h.fire('pointerdown', { clientX: apex[0], clientY: apex[1], timeStamp: 5000 });
  h.fire('pointermove', { clientX: apex[0], clientY: apex[1] - 30, timeStamp: 5010 });
  h.fire('pointerup', { clientX: apex[0], clientY: apex[1] - 30, timeStamp: 5020 });
  const after = h.layer.getInk().strokes;
  assert.equal(after.length, 1, 'dragging a handle draws nothing');
  const moved = polygonCorners(after[0]).reduce((a, b) => (b[1] < a[1] ? b : a));
  assert.ok(Math.abs(moved[1] - (apex[1] - 30)) < 1e-6);
  assert.equal(typeof after[0].edited, 'number');

  // A stroke elsewhere puts the handles away.
  draw(h, [[400, 400], [430, 405]]);
  assert.equal(h.layer.handlesFor(), null);
});

test('UI-04 P8: holding the pen still inside a closed shape fills it and leaves no dot', () => {
  const h = harness();
  h.layer.setTool('pen');
  draw(h, triangleLoop(), 600);
  const id = h.layer.getInk().strokes[0].id;
  h.fire('pointerdown', { clientX: 160, clientY: 190, timeStamp: 9000 });
  h.runTimers();   // SNAP_HOLD_MS still
  h.fire('pointerup', { clientX: 160, clientY: 190, timeStamp: 9600 });
  const ink = h.layer.getInk().strokes;
  assert.equal(ink.length, 1, 'no dot');
  assert.equal(ink[0].id, id);
  assert.equal(ink[0].fill, h.layer.getColor());

  // The same hold outside any shape leaves the dot as before.
  h.fire('pointerdown', { clientX: 600, clientY: 500, timeStamp: 10000 });
  h.runTimers();
  h.fire('pointerup', { clientX: 600, clientY: 500, timeStamp: 10600 });
  assert.equal(h.layer.getInk().strokes.length, 2);
});

test('UI-04 P9–P11: lasso selects, a drag inside the box moves, the menu duplicates and deletes', () => {
  const h = harness();
  h.layer.setTool('pen');
  draw(h, [[100, 100], [140, 110], [180, 100]]);
  draw(h, [[500, 500], [540, 510]]);
  h.layer.setTool('lasso');
  draw(h, [[80, 80], [200, 80], [200, 130], [80, 130], [80, 80]]);
  const sel = h.layer.selection();
  const [first, second] = h.layer.getInk().strokes;
  assert.deepEqual(sel.selectedIds(), [first.id]);
  const menu = sel.menuElement();
  assert.ok(menu, 'menu shows');
  assert.deepEqual(menu.children.map(b => b.textContent), ['Style', 'Duplicate', 'Cut', 'Copy', 'Delete', '›']);

  // Move by (+50, +20).
  draw(h, [[140, 105], [165, 115], [190, 125]]);
  const moved = h.layer.getInk().strokes.find(s => s.id === first.id);
  assert.deepEqual(moved.points[0].slice(0, 2), [150, 120]);
  assert.equal(typeof moved.edited, 'number');

  sel.duplicate();
  assert.equal(h.layer.getInk().strokes.length, 3);
  sel.del();
  const left = h.layer.getInk();
  assert.equal(left.strokes.length, 2, 'the duplicate was deleted');
  assert.ok(left.removed.length === 1);
  assert.ok(left.strokes.some(s => s.id === second.id));
});

test('UI-04 P10: Boxed lasso, then mirror horizontally about the box centre', () => {
  const h = harness();
  h.layer.setTool('pen');
  draw(h, [[100, 100], [140, 100], [180, 140]]);
  h.layer.setTool('lasso');
  h.layer.selection().setMode('boxed');
  draw(h, [[90, 90], [150, 120], [190, 150]]);
  const sel = h.layer.selection();
  assert.equal(sel.selectedIds().length, 1);
  sel.mirror('h');
  const xs = h.layer.getInk().strokes[0].points.map(p => p[0]);
  assert.deepEqual([xs[0], xs[xs.length - 1]].map(Math.round), [180, 100]);
});

test('UI-04 P13: a loupe shows while the Pencil drags a corner handle, and goes on lift; never for the mouse', () => {
  const h = harness();
  h.layer.setTool('pen');
  draw(h, triangleLoop(), 600);
  const c = polygonCorners(h.layer.getInk().strokes[0])[0];
  h.fire('pointerdown', { clientX: c[0], clientY: c[1], timeStamp: 5000 });
  h.fire('pointermove', { clientX: c[0] + 10, clientY: c[1], timeStamp: 5010 });
  const loupe = h.body.children.find(x => x.className === 'rc-ink-loupe');
  assert.ok(loupe && loupe.hidden === false, 'loupe up while dragging');
  h.fire('pointerup', { clientX: c[0] + 10, clientY: c[1], timeStamp: 5020 });
  assert.equal(loupe.hidden, true);

  const m = harness();
  m.layer.setTool('pen');
  draw(m, triangleLoop(), 600);
  const d = polygonCorners(m.layer.getInk().strokes[0])[0];
  m.fire('pointerdown', { pointerType: 'mouse', clientX: d[0], clientY: d[1], timeStamp: 5000 });
  m.fire('pointermove', { pointerType: 'mouse', clientX: d[0] + 10, clientY: d[1], timeStamp: 5010 });
  assert.equal(m.body.children.some(x => x.className === 'rc-ink-loupe'), false);
});
