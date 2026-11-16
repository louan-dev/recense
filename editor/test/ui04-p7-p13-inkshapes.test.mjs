// Derived from Spec: UI-04 P7–P12 — polygon hold-to-snap, fill hit tests, lasso, transforms, menu actions, style.
// Regression guard: UI-04
import test from 'node:test';
import assert from 'node:assert/strict';

import { detectAndSnapShape, SNAP_HOLD_MS, mergeInkDocuments } from '../src/ink.js';
import {
  fitPolygon, polygonCorners, shapeHandles, moveHandle,
  pointInPolygon, pointInEllipse, closedShapeAt,
  selectInLasso, expandGroups,
  translate, scaleAbout, rotateAbout, mirrorH, mirrorV, compose, transformStroke, strokesBounds,
  duplicateStrokes, toggleGroup, applyStyle, strokeStyleOf, dashFor
} from '../src/inkshapes.js';

// A deterministic "hand": each edge sampled with jitter, ending just past the start.
function hand(seed = 7) {
  return () => ((seed = (seed * 16807) % 2147483647) / 2147483647 - 0.5);
}
function loop(corners, { per = 10, noise = 5, seed = 7 } = {}) {
  const rnd = hand(seed);
  const pts = [];
  let t = 0;
  for (let i = 0; i < corners.length; i++) {
    const a = corners[i], b = corners[(i + 1) % corners.length];
    for (let k = 0; k < per; k++) {
      const u = k / per;
      pts.push([a[0] + (b[0] - a[0]) * u + rnd() * noise, a[1] + (b[1] - a[1]) * u + rnd() * noise, 0.5, (t += 10)]);
    }
  }
  pts.push([corners[0][0] + 2, corners[0][1] + 1, 0.5, (t += 10)]);
  return pts;
}
function circle(cx, cy, r, { n = 40, noise = 2, seed = 3 } = {}) {
  const rnd = hand(seed);
  const pts = [];
  for (let i = 0; i <= n; i++) {
    const a = (i / n) * 2 * Math.PI;
    pts.push([cx + r * Math.cos(a) + rnd() * noise, cy + r * Math.sin(a) + rnd() * noise, 0.5, i * 10]);
  }
  return pts;
}
const held = { holdDurationMs: SNAP_HOLD_MS };
const near = (a, b, tol = 1e-6) => Math.abs(a - b) <= tol;
const pentagon = Array.from({ length: 5 }, (_, i) => {
  const a = -Math.PI / 2 + (i * 2 * Math.PI) / 5;
  return [200 + 60 * Math.cos(a), 200 + 60 * Math.sin(a)];
});

for (const seed of [7, 12345, 99]) {
  test(`P7 (seed ${seed}): held rough loops snap to triangle, right triangle, rectangle, trapezoid, pentagon`, () => {
    const cases = [
      ['triangle', [[100, 200], [160, 90], [220, 200]]],
      ['right-triangle', [[100, 100], [100, 220], [240, 220]]],
      ['rectangle', [[100, 100], [260, 100], [260, 180], [100, 180]]],
      ['rectangle', [[100, 100], [400, 100], [400, 150], [100, 150]]],   // long thin box
      ['trapezoid', [[130, 100], [230, 100], [270, 170], [90, 170]]],
      ['pentagon', pentagon]
    ];
    for (const [name, corners] of cases) {
      const r = detectAndSnapShape(loop(corners, { seed }), held);
      assert.equal(r.snapped, true, name);
      assert.equal(r.shape.kind, 'polygon', name);
      assert.equal(r.shape.name, name);
      // Closed: the first corner is repeated, so an older build draws a closed outline.
      assert.deepEqual(r.points[0].slice(0, 2), r.points[r.points.length - 1].slice(0, 2));
      assert.equal(polygonCorners(r).length, corners.length, `${name} corner count`);
    }
  });
}

test('P7: a rectangle is tidied to exact right angles, axis-aligned', () => {
  const r = detectAndSnapShape(loop([[100, 100], [260, 100], [260, 180], [100, 180]]), held);
  const c = polygonCorners(r);
  assert.ok(near(c[0][1], c[1][1]) && near(c[1][0], c[2][0]) && near(c[2][1], c[3][1]) && near(c[3][0], c[0][0]));
});

test('P7: a right triangle keeps its legs on the axes; a trapezoid is made symmetric', () => {
  const rt = polygonCorners(detectAndSnapShape(loop([[100, 100], [100, 220], [240, 220]]), held));
  const xs = rt.map(p => p[0]), ys = rt.map(p => p[1]);
  assert.ok(xs.filter(x => near(x, Math.min(...xs))).length === 2, 'a vertical leg');
  assert.ok(ys.filter(y => near(y, Math.max(...ys))).length === 2, 'a horizontal leg');
  const tz = polygonCorners(detectAndSnapShape(loop([[130, 100], [230, 100], [270, 170], [90, 170]]), held));
  const top = tz.filter(p => p[1] < 135), bottom = tz.filter(p => p[1] > 135);
  const mid = side => (side[0][0] + side[1][0]) / 2;
  assert.ok(near(mid(top), mid(bottom), 1e-6), 'isosceles: both sides centred');
});

test('P7: a held round loop is still an ellipse; a near-straight stroke is still a line', () => {
  for (const pts of [circle(200, 200, 60), circle(200, 200, 60, { n: 24, noise: 6 }),
    circle(200, 200, 60).map(p => [200 + (p[0] - 200) * 1.8, p[1], p[2], p[3]])]) {
    assert.equal(detectAndSnapShape(pts, held).shape.kind, 'ellipse');
  }
  const line = [[10, 20, 0.5, 0], [50, 22, 0.5, 100], [100, 20, 0.5, 200]];
  assert.equal(detectAndSnapShape(line, held).shape.kind, 'line');
});

test('P7: un-held or letter-sized shapes never snap', () => {
  const tri = loop([[100, 200], [160, 90], [220, 200]]);
  assert.equal(detectAndSnapShape(tri, { holdDurationMs: SNAP_HOLD_MS - 1 }).snapped, false);
  const small = loop([[10, 30], [20, 12], [30, 30]], { noise: 1 });
  assert.equal(detectAndSnapShape(small, { holdDurationMs: 2000 }).snapped, false, 'a held letter "A"-sized triangle stays ink');
  assert.equal(fitPolygon([[0, 0], [1, 1]]), null);
});

test('P7: corner handles move one corner (and the closing copy of the first)', () => {
  const r = detectAndSnapShape(loop([[100, 200], [160, 90], [220, 200]]), held);
  const stroke = { id: 's', tool: 'pen', points: r.points, shape: r.shape };
  assert.equal(shapeHandles(stroke).length, 3);
  const moved = moveHandle(stroke, 0, 50, 250);
  assert.deepEqual(moved.points[0].slice(0, 2), [50, 250]);
  assert.deepEqual(moved.points[moved.points.length - 1].slice(0, 2), [50, 250]);
  assert.deepEqual(stroke.points[0].slice(0, 2), r.points[0].slice(0, 2), 'original untouched');
  const line = { id: 'l', points: [[0, 0, 0.5, 0], [100, 0, 0.5, 1]], shape: { kind: 'line', x1: 0, y1: 0, x2: 100, y2: 0 } };
  const ml = moveHandle(line, 1, 120, 40);
  assert.deepEqual([ml.shape.x2, ml.shape.y2], [120, 40]);
});

test('P8: closed-shape hit tests (ellipse, rotated ellipse, triangle, concave quad) pick the topmost', () => {
  assert.equal(pointInEllipse(100, 100, { cx: 100, cy: 100, rx: 50, ry: 20 }), true);
  assert.equal(pointInEllipse(100, 125, { cx: 100, cy: 100, rx: 50, ry: 20 }), false);
  assert.equal(pointInEllipse(100, 140, { cx: 100, cy: 100, rx: 50, ry: 20, rot: Math.PI / 2 }), true);
  const tri = [[0, 100], [50, 0], [100, 100]];
  assert.equal(pointInPolygon(50, 60, tri), true);
  assert.equal(pointInPolygon(5, 5, tri), false);
  const dart = [[0, 0], [50, 30], [100, 0], [50, 100]];   // concave at (50, 30)
  assert.equal(pointInPolygon(50, 10, dart), false);
  assert.equal(pointInPolygon(50, 60, dart), true);
  const strokes = [
    { id: 'big', shape: { kind: 'ellipse', cx: 50, cy: 50, rx: 50, ry: 50 }, points: [] },
    { id: 'tri', shape: { kind: 'polygon', name: 'triangle' }, points: [[30, 70, 0.5, 0], [50, 30, 0.5, 0], [70, 70, 0.5, 0], [30, 70, 0.5, 0]] },
    { id: 'ink', points: [[50, 50, 0.5, 0], [60, 60, 0.5, 0]] }
  ];
  assert.equal(closedShapeAt(strokes, 50, 60).id, 'tri', 'topmost closed shape');
  assert.equal(closedShapeAt(strokes, 10, 50).id, 'big');
  assert.equal(closedShapeAt(strokes, 200, 200), null);
  assert.equal(closedShapeAt([{ ...strokes[0], anchor: { pageIndex: 1 } }], 50, 50, 0), null, 'other page');
});

test('P9: lasso freeform and boxed catch strokes with half their points inside; groups come along', () => {
  const strokes = [
    { id: 'a', points: [[10, 10], [20, 20]] },
    { id: 'b', points: [[90, 90], [200, 200], [210, 210]] },   // 1 of 3 inside: not caught
    { id: 'c', points: [[300, 300], [310, 310]], group: 'g' },
    { id: 'd', points: [[30, 30], [40, 40]], group: 'g' }
  ];
  const box = [[0, 0], [100, 100]];
  assert.deepEqual(selectInLasso(strokes, box, 'boxed'), ['a', 'c', 'd']);
  const tri = [[0, 0], [100, 0], [0, 100]];
  assert.deepEqual(selectInLasso(strokes, tri, 'freeform'), ['a', 'c', 'd']);
  assert.deepEqual(selectInLasso(strokes, [[500, 500], [600, 500], [600, 600]], 'freeform'), []);
  assert.deepEqual(expandGroups(strokes, ['c']), ['c', 'd']);
});

test('P10: move, scale, rotate and mirror transform points and shapes exactly', () => {
  const s = { id: 's', points: [[0, 0, 0.7, 5], [10, 0, 0.7, 6]], width: 3 };
  assert.deepEqual(transformStroke(s, translate(5, 7)).points, [[5, 7, 0.7, 5], [15, 7, 0.7, 6]]);
  const sc = transformStroke(s, scaleAbout(2, 0, 0));
  assert.deepEqual(sc.points.map(p => p.slice(0, 2)), [[0, 0], [20, 0]]);
  assert.equal(sc.width, 3, 'width kept');
  const r = transformStroke(s, rotateAbout(Math.PI / 2, 0, 0));
  assert.ok(near(r.points[1][0], 0) && near(r.points[1][1], 10));
  assert.deepEqual(transformStroke(s, mirrorH(20)).points.map(p => p.slice(0, 2)), [[40, 0], [30, 0]]);
  assert.deepEqual(transformStroke(s, mirrorV(5)).points.map(p => p.slice(0, 2)), [[0, 10], [10, 10]]);
  const m = compose(translate(1, 0), scaleAbout(2, 0, 0));
  assert.deepEqual(transformStroke(s, m).points[1].slice(0, 2), [21, 0]);

  const e = { id: 'e', points: [], shape: { kind: 'ellipse', cx: 10, cy: 0, rx: 20, ry: 10 } };
  const er = transformStroke(e, rotateAbout(Math.PI / 4, 0, 0)).shape;
  assert.ok(near(er.rot, Math.PI / 4) && near(er.rx, 20) && near(er.ry, 10));
  assert.ok(near(er.cx, 10 / Math.SQRT2) && near(er.cy, 10 / Math.SQRT2));
  const es = transformStroke(e, scaleAbout(0.5, 0, 0)).shape;
  assert.ok(near(es.rx, 10) && near(es.ry, 5) && es.rot === undefined);
  const em = transformStroke({ ...e, shape: { ...e.shape, rot: 0.3 } }, mirrorH(0)).shape;
  assert.ok(near(em.rot, -0.3) && near(em.cx, -10));
  const l = { id: 'l', points: [], shape: { kind: 'line', x1: 0, y1: 0, x2: 10, y2: 0 } };
  assert.deepEqual(transformStroke(l, translate(1, 2)).shape, { kind: 'line', x1: 1, y1: 2, x2: 11, y2: 2 });
  const b = strokesBounds([e, s]);
  assert.deepEqual([b.minX, b.minY, b.maxX, b.maxY], [-10, -10, 30, 10]);
});

test('P11: duplicate gives new ids, offsets by 16, keeps copies grouped together; group toggles', () => {
  let n = 0;
  const strokes = [
    { id: 'a', at: 1, points: [[0, 0, 0.5, 0]], group: 'g' },
    { id: 'b', at: 2, points: [[5, 5, 0.5, 0]], group: 'g', edited: 9 }
  ];
  const d = duplicateStrokes(strokes, 16, 16, () => `id${++n}`, 1000);
  assert.deepEqual(d.map(s => s.points[0].slice(0, 2)), [[16, 16], [21, 21]]);
  assert.ok(d.every(s => !['a', 'b'].includes(s.id)));
  assert.equal(d[0].group, d[1].group);
  assert.notEqual(d[0].group, 'g');
  assert.equal('edited' in d[1], false);
  assert.ok(d[0].at < d[1].at);
  const ungrouped = toggleGroup(strokes, 'x');
  assert.ok(ungrouped.every(s => !('group' in s)), 'one group → ungroup');
  const grouped = toggleGroup([{ id: 'a', points: [] }, { id: 'b', points: [], group: 'g' }], 'x');
  assert.ok(grouped.every(s => s.group === 'x'), 'mixed → one new group');
});

test('P12: style applies width, line style, colour, and fill only to closed shapes', () => {
  const strokes = [
    { id: 'p', tool: 'pen', points: [[0, 0]] },
    { id: 'e', tool: 'pen', points: [], shape: { kind: 'ellipse', cx: 0, cy: 0, rx: 1, ry: 1 } }
  ];
  const out = applyStyle(strokes, { width: 4, style: 'dashed', color: '#ff0000', fill: '#00ff00' });
  assert.equal(out[0].width, 4);
  assert.equal(out[0].style, 'dashed');
  assert.equal(out[0].color, '#ff0000');
  assert.equal('fill' in out[0], false, 'open ink takes no fill');
  assert.equal(out[1].fill, '#00ff00');
  assert.equal('fill' in applyStyle(out, { fill: null })[1], false, 'None clears the fill');
  assert.equal(applyStyle(strokes, { style: 'wavy' })[0].style, undefined, 'unknown style ignored');
  assert.equal(strokeStyleOf({ tool: 'pen' }), 'pressure');
  assert.equal(strokeStyleOf({ tool: 'highlighter' }), 'solid');
  assert.equal(dashFor('dashed', 2), '6 4');
  assert.equal(dashFor('solid', 2), '');
});

test('UI-04: merge keeps the later edit of a stroke, files without new fields merge as before', () => {
  const local = { strokes: [{ id: 's', at: 1, edited: 50, points: [[1, 1]] }], removed: [] };
  const remote = { strokes: [{ id: 's', at: 1, points: [[0, 0]] }], removed: [] };
  assert.deepEqual(mergeInkDocuments(local, remote).strokes[0].points, [[1, 1]]);
  assert.deepEqual(mergeInkDocuments(remote, local).strokes[0].points, [[1, 1]]);
  const old = { strokes: [{ id: 's', at: 1, points: [[0, 0]] }], removed: [] };
  const old2 = { strokes: [{ id: 's', at: 2, points: [[2, 2]] }], removed: [] };
  assert.deepEqual(mergeInkDocuments(old, old2).strokes[0].points, [[2, 2]]);
});
