import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  formatDotIndicator,
  detectHapticZone,
  attachHapticZones,
  executeVoiceMove,
  HAPTIC_ZONES
} from '../src/gestures.js';
import {
  formatPageIndicator,
  mountEditor
} from '../src/index.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Helper for minimal mock DOM environment to test mountEditor
function setupMockDom() {
  class FakeObserver {
    observe() {}
    disconnect() {}
    takeRecords() {
      return [];
    }
  }

  class FakeWindow {
    constructor() {
      this.addEventListener = () => {};
      this.removeEventListener = () => {};
      this.getSelection = () => ({
        anchorNode: null,
        anchorOffset: 0,
        focusNode: null,
        focusOffset: 0,
        rangeCount: 0,
        getRangeAt: () => null
      });
      this.getComputedStyle = () => ({
        lineHeight: '20px',
        fontSize: '18px',
        direction: 'ltr'
      });
      this.requestAnimationFrame = fn => setTimeout(fn, 0);
      this.cancelAnimationFrame = id => clearTimeout(id);
      this.MutationObserver = FakeObserver;
      this.webkit = {
        messageHandlers: {
          editor: { postMessage() {} },
          ui: { postMessage() {} },
          audio: { postMessage() {} }
        }
      };
    }
  }

  global.Window = FakeWindow;
  global.Node = class {};
  global.HTMLElement = class {};

  const win = new FakeWindow();
  const doc = {
    nodeType: 9,
    defaultView: win,
    addEventListener() {},
    removeEventListener() {},
    getSelection: win.getSelection,
    hasFocus: () => false,
    createElement(tag) {
      return makeEl(tag);
    },
    createElementNS(ns, tag) {
      return makeEl(tag);
    },
    createTextNode(text) {
      return { nodeType: 3, nodeValue: text, ownerDocument: doc };
    },
    getElementById: () => null,
    head: null,
    body: null,
    documentElement: null,
    createRange: () => ({
      setStart() {},
      setEnd() {},
      getBoundingClientRect() {
        return { left: 0, top: 0, width: 100, height: 20 };
      },
      getClientRects() {
        return [];
      }
    })
  };
  win.document = doc;

  function makeEl(tag = 'div') {
    const listeners = {};
    const attrs = [];
    const el = {
      nodeType: 1,
      nodeName: tag.toUpperCase(),
      tagName: tag.toUpperCase(),
      style: {
        setProperty() {}
      },
      attributes: attrs,
      classList: {
        set: new Set(),
        add(c) {
          this.set.add(c);
        },
        remove(c) {
          this.set.delete(c);
        },
        contains(c) {
          return this.set.has(c);
        }
      },
      childNodes: [],
      children: [],
      ownerDocument: doc,
      firstChild: null,
      appendChild(c) {
        el.childNodes.push(c);
        el.children.push(c);
        c.parentNode = el;
        el.firstChild = el.childNodes[0];
        return c;
      },
      insertBefore(c, ref) {
        el.childNodes.push(c);
        el.children.push(c);
        c.parentNode = el;
        el.firstChild = el.childNodes[0];
        return c;
      },
      removeChild(c) {
        el.childNodes = el.childNodes.filter(x => x !== c);
        el.children = el.children.filter(x => x !== c);
        el.firstChild = el.childNodes[0] || null;
        return c;
      },
      setAttribute(k, v) {
        el[k] = v;
        attrs.push({ name: k, value: String(v) });
      },
      getAttribute(k) {
        return el[k] || null;
      },
      removeAttribute(k) {
        const idx = attrs.findIndex(a => a.name === k);
        if (idx >= 0) attrs.splice(idx, 1);
        delete el[k];
      },
      append(...args) {
        args.forEach(a => el.appendChild(a));
      },
      addEventListener(k, fn) {
        (listeners[k] = listeners[k] || []).push(fn);
      },
      removeEventListener(k, fn) {
        if (listeners[k]) listeners[k] = listeners[k].filter(f => f !== fn);
      },
      focus() {},
      select() {},
      contains() {
        return false;
      },
      getBoundingClientRect() {
        return { left: 0, top: 0, width: 800, height: 600 };
      },
      getClientRects() {
        return [];
      },
      listeners
    };
    return el;
  }

  doc.head = makeEl('head');
  doc.body = makeEl('body');
  doc.documentElement = makeEl('html');
  global.window = win;
  global.document = doc;
  global.MutationObserver = FakeObserver;

  return { win, doc, makeEl };
}

test('Zero-chrome resting state: toolbar starts faded, formatDotIndicator has zero letters/digits', () => {
  // 1. formatDotIndicator produces pure dots and spaces with zero letters or digits
  assert.equal(formatDotIndicator(0, 1), '●');
  assert.equal(formatDotIndicator(0, 3), '● ○ ○');
  assert.equal(formatDotIndicator(1, 3), '○ ● ○');
  assert.equal(formatDotIndicator(2, 3), '○ ○ ●');
  assert.equal(formatDotIndicator(0, 8), '● ○ ○ ○ ○ ○ ○ ○');

  const multiDot = formatDotIndicator(5, 12);
  assert.ok(multiDot.includes('●'));
  assert.ok(multiDot.includes('○'));
  assert.equal(/[a-zA-Z0-9]/.test(multiDot), false, 'Must contain no letters or digits');

  const largeDot = formatDotIndicator(0, 100);
  assert.equal(/[a-zA-Z0-9]/.test(largeDot), false, 'Large indicator must have no words or digits');

  // Backwards compatibility check
  assert.equal(formatPageIndicator(0, 3), 'Page 1 of 3');

  // 2. mountEditor zero-chrome resting state
  const { makeEl } = setupMockDom();
  const root = makeEl('div');
  const mounted = mountEditor(root, 'Topic 1\n<!-- page -->\nTopic 2');

  assert.equal(mounted.isToolbarFaded(), true, 'Toolbar must start faded at boot for zero chrome');
  assert.ok(mounted.bridge, 'Bridge API exposed');
  assert.ok(typeof mounted.voiceCommand === 'function', 'voiceCommand exposed on return');
  assert.ok(typeof mounted.bridge.voiceCommand === 'function', 'voiceCommand exposed on bridge');
});

test('Hand-neutral symmetric left/right/top haptic zones: detection and haptic dwell disclosure', async () => {
  assert.equal(HAPTIC_ZONES.top, 44);
  assert.equal(HAPTIC_ZONES.edge, 32);
  assert.equal(HAPTIC_ZONES.dwellMs, 280);

  // 1. detectHapticZone detection
  assert.equal(detectHapticZone(15, 200, 800, 600), 'left');
  assert.equal(detectHapticZone(785, 200, 800, 600), 'right');
  assert.equal(detectHapticZone(400, 20, 800, 600), 'top');
  assert.equal(detectHapticZone(400, 300, 800, 600), null);
  assert.equal(detectHapticZone(-5, 200, 800, 600), null);
  assert.equal(detectHapticZone(400, 650, 800, 600), null);

  // Symmetry: exact 32px reach targets for left- and right-handed users
  assert.equal(detectHapticZone(32, 200, 800, 600), 'left');
  assert.equal(detectHapticZone(33, 200, 800, 600), null);
  assert.equal(detectHapticZone(800 - 32, 200, 800, 600), 'right');
  assert.equal(detectHapticZone(800 - 33, 200, 800, 600), null);

  // 2. attachHapticZones firing haptic snap and dwell disclosure
  const listeners = {};
  const activeClasses = new Set();
  const container = {
    clientWidth: 800,
    clientHeight: 600,
    classList: {
      add(c) {
        activeClasses.add(c);
      },
      remove(c) {
        activeClasses.delete(c);
      },
      contains(c) {
        return activeClasses.has(c);
      }
    },
    addEventListener(type, fn) {
      listeners[type] = listeners[type] || [];
      listeners[type].push(fn);
    },
    removeEventListener(type, fn) {
      if (listeners[type]) listeners[type] = listeners[type].filter(f => f !== fn);
    }
  };

  const hapticsPosted = [];
  const fakeGlobal = {
    webkit: {
      messageHandlers: {
        ui: {
          postMessage(msg) {
            hapticsPosted.push(msg);
          }
        }
      }
    }
  };

  const entered = [];
  const dwelled = [];
  const left = [];

  const unbind = attachHapticZones(container, {
    onZoneEnter(z) {
      entered.push(z);
    },
    onZoneDwell(z) {
      dwelled.push(z);
    },
    onZoneLeave(z) {
      left.push(z);
    },
    zones: { top: 44, edge: 32, dwellMs: 40 }, // shorter dwellMs for fast test
    globalObj: fakeGlobal
  });

  function fire(type, clientX, clientY) {
    const list = listeners[type] || [];
    for (const fn of list) {
      fn({ clientX, clientY });
    }
  }

  // Pointer enters left zone
  fire('pointermove', 10, 200);
  assert.deepEqual(entered, ['left']);
  assert.deepEqual(hapticsPosted, [{ haptic: 'snap' }]);
  assert.ok(activeClasses.has('rc-zone-active-left'));

  // Wait for dwell (40ms)
  await new Promise(r => setTimeout(r, 60));
  assert.deepEqual(dwelled, ['left'], 'Dwelling in left zone triggers onZoneDwell');

  // Move pointer into neutral canvas center
  fire('pointermove', 400, 300);
  assert.deepEqual(left, ['left']);
  assert.equal(activeClasses.has('rc-zone-active-left'), false);

  // Pointer enters right zone
  fire('pointermove', 790, 200);
  assert.equal(entered[1], 'right');
  assert.equal(hapticsPosted.length, 2);
  assert.equal(hapticsPosted[1].haptic, 'snap');
  assert.ok(activeClasses.has('rc-zone-active-right'));

  // Drag cancel test: moving pointer before dwell completes cancels dwell
  fire('pointermove', 770, 250); // moved > 10px
  await new Promise(r => setTimeout(r, 60));
  assert.equal(dwelled.length, 1, 'Drag must cancel dwell trigger');

  unbind();
});

test('Touch, Pencil, and Voice parity: executeVoiceMove and voiceCommand dispatching', () => {
  const actionsRun = [];
  let currentInk = null;

  const handlers = {
    swipeLeftToRight() {
      actionsRun.push('swipeLeftToRight');
    },
    swipeRightToLeft() {
      actionsRun.push('swipeRightToLeft');
    },
    deleteEmptyWindow() {
      actionsRun.push('deleteEmptyWindow');
    },
    toggleOutline() {
      actionsRun.push('toggleOutline');
    },
    openFind() {
      actionsRun.push('openFind');
    },
    setInkTool(tool) {
      currentInk = tool;
      actionsRun.push(`setInkTool:${tool}`);
    },
    summarizeSection() {
      actionsRun.push('summarizeSection');
    },
    bookmarkAudio() {
      actionsRun.push('bookmarkAudio');
    }
  };

  // 1. Swipe left-to-right (New window / topic) in English, French, Vietnamese
  const r1 = executeVoiceMove('new topic', handlers);
  assert.equal(r1.matched, true);
  assert.equal(r1.action, 'swipeLeftToRight');

  executeVoiceMove('new window', handlers);
  executeVoiceMove('new page', handlers);
  executeVoiceMove('swipe right', handlers);
  executeVoiceMove('left', handlers);
  executeVoiceMove('nouveau', handlers);
  executeVoiceMove('mới', handlers);
  assert.equal(actionsRun.filter(a => a === 'swipeLeftToRight').length, 7);

  // 2. Swipe right-to-left (Next / older window)
  const r2 = executeVoiceMove('next topic', handlers);
  assert.equal(r2.matched, true);
  assert.equal(r2.action, 'swipeRightToLeft');

  executeVoiceMove('older', handlers);
  executeVoiceMove('swipe left', handlers);
  executeVoiceMove('right', handlers);
  executeVoiceMove('suivant', handlers);
  executeVoiceMove('tiếp', handlers);
  assert.equal(actionsRun.filter(a => a === 'swipeRightToLeft').length, 6);

  // 3. Delete window
  const r3 = executeVoiceMove('delete window', handlers);
  assert.equal(r3.matched, true);
  assert.equal(r3.action, 'deleteEmptyWindow');

  executeVoiceMove('remove empty', handlers);
  executeVoiceMove('supprimer', handlers);
  executeVoiceMove('xóa', handlers);
  assert.equal(actionsRun.filter(a => a === 'deleteEmptyWindow').length, 4);

  // 4. Outline
  const r4 = executeVoiceMove('outline', handlers);
  assert.equal(r4.matched, true);
  assert.equal(r4.action, 'toggleOutline');

  executeVoiceMove('topics', handlers);
  assert.equal(actionsRun.filter(a => a === 'toggleOutline').length, 2);

  // 5. Find
  const r5 = executeVoiceMove('find', handlers);
  assert.equal(r5.matched, true);
  assert.equal(r5.action, 'openFind');

  executeVoiceMove('search', handlers);
  assert.equal(actionsRun.filter(a => a === 'openFind').length, 2);

  // 6. Ink tools
  const tools = [
    'pen',
    'highlighter',
    'underline',
    'circle',
    'eraser',
    'whole eraser',
    'partial eraser'
  ];
  for (const tool of tools) {
    const res = executeVoiceMove(tool, handlers);
    assert.equal(res.matched, true);
    assert.equal(res.action, 'setInkTool');
    assert.equal(res.tool, tool);
    assert.equal(currentInk, tool);
  }

  // 7. Audio summary & bookmark
  const r7 = executeVoiceMove('audio summary', handlers);
  assert.equal(r7.matched, true);
  assert.equal(r7.action, 'summarizeSection');

  executeVoiceMove('summarize', handlers);
  executeVoiceMove('summary', handlers);
  assert.equal(actionsRun.filter(a => a === 'summarizeSection').length, 3);

  const r8 = executeVoiceMove('bookmark', handlers);
  assert.equal(r8.matched, true);
  assert.equal(r8.action, 'bookmarkAudio');

  executeVoiceMove('annotate', handlers);
  assert.equal(actionsRun.filter(a => a === 'bookmarkAudio').length, 2);

  // 8. Unknown command
  const rUnknown = executeVoiceMove('unrecognized command foo bar', handlers);
  assert.equal(rUnknown.matched, false);
  assert.equal(rUnknown.action, null);
});

test('Integration: voiceCommand on mounted editor drives navigation and tools', () => {
  const { makeEl } = setupMockDom();
  const root = makeEl('div');
  const mounted = mountEditor(root, 'Topic A\n<!-- page -->\nTopic B');

  // Verify voice tool switching
  mounted.voiceCommand('highlighter');
  assert.equal(mounted.getInkTool(), 'highlighter');
  assert.equal(mounted.bridge.getInkTool(), 'highlighter');

  mounted.voiceCommand('eraser');
  assert.equal(mounted.getInkTool(), 'eraser');

  // Voice outline toggle
  assert.equal(mounted.isOutlineOpen(), false);
  mounted.voiceCommand('outline');
  assert.equal(mounted.isOutlineOpen(), true);
  mounted.voiceCommand('outline');
  assert.equal(mounted.isOutlineOpen(), false);

  // Voice search
  const findRes = mounted.voiceCommand('find');
  assert.equal(findRes.matched, true);
  assert.equal(findRes.action, 'openFind');

  // Voice audio commands
  const sumRes = mounted.voiceCommand('audio summary');
  assert.equal(sumRes.matched, true);
  assert.equal(sumRes.action, 'summarizeSection');

  const bmkRes = mounted.voiceCommand('bookmark');
  assert.equal(bmkRes.matched, true);
  assert.equal(bmkRes.action, 'bookmarkAudio');
});

test('CSS verification: calm slow-visual transitions, edge cues, and reduced motion', () => {
  const cssPath = path.resolve(__dirname, '../src/styles.css');
  const css = fs.readFileSync(cssPath, 'utf8');

  assert.ok(
    css.includes('320ms cubic-bezier(0.22, 1, 0.36, 1)'),
    'Styles must include calm 320ms cubic-bezier transition'
  );
  assert.ok(
    css.includes('@media (prefers-reduced-motion: reduce)'),
    'Styles must include prefers-reduced-motion media query'
  );
  assert.ok(
    css.includes('.rc-zone-active-left'),
    'Styles must define .rc-zone-active-left'
  );
  assert.ok(
    css.includes('.rc-zone-active-right'),
    'Styles must define .rc-zone-active-right'
  );
  assert.ok(
    css.includes('.rc-zone-active-top'),
    'Styles must define .rc-zone-active-top'
  );
  assert.ok(
    css.includes('pointer-events: none'),
    'Edge cue borders must have pointer-events: none'
  );
});
