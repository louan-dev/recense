import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  mountEditor,
  anchorStrokeToDoc
} from '../src/index.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function setupMockDom() {
  class FakeObserver {
    observe() {}
    disconnect() {}
    takeRecords() {
      return [];
    }
  }

  const messages = { editor: [], ui: [], ink: [], audio: [] };

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
        lineHeight: '28px',
        fontSize: '18px',
        direction: 'ltr'
      });
      this.requestAnimationFrame = () => 0;
      this.cancelAnimationFrame = () => {};
      this.MutationObserver = FakeObserver;
      this.webkit = {
        messageHandlers: {
          editor: { postMessage(m) { messages.editor.push(m); } },
          ui: { postMessage(m) { messages.ui.push(m); } },
          ink: { postMessage(m) { messages.ink.push(m); } },
          audio: { postMessage(m) { messages.audio.push(m); } }
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
        return { left: 0, top: 0, width: 100, height: 28 };
      },
      getClientRects() {
        return [];
      }
    })
  };
  win.document = doc;

  function makeEl(tag = 'div') {
    const attrs = [];
    const classes = new Set();
    const children = [];
    const el = {
      nodeType: 1,
      nodeName: tag.toUpperCase(),
      tagName: tag.toUpperCase(),
      ownerDocument: doc,
      style: { setProperty() {} },
      attributes: attrs,
      dataset: {},
      hidden: false,
      textContent: '',
      innerHTML: '',
      children,
      childNodes: children,
      firstChild: null,
      parentNode: null,
      parentElement: null,
      clientWidth: 800,
      clientHeight: 600,
      scrollTop: 0,
      scrollLeft: 0,
      setAttribute(k, v) {
        el[k] = v;
        const idx = attrs.findIndex(a => a.name === k);
        if (idx >= 0) attrs[idx].value = String(v);
        else attrs.push({ name: k, value: String(v) });
        if (k === 'class') {
          classes.clear();
          String(v).split(/\s+/).filter(Boolean).forEach(c => classes.add(c));
        }
      },
      getAttribute(k) {
        const found = attrs.find(a => a.name === k);
        return found ? found.value : null;
      },
      removeAttribute(k) {
        const idx = attrs.findIndex(a => a.name === k);
        if (idx >= 0) attrs.splice(idx, 1);
        delete el[k];
      },
      hasAttribute(k) {
        return attrs.some(a => a.name === k);
      },
      classList: {
        add(...cs) { cs.forEach(c => classes.add(c)); },
        remove(...cs) { cs.forEach(c => classes.delete(c)); },
        contains(c) { return classes.has(c); },
        toggle(c, force) {
          if (force === undefined) {
            if (classes.has(c)) { classes.delete(c); return false; }
            classes.add(c); return true;
          }
          if (force) classes.add(c); else classes.delete(c);
          return Boolean(force);
        }
      },
      appendChild(child) {
        if (child && typeof child === 'object') {
          child.parentNode = el;
          child.parentElement = el;
          children.push(child);
          el.firstChild = children[0] || null;
        }
        return child;
      },
      removeChild(child) {
        const i = children.indexOf(child);
        if (i >= 0) children.splice(i, 1);
        el.firstChild = children[0] || null;
        return child;
      },
      remove() {
        if (el.parentNode && typeof el.parentNode.removeChild === 'function') {
          el.parentNode.removeChild(el);
        }
      },
      insertBefore(child, ref) {
        const i = children.indexOf(ref);
        if (i >= 0) children.splice(i, 0, child);
        else children.push(child);
        el.firstChild = children[0] || null;
        return child;
      },
      replaceChildren(...newChildren) {
        children.length = 0;
        newChildren.forEach(c => el.appendChild(c));
      },
      append(...items) {
        items.forEach(c => el.appendChild(c));
      },
      contains(target) {
        if (target === el) return true;
        return children.some(c => c.contains && c.contains(target));
      },
      addEventListener() {},
      removeEventListener() {},
      getBoundingClientRect() {
        return { left: 0, top: 0, width: 800, height: 600, right: 800, bottom: 600 };
      },
      getClientRects() {
        return [];
      },
      focus() {},
      select() {},
      scrollTo(opts) {
        if (opts && typeof opts.top === 'number') el.scrollTop = opts.top;
      }
    };
    Object.defineProperty(el, 'className', {
      get() { return Array.from(classes).join(' '); },
      set(v) {
        classes.clear();
        String(v || '').split(/\s+/).filter(Boolean).forEach(c => classes.add(c));
      }
    });
    return el;
  }

  doc.head = makeEl('head');
  doc.body = makeEl('body');
  doc.documentElement = makeEl('html');
  global.window = win;
  global.document = doc;
  global.MutationObserver = FakeObserver;
  return { win, doc, makeEl, messages };
}

test('P5 Integration: mounted editor unifies navigation, ink sidecar, Pencil Pro squeeze, dropped embeds, and live audio summaries', () => {
  const { makeEl, messages } = setupMockDom();
  const root = makeEl('div');
  const initialDoc = 'Saturday, November 8, 2026\n\n§ 1. Jurisdiction\nThe court held that jurisdiction is proper under Article 4. Therefore the motion is denied.\n\n<!-- page -->\n\nOlder Topic';
  const mounted = mountEditor(root, initialDoc);
  const api = mounted.bridge;

  // 1. Apple Pencil Pro squeeze or double-tap wakes the palette under the pill (and sleeps it), with a haptic
  assert.equal(api.getInkTool(), 'select');
  assert.equal(api.onPencilAction('squeeze'), 'awake');
  assert.equal(mounted.inkLayer.palette.hidden, false);
  assert.ok(messages.ui.some(m => m && m.haptic === 'squeeze'));
  assert.equal(api.onPencilAction('doubleTap'), 'asleep');
  assert.equal(mounted.inkLayer.palette.hidden, true);
  assert.equal(api.getInkTool(), 'select', 'waking the palette changes no tool');

  // 2. Dropped-in file embed inserts ![](...) and keeps its ink on top when lines are inserted above
  const embedMd = api.dropFile('exhibits/chart 01.pdf', 'Exhibit A');
  assert.equal(embedMd, '![Exhibit A](<exhibits/chart 01.pdf>)');
  assert.ok(api.getText().includes('![Exhibit A](<exhibits/chart 01.pdf>)'));

  const docWithEmbed = api.getText();
  const embedLineIdx = docWithEmbed.split('\n').findIndex(l => l.includes('![Exhibit A]'));
  const strokeOnEmbed = {
    id: 'embed-stroke-1',
    tool: 'pen',
    color: '#38bdf8',
    width: 2.5,
    points: [[40, embedLineIdx * 28 + 6, 0.6, 1000], [120, embedLineIdx * 28 + 6, 0.6, 1020]]
  };
  anchorStrokeToDoc(strokeOnEmbed, docWithEmbed, 28, 0);
  assert.equal(strokeOnEmbed.anchor.embedTarget, 'exhibits/chart 01.pdf');

  api.setInk({ version: 1, strokes: [strokeOnEmbed], removed: [] });
  const remoteMerged = api.mergeInk({
    version: 1,
    strokes: [{
      id: 'remote-stroke-2',
      tool: 'highlighter',
      color: '#facc15',
      width: 18,
      points: [[10, 28, 0.5, 2000], [90, 28, 0.5, 2010]]
    }],
    removed: []
  });
  assert.equal(remoteMerged.strokes.length, 2);

  // 3. Live audio transcript sidecar, bookmarking, annotation, and offline section summary
  api.setAudioTranscript({
    playing: true,
    title: 'Oral Argument',
    currentTime: 14,
    cues: [
      { id: 'c1', start: 0, end: 10, text: 'May it please the court.' },
      { id: 'c2', start: 10, end: 25, text: 'Jurisdiction is proper under Article 4.' }
    ]
  });
  assert.equal(api.updateAudioTime(15), 1);

  const bm = api.bookmarkAudioCue(1, 'Key concession');
  assert.equal(bm.cueId, 'c2');
  assert.ok(messages.audio.some(m => m && m.action === 'bookmark' && m.cueId === 'c2'));

  const ann = api.annotateAudioCue(1, 'Cite in brief');
  assert.ok(ann.reference.includes('[@00:10]'));
  assert.ok(api.getText().includes('[@00:10] Jurisdiction is proper under Article 4. — Cite in brief'));

  const spoken = api.summarizeSection(0);
  assert.ok(spoken && spoken.text.length > 0);
  assert.ok(messages.audio.some(m => m && m.action === 'speakSummary'));
});

test('P5 Host Parity: strip/editorhost.swift and mobile/HostApp/iOS/Draftpad.swift mirror all 5 channels, ink sidecar, and zero-chrome whiteboard', () => {
  const repoRoot = path.resolve(__dirname, '../..');
  const macHost = fs.readFileSync(path.join(repoRoot, 'strip/editorhost.swift'), 'utf8');
  const iosHost = fs.readFileSync(path.join(repoRoot, 'mobile/HostApp/iOS/Draftpad.swift'), 'utf8');

  for (const ch of ['"editor"', '"link"', '"ui"', '"ink"', '"audio"']) {
    assert.ok(macHost.includes(ch), `Mac host must register channel ${ch}`);
    assert.ok(iosHost.includes(ch), `iOS host must register channel ${ch}`);
  }

  assert.ok(macHost.includes('draftpad.ink.json'), 'Mac host must persist draftpad.ink.json');
  assert.ok(iosHost.includes('draftpad.ink.json'), 'iOS host must persist draftpad.ink.json');
  assert.ok(macHost.includes('AVSpeechSynthesizer'), 'Mac host must speak summaries via AVSpeechSynthesizer');
  assert.ok(iosHost.includes('AVSpeechSynthesizer'), 'iOS host must speak summaries via AVSpeechSynthesizer');

  assert.ok(!iosHost.includes('PKCanvasView'), 'iOS host must not use modal PKCanvasView');
  assert.ok(!iosHost.includes('Button("Done")'), 'iOS host must not have a Done button');
  assert.ok(iosHost.includes('.toolbar(.hidden, for: .navigationBar)'), 'iOS host must hide navigationBar chrome at rest');
});
