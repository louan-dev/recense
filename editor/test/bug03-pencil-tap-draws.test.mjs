// Regression guard: BUG-03
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
    appendChild(child) { el.children.push(child); child.parentNode = el; return child; },
    removeChild(child) { el.children = el.children.filter(c => c !== child); child.parentNode = null; return child; },
    addEventListener(event, fn) {
      el._listeners = el._listeners || {};
      el._listeners[event] = el._listeners[event] || [];
      el._listeners[event].push(fn);
    }
  };
  return el;
}

function buildHarness() {
  const mockDoc = {
    createElementNS(ns, tag) { return createMockElement(tag); },
    createElement(tag) { return createMockElement(tag); }
  };
  const bubbleListeners = {};
  const scrollDOM = {
    style: {},
    scrollLeft: 0,
    scrollTop: 0,
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 800, height: 600 }),
    appendChild: child => scrollDOM.children.push(child),
    children: [],
    addEventListener(name, fn) {
      bubbleListeners[name] = bubbleListeners[name] || [];
      bubbleListeners[name].push(fn);
    },
    removeEventListener(name, fn) {
      if (bubbleListeners[name]) bubbleListeners[name] = bubbleListeners[name].filter(f => f !== fn);
    }
  };
  const fakeWindow = { document: mockDoc, webkit: { messageHandlers: {} } };
  const mockView = { scrollDOM, state: { doc: { toString: () => 'A line to tap on.' } } };
  const layer = createInkLayer(mockView, { globalObj: fakeWindow, debounceMs: 20, lineHeight: 28 });
  return { layer, bubbleListeners };
}

test('BUG-03: a zero-movement Pencil tap on a fresh page (no tool chosen yet) draws nothing', () => {
  const { layer, bubbleListeners } = buildHarness();
  assert.equal(layer.getInk().strokes.length, 0, 'starts with no ink');

  bubbleListeners.pointerdown.forEach(fn =>
    fn({ pointerType: 'pen', clientX: 50, clientY: 50, timeStamp: 1, preventDefault: () => {} })
  );
  bubbleListeners.pointerup.forEach(fn =>
    fn({ pointerType: 'pen', clientX: 50, clientY: 50, timeStamp: 2 })
  );

  assert.equal(layer.getInk().strokes.length, 0, 'a zero-movement tap on a fresh page must not draw');
});

test('BUG-03: the same fresh-page Pencil touch still draws once it moves past the tap threshold', () => {
  const { layer, bubbleListeners } = buildHarness();

  bubbleListeners.pointerdown.forEach(fn =>
    fn({ pointerType: 'pen', clientX: 50, clientY: 50, timeStamp: 1, preventDefault: () => {} })
  );
  bubbleListeners.pointermove.forEach(fn =>
    fn({ pointerType: 'pen', clientX: 70, clientY: 50, timeStamp: 2, preventDefault: () => {} })
  );
  bubbleListeners.pointerup.forEach(fn =>
    fn({ pointerType: 'pen', clientX: 70, clientY: 50, timeStamp: 3 })
  );

  assert.equal(layer.getInk().strokes.length, 1, 'a real drag past the threshold still draws');
});

test('BUG-03: once a tool is explicitly chosen, a zero-movement Pencil tap still draws (unchanged)', () => {
  const { layer, bubbleListeners } = buildHarness();
  layer.setTool('pen');

  bubbleListeners.pointerdown.forEach(fn =>
    fn({ pointerType: 'pen', clientX: 50, clientY: 50, timeStamp: 1, preventDefault: () => {} })
  );
  bubbleListeners.pointerup.forEach(fn =>
    fn({ pointerType: 'pen', clientX: 50, clientY: 50, timeStamp: 2 })
  );

  assert.equal(layer.getInk().strokes.length, 1, 'an explicitly chosen pen tool still draws a deliberate dot');
});
