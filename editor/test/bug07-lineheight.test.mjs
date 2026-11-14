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

// 10 lines so a y-coordinate for "line 5" is always in range.
const DOC_TEXT = Array.from({ length: 10 }, (_, i) => `line ${i}`).join('\n');

function makeHarness(mockView) {
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

  mockView.scrollDOM = scrollDOM;
  mockView.state = { doc: { toString: () => DOC_TEXT } };

  const fakeWindow = {
    document: mockDoc,
    webkit: { messageHandlers: { ink: { postMessage() {} } } }
  };

  const layer = createInkLayer(mockView, {
    globalObj: fakeWindow,
    debounceMs: 20,
    getPageIndex: () => 0,
    ...(mockView.defaultLineHeight ? {} : { lineHeight: 28 })
  });
  layer.setTool('pen');

  function fire(name, e, capture = false) {
    const map = capture ? captureListeners : bubbleListeners;
    for (const fn of map[name] || []) fn(e);
  }

  function pointerEvent(extra) {
    return {
      pointerType: 'pen',
      clientX: 10,
      clientY: 10,
      pressure: 1,
      timeStamp: Date.now(),
      preventDefault() {},
      ...extra
    };
  }

  // Draws a short horizontal stroke whose top-left y is exactly `y` (the raw pointer coordinate
  // anchorStrokeToDoc converts to a line index via Math.floor(y / lineHeight)).
  function drawAt(y) {
    fire('pointerdown', pointerEvent({ clientY: y }));
    fire('pointermove', pointerEvent({ clientX: 40, clientY: y }));
    fire('pointerup', pointerEvent({ clientX: 40, clientY: y }));
  }

  return { layer, drawAt };
}

test('BUG-07: a live view anchors a stroke to the real line, not floor(y / 28)', () => {
  const mockView = { defaultLineHeight: 40 };
  const { layer, drawAt } = makeHarness(mockView);

  drawAt(5 * 40 + 4);   // physically on line 5 at a real 40px line height

  const strokes = layer.getInk().strokes;
  assert.equal(strokes.length, 1);
  assert.equal(
    strokes[0].anchor.offsetInPage,
    5,
    `line 5 at 40px line height must anchor to line 5, not floor(${5 * 40 + 4} / 28) = ${Math.floor((5 * 40 + 4) / 28)}`
  );
});

test('BUG-07: the line height is read live, not cached from layer creation', () => {
  const mockView = { defaultLineHeight: 40 };
  const { layer, drawAt } = makeHarness(mockView);

  drawAt(5 * 40 + 4);
  assert.equal(layer.getInk().strokes[0].anchor.offsetInPage, 5);

  // The owner changed text size after the layer was created; the real line height is now 24px.
  mockView.defaultLineHeight = 24;
  drawAt(5 * 24 + 4);

  const strokes = layer.getInk().strokes;
  assert.equal(strokes.length, 2);
  assert.equal(
    strokes[1].anchor.offsetInPage,
    5,
    'a stroke drawn after a font-size change must anchor using the new live line height, not one captured at creation'
  );
});

test('BUG-07: no defaultLineHeight on the view (today\'s mock shape) keeps the explicit lineHeight option', () => {
  const mockView = {};
  const { layer, drawAt } = makeHarness(mockView);

  drawAt(5 * 28 + 4);

  assert.equal(layer.getInk().strokes[0].anchor.offsetInPage, 5, 'unchanged behaviour when the view has no defaultLineHeight');
});
