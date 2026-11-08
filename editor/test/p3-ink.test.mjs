import test from 'node:test';
import assert from 'node:assert/strict';

import {
  INK_TOOLS,
  INK_COLORS,
  DEFAULT_LINE_HEIGHT,
  hashLineContext,
  getDocumentPages,
  anchorStrokeToDoc,
  resolveStrokeAnchor,
  mergeInkDocuments,
  snapUnderlineStroke,
  detectAndSnapShape,
  endHoldMs,
  SNAP_HOLD_MS,
  eraseWholeStrokes,
  erasePartialStrokes,
  createInkLayer,
  parseEmbedTarget
} from '../src/ink.js';

test('P3: INK_TOOLS and INK_COLORS match Notability specifications', () => {
  assert.deepEqual(INK_TOOLS, [
    'pen',
    'highlighter',
    'underline',
    'circle',
    'eraser-whole',
    'eraser-partial'
  ]);
  assert.deepEqual(INK_COLORS, [
    '#38bdf8',
    '#facc15',
    '#4ade80',
    '#f472b6',
    '#a78bfa',
    '#fb923c',
    '#f87171',
    '#e6edf3'
  ]);
  assert.equal(INK_COLORS.length, 8);
  for (const c of INK_COLORS) {
    assert.match(c, /^#[0-9a-f]{6}$/);
  }
});

test('P3: hashLineContext computes deterministic line hash', () => {
  const h1 = hashLineContext('The quick brown fox', 'Introduction', 'Jumps over');
  const h2 = hashLineContext('The quick brown fox', 'Introduction', 'Jumps over');
  assert.equal(h1, h2);
  assert.equal(typeof h1, 'string');
  assert.equal(h1.length, 8);

  const h3 = hashLineContext('Different text', 'Introduction', 'Jumps over');
  assert.notEqual(h1, h3);
});

test('P3: snapUnderlineStroke snaps wavy stroke to clean level underline', () => {
  const wavyPoints = [
    [10, 52, 0.5, 100],
    [30, 55, 0.6, 120],
    [60, 49, 0.5, 140],
    [90, 54, 0.7, 160],
    [120, 50, 0.4, 180]
  ];

  const snapped = snapUnderlineStroke(wavyPoints, 28);
  assert.equal(snapped.length, 2);
  const [start, end] = snapped;

  assert.equal(start[0], 10, 'minX is start x');
  assert.equal(end[0], 120, 'maxX is end x');
  assert.equal(start[1], end[1], 'level underline has identical Y coordinates');
  assert.equal(start[1], 52, 'snapY matches average Y of stroke points');
});

test('P3: detectAndSnapShape protects quick handwritten "o" and snaps held rough circles to ellipse', () => {
  // 1. Quick handwritten 'o' (holdDurationMs = 120 < 320ms) -> MUST NOT SNAP!
  const handwrittenO = [];
  const N = 16;
  for (let i = 0; i <= N; i++) {
    const angle = (i / N) * 2 * Math.PI;
    handwrittenO.push([50 + 15 * Math.cos(angle), 50 + 18 * Math.sin(angle), 0.5, i * 7]);
  }
  const quickResult = detectAndSnapShape(handwrittenO, { holdDurationMs: 120, forceCircle: false });
  assert.equal(quickResult.snapped, false, 'quick handwritten "o" never snaps');
  assert.equal(quickResult.shape, null);
  assert.equal(quickResult.points.length, handwrittenO.length);

  // 2. Held rough circle whose ends meet -> snaps to ellipse with 48 points
  const heldRoughCircle = [];
  for (let i = 0; i <= 24; i++) {
    const angle = (i / 24) * 2 * Math.PI;
    const r = 35 + (i % 3 === 0 ? 3 : -2);
    heldRoughCircle.push([100 + r * Math.cos(angle), 100 + r * Math.sin(angle), 0.5, i * 15]);
  }
  const heldCircleResult = detectAndSnapShape(heldRoughCircle, { holdDurationMs: SNAP_HOLD_MS, forceCircle: false });
  assert.equal(heldCircleResult.snapped, true);
  assert.equal(heldCircleResult.shape.kind, 'ellipse');
  assert.equal(heldCircleResult.points.length, 48, 'generates exactly 48 perimeter points');
  assert.ok(Math.abs(heldCircleResult.shape.cx - 100) <= 3);
  assert.ok(Math.abs(heldCircleResult.shape.cy - 100) <= 3);

  // 3. forceCircle === true (circle tool) -> Snaps to ellipse with 48 points even with holdDurationMs = 0
  const forceCircleResult = detectAndSnapShape(heldRoughCircle.slice(0, 10), { forceCircle: true });
  assert.equal(forceCircleResult.snapped, true);
  assert.equal(forceCircleResult.shape.kind, 'ellipse');
  assert.equal(forceCircleResult.points.length, 48);

  // 4. Held, nearly straight -> straight line; held open arc or zigzag -> stays as drawn
  const straightLine = [
    [10, 20, 0.5, 0],
    [50, 22.5, 0.5, 100],
    [100, 20, 0.5, 350]
  ];
  const lineResult = detectAndSnapShape(straightLine, { holdDurationMs: SNAP_HOLD_MS });
  assert.equal(lineResult.snapped, true, 'held, nearly straight stroke becomes a line');
  assert.deepEqual(lineResult.shape, { kind: 'line', x1: 10, y1: 20, x2: 100, y2: 20 });
  assert.equal(detectAndSnapShape(straightLine, { holdDurationMs: 0 }).snapped, false, 'not held: stays as drawn');
  const openArc = heldRoughCircle.slice(0, 18);
  assert.equal(detectAndSnapShape(openArc, { holdDurationMs: 2000 }).snapped, false, 'held open arc stays as drawn');
  const zigzag = [[0, 0, 0.5, 0], [20, 15, 0.5, 50], [40, 0, 0.5, 100], [60, 15, 0.5, 150], [80, 0, 0.5, 200]];
  assert.equal(detectAndSnapShape(zigzag, { holdDurationMs: 2000 }).snapped, false, 'held cursive-like zigzag stays as drawn');
  const shortDash = [[0, 0, 0.5, 0], [25, 0, 0.5, 100]];
  assert.equal(detectAndSnapShape(shortDash, { holdDurationMs: 2000 }).snapped, false, 'letter-sized dash (a "-" or "t" bar) stays as drawn');

  // 5. Held closed loop but letter-sized (a slow, held "o") never snaps
  const smallO = [];
  for (let i = 0; i <= 20; i++) {
    const a = (i / 20) * 2 * Math.PI;
    smallO.push([50 + 9 * Math.cos(a), 50 + 11 * Math.sin(a), 0.5, i * 40]);
  }
  assert.equal(detectAndSnapShape(smallO, { holdDurationMs: 2000 }).snapped, false, 'letter-sized loop stays a letter');

  // 6. Closed loop that is not held long enough never snaps
  assert.equal(detectAndSnapShape(heldRoughCircle, { holdDurationMs: SNAP_HOLD_MS - 1 }).snapped, false);
});

test('P3: endHoldMs counts only the stillness before lift, not the whole stroke', () => {
  // A slow 900 ms letter stroke, lifted while still moving: no hold.
  const slowLetter = [];
  for (let i = 0; i <= 30; i++) slowLetter.push([10 + i * 8, 20 + (i % 2) * 8, 0.5, i * 30]);
  assert.equal(endHoldMs(slowLetter, 905), 5);
  // The pen stops at (40, 20) at t=600 and rests there until lift at t=1200.
  const held = [[0, 20, 0.5, 0], [20, 20, 0.5, 300], [40, 20, 0.5, 600], [41, 21, 0.5, 900], [40, 20, 0.5, 1150]];
  assert.equal(endHoldMs(held, 1200), 600);
  assert.equal(endHoldMs([], 100), 0);
});

test('P3: eraseWholeStrokes removes intersecting stroke and collects removed ID', () => {
  const strokes = [
    {
      id: 'stroke-1',
      tool: 'pen',
      color: '#38bdf8',
      width: 2.5,
      points: [
        [10, 10, 0.5, 0],
        [50, 10, 0.5, 10]
      ]
    },
    {
      id: 'stroke-2',
      tool: 'pen',
      color: '#facc15',
      width: 2.5,
      points: [
        [10, 100, 0.5, 0],
        [50, 100, 0.5, 10]
      ]
    }
  ];

  const eraser = [[30, 12]];
  const { remaining, removedIds } = eraseWholeStrokes(strokes, eraser, 12);

  assert.equal(remaining.length, 1);
  assert.equal(remaining[0].id, 'stroke-2');
  assert.deepEqual(removedIds, ['stroke-1']);
});

test('P3: erasePartialStrokes splits a stroke into two clean sub-strokes', () => {
  const stroke = {
    id: 'stroke-orig',
    tool: 'pen',
    color: '#4ade80',
    width: 2.5,
    points: [
      [0, 50, 0.5, 0],
      [20, 50, 0.5, 10],
      [40, 50, 0.5, 20],
      [60, 50, 0.5, 30],
      [80, 50, 0.5, 40],
      [100, 50, 0.5, 50]
    ],
    anchor: {
      lineNumber: 2,
      lineText: 'Second line',
      pageIndex: 0,
      offsetInPage: 1,
      relX: 0,
      relY: 22
    }
  };

  const eraser = [[50, 50]];
  const { remaining, removedIds } = erasePartialStrokes([stroke], eraser, 10);

  assert.deepEqual(removedIds, ['stroke-orig'], 'original stroke ID tombstoned');
  assert.equal(remaining.length, 2, 'split into exactly 2 sub-strokes');

  const part1 = remaining[0];
  const part2 = remaining[1];

  assert.equal(part1.id, 'stroke-orig-part-1');
  assert.equal(part2.id, 'stroke-orig-part-2');
  assert.equal(part1.color, stroke.color);
  assert.equal(part2.color, stroke.color);

  const part1MaxX = Math.max(...part1.points.map(p => p[0]));
  const part2MinX = Math.min(...part2.points.map(p => p[0]));
  assert.ok(part1MaxX < 50, 'part1 ends before erased center');
  assert.ok(part2MinX > 50, 'part2 starts after erased center');
});

test('P3: per-window line anchoring: Window 0 edits produce deltaY=0 for Window 1, while Window 1 edits shift ink', () => {
  const docV1 = [
    'Title Window 0',
    'Body Window 0',
    '<!-- page -->',
    'Title Window 1',
    'Important note in Window 1',
    'Footer Window 1'
  ].join('\n');

  const strokeInWindow1 = {
    id: 'stroke-w1',
    tool: 'pen',
    color: '#38bdf8',
    width: 2.5,
    points: [
      [20, 28, 0.5, 0], // y=28 is line index 1 within Window 1 (which starts at line 4)
      [80, 28, 0.5, 10]
    ]
  };

  // Anchor to Window 1 (pageIndex = 1)
  const anchor = anchorStrokeToDoc(strokeInWindow1, docV1, 28, 1);
  assert.equal(anchor.pageIndex, 1);
  assert.equal(anchor.offsetInPage, 1, 'lineIndexInPage is 1 within Window 1');
  assert.equal(anchor.lineText, 'Important note in Window 1');

  // Probe 1: Insert 3 lines in Window 0 (pageIndex = 0)
  const docV2 = [
    'Title Window 0',
    'Extra line 1',
    'Extra line 2',
    'Extra line 3',
    'Body Window 0',
    '<!-- page -->',
    'Title Window 1',
    'Important note in Window 1',
    'Footer Window 1'
  ].join('\n');

  const resW0Edit = resolveStrokeAnchor(strokeInWindow1, docV2, 28);
  assert.equal(resW0Edit.orphaned, false);
  assert.equal(resW0Edit.pageIndex, 1);
  assert.equal(resW0Edit.deltaY, 0, 'inserting lines in Window 0 produces deltaY = 0 for Window 1 ink!');
  assert.equal(resW0Edit.points[0][1], 28);

  // Probe 2: Insert 3 lines at the top of Window 1
  const docV3 = [
    'Title Window 0',
    '<!-- page -->',
    'New line 1 in W1',
    'New line 2 in W1',
    'New line 3 in W1',
    'Title Window 1',
    'Important note in Window 1',
    'Footer Window 1'
  ].join('\n');

  const resW1Edit = resolveStrokeAnchor(strokeInWindow1, docV3, 28);
  assert.equal(resW1Edit.orphaned, false);
  assert.equal(resW1Edit.deltaY, 3 * 28, 'shifts down by 84px (3 lines * 28px) when lines are typed in Window 1');
  assert.equal(resW1Edit.points[0][1], 28 + 84);

  // Probe 3: Delete line in Window 1 -> orphaned
  const docV4 = [
    'Title Window 0',
    '<!-- page -->',
    'Title Window 1',
    'Footer Window 1'
  ].join('\n');

  const resDeleted = resolveStrokeAnchor(strokeInWindow1, docV4, 28);
  assert.equal(resDeleted.orphaned, true, 'orphaned when line is deleted from Window 1');
  assert.equal(resDeleted.deltaY, 0);
  assert.equal(resDeleted.points[0][1], strokeInWindow1.points[0][1]);
});

test('P3: dropped-in file embed ![](diagram.png) keeps its ink on top when lines are inserted above it', () => {
  const docV1 = [
    '# Architecture',
    'Overview text here.',
    '![](diagram.png)',
    'Caption below.'
  ].join('\n');

  const strokeOnDiagram = {
    id: 'stroke-diagram-note',
    tool: 'highlighter',
    color: '#facc15',
    width: 18,
    points: [
      [30, 56, 0.5, 0],
      [120, 56, 0.5, 20]
    ]
  };

  const anchor = anchorStrokeToDoc(strokeOnDiagram, docV1, 28, 0);
  assert.equal(anchor.offsetInPage, 2);
  assert.equal(anchor.embedTarget, 'diagram.png');

  // Insert 3 new lines above the embed in the same window
  const docV2 = [
    '# Architecture',
    'New line A',
    'New line B',
    'New line C',
    'Overview text here.',
    '![](diagram.png)',
    'Caption below.'
  ].join('\n');

  const res = resolveStrokeAnchor(strokeOnDiagram, docV2, 28);
  assert.equal(res.orphaned, false);
  assert.equal(res.deltaY, 3 * 28, 'shifts down by 84px to follow dropped-in diagram.png');
  assert.equal(res.points[0][1], 56 + 84);
});

test('P3: CRDT mergeInkDocuments merges strokes and respects removed tombstones', () => {
  const localDoc = {
    version: 1,
    strokes: [
      { id: 'stroke-mac-1', tool: 'pen', color: '#38bdf8', width: 2.5, at: 1000, points: [[10, 10, 0.5, 0]] },
      { id: 'stroke-shared', tool: 'pen', color: '#38bdf8', width: 2.5, at: 1000, points: [[20, 20, 0.5, 0]] }
    ],
    removed: []
  };

  const remoteDoc = {
    version: 1,
    strokes: [
      { id: 'stroke-ipad-1', tool: 'highlighter', color: '#facc15', width: 18, at: 1500, points: [[50, 50, 0.5, 0]] },
      { id: 'stroke-shared', tool: 'pen', color: '#f472b6', width: 2.5, at: 2000, points: [[20, 25, 0.5, 0]] }
    ],
    removed: ['stroke-mac-1']
  };

  const merged = mergeInkDocuments(localDoc, remoteDoc);

  assert.equal(merged.version, 1);
  assert.ok(merged.removed.includes('stroke-mac-1'), 'tombstone preserved');

  const strokeIds = merged.strokes.map(s => s.id);
  assert.ok(!strokeIds.includes('stroke-mac-1'), 'stroke-mac-1 deleted by tombstone');
  assert.ok(strokeIds.includes('stroke-ipad-1'), 'remote stroke preserved');
  assert.ok(strokeIds.includes('stroke-shared'), 'shared stroke preserved');

  const shared = merged.strokes.find(s => s.id === 'stroke-shared');
  assert.equal(shared.color, '#f472b6', 'LWW resolved in favor of newer edit');
});

test('P3: createInkLayer manages 240Hz coalesced events, embed capture, per-window ink, and palette DOM', async () => {
  // Mock DOM and view harness
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

  const mockDoc = {
    createElementNS(ns, tag) {
      return createMockElement(tag);
    },
    createElement(tag) {
      return createMockElement(tag);
    }
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
      if (map[name]) {
        map[name] = map[name].filter(f => f !== fn);
      }
    }
  };

  const posted = [];
  const fakeWindow = {
    document: mockDoc,
    webkit: {
      messageHandlers: {
        ink: {
          postMessage(msg) {
            posted.push(msg);
          }
        }
      }
    }
  };

  let activeWindow = 0;
  const mockView = {
    scrollDOM,
    state: {
      doc: {
        toString: () => 'Window 0 line\n<!-- page -->\nWindow 1 line'
      }
    }
  };

  const layer = createInkLayer(mockView, {
    globalObj: fakeWindow,
    debounceMs: 20,
    lineHeight: 28,
    getPageIndex: () => activeWindow
  });

  // Verify Palette DOM: 8 pure color dots, 6 tool dots, zero text/words, no Done button
  assert.ok(layer.palette, 'palette DOM element created');
  assert.equal(layer.palette.hidden, true, 'palette hidden by default');
  layer.showPalette();
  assert.equal(layer.palette.hidden, false);
  layer.hidePalette();
  assert.equal(layer.palette.hidden, true);

  const colorButtons = layer.palette.children.filter(c => c.attributes['data-color']);
  const toolButtons = layer.palette.children.filter(c => c.attributes['data-tool']);
  assert.equal(colorButtons.length, 8, '8 color dots');
  assert.equal(toolButtons.length, 4, 'Select, pen, highlighter, one eraser (no Underline, Circle or partial eraser)');
  assert.equal(toolButtons[0].attributes['data-tool'], 'select', 'Select comes first');
  // The pill and palette float in their own dock, never inside the text scroller (that squeezed the text).
  assert.ok(layer.dock && layer.pill, 'dock and pill exist');
  assert.equal(scrollDOM.children.includes(layer.dock), false, 'dock is not a child of the scroller');
  assert.equal(scrollDOM.children.includes(layer.palette), false, 'palette is not a child of the scroller');
  assert.equal(layer.getTool(), 'select', 'starts on Select so a mouse drag selects text');
  assert.equal(layer.toggleMenu(), true, 'pill wakes the palette');
  assert.equal(layer.palette.hidden, false);
  assert.equal(layer.toggleMenu(), false, 'and puts it back to sleep');
  // A mouse drag on Select draws nothing (it is a text selection).
  bubbleListeners.pointerdown.forEach(fn => fn({ pointerType: 'mouse', clientX: 5, clientY: 5, timeStamp: 1, preventDefault: () => {} }));
  bubbleListeners.pointerup.forEach(fn => fn({ pointerType: 'mouse', clientX: 9, clientY: 5, timeStamp: 2 }));
  assert.equal(layer.getInk().strokes.length, 0, 'mouse on Select leaves no ink');
  // Picking the eraser from the palette selects it (it used to stay on the pen).
  toolButtons.find(b => b.attributes['data-tool'] === 'eraser-whole')._listeners.click[0]({ preventDefault() {} });
  assert.equal(layer.getTool(), 'eraser-whole', 'eraser click selects the eraser');
  // The palette's colour dots pick the last pen back up from an eraser.
  colorButtons[1]._listeners.click[0]({ preventDefault() {} });
  assert.equal(layer.getTool(), 'pen');
  // An explicit Select keeps the Pencil from inking too (it selects); back to Pen for the probes below.
  layer.setTool('select');
  bubbleListeners.pointerdown.forEach(fn => fn({ pointerType: 'pen', clientX: 5, clientY: 5, timeStamp: 1, preventDefault: () => {} }));
  bubbleListeners.pointerup.forEach(fn => fn({ pointerType: 'pen', clientX: 9, clientY: 5, timeStamp: 2 }));
  assert.equal(layer.getInk().strokes.length, 0, 'Pencil on a chosen Select leaves no ink');
  layer.setTool('pen');
  // The colour wheel: right after the eraser; what it picks replaces the selected dot's colour.
  const kids = layer.palette.children;
  const eraserIdx = kids.findIndex(c => c.attributes['data-tool'] === 'eraser-whole');
  assert.equal(kids[eraserIdx + 1].attributes['aria-label'], 'Colour wheel');
  const before = layer.getPaletteColors();
  layer.setColor(before[2]);
  assert.equal(layer.replaceSelectedColor('#123456'), '#123456');
  assert.deepEqual(layer.getPaletteColors(), [...before.slice(0, 2), '#123456', ...before.slice(3)]);
  assert.equal(layer.getColor(), '#123456');
  assert.equal(layer.replaceSelectedColor('not a colour'), null);
  // A shade from the eyedropper waits under the check mark; closing the wheel keeps the current colour.
  layer.showPalette();
  assert.equal(layer.offerColor('#abcdef'), '#abcdef');
  assert.equal(layer.getColor(), '#123456', 'nothing changes before the check mark');
  layer.setWheelOpen(false);
  assert.equal(layer.getPendingColor(), null);
  assert.equal(layer.getColor(), '#123456', 'dismissed: the current colour stays');
  layer.hidePalette();
  for (const b of colorButtons) {
    assert.equal(b.textContent, '', 'color dot has zero text/words');
    assert.ok(b.style.backgroundColor);
  }
  for (const b of toolButtons) {
    assert.equal(b.textContent, '', 'tool dot has zero text/words');
  }

  // Probe 1: 240Hz Apple Pencil Pro coalesced events in onPointerMove
  const pointerDown = {
    pointerType: 'pen',
    clientX: 10,
    clientY: 10,
    pressure: 0.5,
    timeStamp: 1000,
    preventDefault: () => {}
  };
  bubbleListeners.pointerdown.forEach(fn => fn(pointerDown));

  // Pointer move with 3 coalesced high-frequency samples from Apple Pencil Pro
  const coalescedSamples = [
    { clientX: 20, clientY: 12, pressure: 0.6, timeStamp: 1004 },
    { clientX: 30, clientY: 15, pressure: 0.7, timeStamp: 1008 },
    { clientX: 40, clientY: 18, pressure: 0.8, timeStamp: 1012 }
  ];
  const pointerMoveWithCoalesced = {
    pointerType: 'pen',
    clientX: 40,
    clientY: 18,
    pressure: 0.8,
    timeStamp: 1012,
    getCoalescedEvents: () => coalescedSamples,
    preventDefault: () => {}
  };
  bubbleListeners.pointermove.forEach(fn => fn(pointerMoveWithCoalesced));

  const pointerUp = {
    pointerType: 'pen',
    clientX: 40,
    clientY: 18,
    timeStamp: 1020
  };
  bubbleListeners.pointerup.forEach(fn => fn(pointerUp));

  // Stroke created should include all 4 samples (start + 3 coalesced samples)
  const ink = layer.getInk();
  assert.equal(ink.strokes.length, 1);
  assert.equal(ink.strokes[0].points.length, 4, 'all 3 coalesced samples appended to active stroke');

  // Probe 2: Capture listener intercepts Pencil over .cm-embed
  assert.ok(captureListeners.pointerdown.length > 0, 'capture listener installed for pointerdown');
  assert.ok(captureListeners.pointerenter.length > 0, 'capture listener installed for pointerenter');
  let stopped = false;
  let prevented = false;
  const embedPencilDown = {
    pointerType: 'pen',
    clientX: 50,
    clientY: 50,
    pressure: 0.5,
    timeStamp: 2000,
    stopPropagation: () => { stopped = true; },
    preventDefault: () => { prevented = true; }
  };
  captureListeners.pointerdown.forEach(fn => fn(embedPencilDown));
  assert.ok(stopped, 'stopPropagation called on capture');
  assert.ok(prevented, 'preventDefault called on capture');

  // Clean up
  bubbleListeners.pointerup.forEach(fn => fn(pointerUp));
  layer.destroy();
});
