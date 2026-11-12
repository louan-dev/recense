import test from 'node:test';
import assert from 'node:assert/strict';

import { createInkLayer } from '../src/ink.js';

function createMockElement(tag) {
  const el = {
    tag,
    attributes: {},
    style: {},
    children: [],
    hidden: false,
    innerHTML: '',
    setAttribute(k, v) { el.attributes[k] = String(v); },
    getAttribute(k) { return el.attributes[k]; },
    appendChild(child) {
      el.children.push(child);
      child.parentNode = el;
      return child;
    },
    removeChild(child) {
      el.children = el.children.filter(c => c !== child);
      child.parentNode = null;
      return child;
    },
    addEventListener(event, fn) {
      el._listeners = el._listeners || {};
      el._listeners[event] = el._listeners[event] || [];
      el._listeners[event].push(fn);
    }
  };
  return el;
}

function makeHarness() {
  const mockDoc = {
    createElementNS(ns, tag) { return createMockElement(tag); },
    createElement(tag) { return createMockElement(tag); }
  };

  const bubbleListeners = {};
  const captureListeners = {};
  const scrollDOM = {
    style: {},
    scrollLeft: 0,
    scrollTop: 0,
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 800, height: 600 }),
    appendChild: child => scrollDOM.children.push(child),
    children: [],
    addEventListener(name, fn, useCapture = false) {
      const map = useCapture ? captureListeners : bubbleListeners;
      map[name] = map[name] || [];
      map[name].push(fn);
    },
    removeEventListener(name, fn, useCapture = false) {
      const map = useCapture ? captureListeners : bubbleListeners;
      if (map[name]) map[name] = map[name].filter(f => f !== fn);
    }
  };

  const fakeWindow = {
    document: mockDoc,
    webkit: { messageHandlers: { ink: { postMessage() {} } } }
  };

  const mockView = {
    scrollDOM,
    state: { doc: { toString: () => 'line one\nline two\nline three' } }
  };

  const layer = createInkLayer(mockView, {
    globalObj: fakeWindow,
    debounceMs: 20,
    lineHeight: 28,
    getPageIndex: () => 0
  });

  function fire(name, e, capture = false) {
    const map = capture ? captureListeners : bubbleListeners;
    for (const fn of map[name] || []) fn(e);
  }

  function pointerEvent(extra) {
    return {
      pointerType: 'touch',
      clientX: 10,
      clientY: 10,
      pressure: 1,
      timeStamp: Date.now(),
      preventDefault() {},
      ...extra
    };
  }

  function drag(pointerType, { from = [10, 10], to = [60, 10] } = {}) {
    fire('pointerdown', pointerEvent({ pointerType, clientX: from[0], clientY: from[1] }));
    fire('pointermove', pointerEvent({ pointerType, clientX: to[0], clientY: to[1] }));
    fire('pointerup', pointerEvent({ pointerType, clientX: to[0], clientY: to[1] }));
  }

  return { layer, fire, pointerEvent, drag };
}

test('BUG-04: no tool picked, a touch drag still does nothing (G2 unchanged)', () => {
  const { layer, drag } = makeHarness();
  drag('touch');
  assert.equal(layer.getInk().strokes.length, 0);
});

test('BUG-04: tool picked, a touch drag draws a stroke (G1, G4)', () => {
  const { layer, drag } = makeHarness();
  layer.setTool('pen');
  drag('touch');
  assert.equal(layer.getInk().strokes.length, 1, 'a touch stroke must be committed once a tool is active');
  assert.equal(layer.getInk().strokes[0].tool, 'pen');
});

test('BUG-04: eraser tool picked, a touch drag over a stroke erases it (G1 covers erase)', () => {
  const { layer, drag } = makeHarness();
  layer.setTool('pen');
  drag('touch', { from: [10, 10], to: [60, 10] });
  assert.equal(layer.getInk().strokes.length, 1);

  layer.setTool('eraser-whole');
  drag('touch', { from: [10, 10], to: [60, 10] });
  assert.equal(layer.getInk().strokes.length, 0, 'the eraser must remove the stroke under a touch drag');
});

test('BUG-04: untouched palette, a stray touch tap does not auto-pick a tool (G3 is pen-only)', () => {
  const { layer, fire, pointerEvent } = makeHarness();
  fire('pointerdown', pointerEvent({ pointerType: 'touch' }));
  fire('pointerup', pointerEvent({ pointerType: 'touch' }));
  assert.equal(layer.getTool(), 'select', 'a bare finger tap must never switch the tool away from select');
  assert.equal(layer.getInk().strokes.length, 0);
});
