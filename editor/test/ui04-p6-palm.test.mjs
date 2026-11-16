// Derived from Spec: UI-04 P6 — palm rejection for finger and trackpad.
import test from 'node:test';
import assert from 'node:assert/strict';

import { createPalmGate, isTinyStroke, isBrush, PALM_CONTACT_PX, REST_MS, PEN_GRACE_MS } from '../src/palm.js';
import { createInkLayer } from '../src/ink.js';

const T = (id, x, y, t, extra = {}) => ({ pointerType: 'touch', pointerId: id, clientX: x, clientY: y, timeStamp: t, width: 20, height: 20, ...extra });
const vp = () => ({ w: 800, h: 600 });

// ── the pure gate ─────────────────────────────────────────────────────────
test('P6 gate: a touch waits, then starts ink once it moves past the slop in time', () => {
  const g = createPalmGate({ viewport: vp });
  assert.equal(g.down(T(1, 100, 100, 1000)).act, 'wait');
  assert.equal(g.move(T(1, 102, 100, 1010)).act, 'wait', 'under 4 px is still probation');
  assert.equal(g.move(T(1, 110, 100, 1020)).act, 'start');
  assert.equal(g.move(T(1, 130, 100, 1030)).act, 'ink');
});

test('P6 gate: a touch resting past REST_MS before moving is a palm, ignored', () => {
  const g = createPalmGate({ viewport: vp });
  g.down(T(1, 100, 100, 1000));
  const r = g.move(T(1, 140, 100, 1000 + REST_MS + 1));
  assert.equal(r.act, 'ignore');
  assert.equal(g.move(T(1, 180, 100, 1000 + REST_MS + 20)).act, 'ignore');
});

test('P6 gate: a contact wider than the palm threshold is ignored', () => {
  const g = createPalmGate({ viewport: vp });
  assert.equal(g.down(T(1, 100, 100, 1000, { width: PALM_CONTACT_PX + 1 })).act, 'ignore');
  assert.equal(g.move(T(1, 150, 100, 1010)).act, 'ignore');
});

test('P6 gate: two fingers scroll by their centroid, and the first finger\'s stroke is dropped', () => {
  const g = createPalmGate({ viewport: vp });
  g.down(T(1, 100, 100, 1000));
  g.move(T(1, 110, 100, 1010));                     // first finger started inking
  const d = g.down(T(2, 200, 100, 1050));
  assert.equal(d.act, 'scroll');
  assert.equal(d.cancel, true, 'the young stroke is dropped');
  assert.deepEqual(g.move(T(1, 110, 80, 1060)), { act: 'scroll', dx: 0, dy: -10 });
  assert.deepEqual(g.move(T(2, 200, 80, 1060)), { act: 'scroll', dx: 0, dy: -10 });
});

test('P6 gate: a second touch landing mid-stroke (after 250 ms) is a palm, the stroke goes on', () => {
  const g = createPalmGate({ viewport: vp });
  g.down(T(1, 100, 100, 1000));
  g.move(T(1, 110, 100, 1010));
  assert.equal(g.down(T(2, 300, 300, 1400)).act, 'ignore');
  assert.equal(g.move(T(1, 150, 100, 1410)).act, 'ink');
});

test('P6 gate: a resting palm does not turn the next finger into a scroll', () => {
  const g = createPalmGate({ viewport: vp });
  g.down(T(1, 400, 400, 1000, { width: 80 }));     // palm
  assert.equal(g.down(T(2, 100, 100, 1100)).act, 'wait', 'the finger may still write');
});

test('P6 gate: mouse and pen go straight to ink', () => {
  const g = createPalmGate({ viewport: vp });
  assert.equal(g.down({ pointerType: 'mouse', clientX: 5, clientY: 5, timeStamp: 1 }).act, 'ink');
  assert.equal(g.down({ pointerType: 'pen', clientX: 5, clientY: 5, timeStamp: 1 }).act, 'ink');
});

test('P6 gate: a touch in the home-indicator band is left to iOS; the side margins still write', () => {
  assert.equal(createPalmGate({ viewport: vp }).down(T(3, 400, 590, 1000)).act, 'ignore', 'home indicator');
  assert.equal(createPalmGate({ viewport: vp }).down(T(1, 10, 300, 1000)).act, 'wait', 'left margin');
  assert.equal(createPalmGate({ viewport: vp }).down(T(2, 790, 300, 1000)).act, 'wait', 'right margin');
});

test('P6 gate: while the Pencil is down touches never ink; after it, one finger scrolls', () => {
  const g = createPalmGate({ viewport: vp });
  g.down({ pointerType: 'pen', clientX: 300, clientY: 300, timeStamp: 1000 });
  assert.equal(g.down(T(1, 100, 100, 1010)).act, 'ignore');
  g.up(T(1, 100, 100, 1020));
  g.up({ pointerType: 'pen', clientX: 300, clientY: 300, timeStamp: 1100 });
  assert.equal(g.down(T(2, 100, 100, 1200)).act, 'scroll', 'Pencil-only: a finger scrolls');
  assert.deepEqual(g.move(T(2, 100, 60, 1210)), { act: 'scroll', dx: 0, dy: -40 });
  g.up(T(2, 100, 60, 1220));
  assert.equal(g.down(T(3, 100, 100, 1100 + PEN_GRACE_MS + 1)).act, 'wait', 'Pencil put away: the finger writes again');
});

test('P6 gate: a Pencil landing while a finger inks drops the finger\'s stroke', () => {
  const g = createPalmGate({ viewport: vp });
  g.down(T(1, 100, 100, 1000));
  g.move(T(1, 120, 100, 1010));
  assert.equal(g.down({ pointerType: 'pen', clientX: 300, clientY: 300, timeStamp: 1020 }).cancel, true);
});

test('P6: tiny strokes and trackpad brushes', () => {
  assert.equal(isTinyStroke([[0, 0], [2, 0]]), true);
  assert.equal(isTinyStroke([[0, 0], [3, 0]]), false);
  assert.equal(isBrush([[0, 0, 0.5, 0], [6, 0, 0.5, 30]], 30), true, 'fast and small');
  assert.equal(isBrush([[0, 0, 0.5, 0], [6, 0, 0.5, 200]], 200), false, 'slow small mark is deliberate');
  assert.equal(isBrush([[0, 0, 0.5, 0], [40, 0, 0.5, 30]], 30), false, 'a fast long stroke is deliberate');
});

// ── wired into the ink layer ─────────────────────────────────────────────
function el(tag) {
  const e = {
    tag, attributes: {}, style: {}, children: [], hidden: false, innerHTML: '',
    setAttribute(k, v) { e.attributes[k] = String(v); },
    getAttribute(k) { return e.attributes[k]; },
    appendChild(c) { e.children.push(c); c.parentNode = e; return c; },
    removeChild(c) { e.children = e.children.filter(x => x !== c); return c; },
    addEventListener() {}
  };
  return e;
}
function harness() {
  const listeners = {};
  const scrollDOM = {
    style: {}, scrollLeft: 0, scrollTop: 500, children: [],
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 800, height: 600 }),
    appendChild: c => scrollDOM.children.push(c),
    addEventListener(name, fn, capture = false) {
      const key = name + (capture ? ':c' : '');
      (listeners[key] = listeners[key] || []).push(fn);
    },
    removeEventListener() {}
  };
  const doc = { createElementNS: (_, t) => el(t), createElement: t => el(t) };
  const layer = createInkLayer(
    { scrollDOM, state: { doc: { toString: () => 'one\ntwo' } } },
    { globalObj: { document: doc, innerWidth: 800, innerHeight: 600, webkit: { messageHandlers: { ink: { postMessage() {} } } } }, debounceMs: 20, lineHeight: 28, getPageIndex: () => 0 }
  );
  let prevented = 0;
  const fire = (name, e) => { for (const fn of listeners[name] || []) fn({ preventDefault() { prevented++; }, ...e }); };
  return { layer, scrollDOM, fire, listeners, prevented: () => prevented };
}

test('P6 ink: two fingers scroll the page and leave no ink while a pen is chosen', () => {
  const { layer, scrollDOM, fire } = harness();
  layer.setTool('pen');
  fire('pointerdown', T(1, 100, 100, 1000));
  fire('pointerdown', T(2, 200, 100, 1020));
  fire('pointermove', T(1, 100, 60, 1030));
  fire('pointermove', T(2, 200, 60, 1030));
  fire('pointerup', T(1, 100, 60, 1040));
  fire('pointerup', T(2, 200, 60, 1040));
  assert.equal(scrollDOM.scrollTop, 540, 'fingers moved up 40 px: the page scrolls down 40');
  assert.equal(layer.getInk().strokes.length, 0);
});

test('P6 ink: one finger drawn after a short rest still writes a stroke', () => {
  const { layer, scrollDOM, fire } = harness();
  layer.setTool('pen');
  fire('pointerdown', T(1, 100, 100, 1000));
  fire('pointermove', T(1, 120, 100, 1020));
  fire('pointermove', T(1, 160, 110, 1040));
  fire('pointerup', T(1, 160, 110, 1050));
  assert.equal(layer.getInk().strokes.length, 1);
  assert.equal(layer.getInk().strokes[0].points[0][0], 100, 'the stroke starts where the finger landed');
  assert.equal(scrollDOM.scrollTop, 500, 'one finger never scrolls');
});

test('P6 ink: a resting palm leaves no mark', () => {
  const { layer, fire } = harness();
  layer.setTool('pen');
  fire('pointerdown', T(1, 300, 300, 1000, { width: 90, height: 70 }));
  fire('pointermove', T(1, 330, 310, 1050, { width: 90, height: 70 }));
  fire('pointerup', T(1, 330, 310, 1100));
  assert.equal(layer.getInk().strokes.length, 0);
});

test('P6 ink: a finger tap under 3 px leaves no dot', () => {
  const { layer, fire } = harness();
  layer.setTool('pen');
  fire('pointerdown', T(1, 100, 100, 1000));
  fire('pointerup', T(1, 101, 100, 1080));
  assert.equal(layer.getInk().strokes.length, 0);
});

test('P6 ink (trackpad): with a pen chosen, a mouse drag inks and the page does not scroll', () => {
  const { layer, scrollDOM, fire, listeners, prevented } = harness();
  layer.setTool('pen');
  const M = (x, y, t) => ({ pointerType: 'mouse', pointerId: 1, clientX: x, clientY: y, timeStamp: t, buttons: 1 });
  fire('pointerdown', M(100, 100, 1000));
  fire('pointermove', M(160, 120, 1100));
  fire('pointerup', M(160, 120, 1150));
  assert.equal(layer.getInk().strokes.length, 1);
  assert.equal(scrollDOM.scrollTop, 500);
  assert.ok(prevented() >= 2, 'pointerdown and pointermove are prevented');
  // CodeMirror's own mousedown (text selection drag, which autoscrolls) never sees an inking press.
  const md = listeners['mousedown:c'] || [];
  assert.ok(md.length > 0, 'a capture mousedown guard exists');
  let stopped = false, mdPrevented = false;
  for (const fn of md) fn({ button: 0, stopPropagation() { stopped = true; }, preventDefault() { mdPrevented = true; } });
  assert.ok(stopped && mdPrevented, 'with a pen chosen, mousedown is stopped before CodeMirror');
});

test('P6 ink (trackpad): on Select the mousedown guard lets CodeMirror select text', () => {
  const { listeners } = harness();
  let stopped = false;
  for (const fn of listeners['mousedown:c'] || []) fn({ button: 0, stopPropagation() { stopped = true; }, preventDefault() {} });
  assert.equal(stopped, false);
});

test('P6 ink (trackpad): an accidental brush (fast, small) adds no mark', () => {
  const { layer, fire } = harness();
  layer.setTool('pen');
  const M = (x, y, t) => ({ pointerType: 'mouse', pointerId: 1, clientX: x, clientY: y, timeStamp: t });
  fire('pointerdown', M(100, 100, 1000));
  fire('pointermove', M(105, 101, 1020));
  fire('pointerup', M(105, 101, 1030));
  assert.equal(layer.getInk().strokes.length, 0);
});
