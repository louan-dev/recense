// Regression guard: BUG-21 (T-0131) — with a pen chosen, a finger drag inks instead of scrolling the page.
import test from 'node:test';
import assert from 'node:assert/strict';

import { createInkLayer } from '../src/ink.js';

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
    style: {}, scrollLeft: 0, scrollTop: 0, children: [],
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
    { globalObj: { document: doc, webkit: { messageHandlers: { ink: { postMessage() {} } } } }, debounceMs: 20, lineHeight: 28, getPageIndex: () => 0 }
  );
  const fire = (name, e) => { for (const fn of listeners[name] || []) fn(e); };
  const ev = extra => ({ pointerType: 'touch', pointerId: 1, clientX: 10, clientY: 10, pressure: 0, timeStamp: Date.now(), preventDefault() {}, ...extra });
  return { layer, scrollDOM, fire, ev };
}

test('BUG-21: choosing a pen turns off touch panning on the scroller', () => {
  const { layer, scrollDOM } = harness();
  layer.setTool('pen');
  assert.equal(scrollDOM.style.touchAction, 'none', 'WebKit only honours touch-action set before the gesture starts');
});

test('BUG-21: the eraser also turns off touch panning', () => {
  const { layer, scrollDOM } = harness();
  layer.setTool('eraser-whole');
  assert.equal(scrollDOM.style.touchAction, 'none');
});

test('BUG-21: back to select, the finger scrolls again', () => {
  const { layer, scrollDOM } = harness();
  layer.setTool('pen');
  layer.setTool('select');
  assert.equal(scrollDOM.style.touchAction, '');
});

test('BUG-21: before any tool is chosen, touch panning is left alone', () => {
  const { scrollDOM } = harness();
  assert.notEqual(scrollDOM.style.touchAction, 'none');
});

test('BUG-21: a Pencil touch that auto-picks the pen also turns off panning', () => {
  const { scrollDOM, fire, ev } = harness();
  fire('pointerdown:c', ev({ pointerType: 'pen', pressure: 0.5 }));
  assert.equal(scrollDOM.style.touchAction, 'none');
});
