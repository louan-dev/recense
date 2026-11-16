// Derived from Spec: UI-04 P7–P12 — pure ink geometry: polygon fit for hold-to-snap, closed-shape hit tests (fill),
// lasso selection, selection transforms (move/scale/rotate/mirror), duplicate, group and style.
// Points are [x, y, pressure, t]. No DOM here; every function is unit-tested.

const DEG = Math.PI / 180;

// ---------- small helpers ----------

export function boundsOf(points) {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const p of points || []) {
    if (p[0] < minX) minX = p[0];
    if (p[0] > maxX) maxX = p[0];
    if (p[1] < minY) minY = p[1];
    if (p[1] > maxY) maxY = p[1];
  }
  if (minX === Infinity) return { minX: 0, minY: 0, maxX: 0, maxY: 0, w: 0, h: 0 };
  return { minX, minY, maxX, maxY, w: maxX - minX, h: maxY - minY };
}

function distToSeg(px, py, a, b) {
  const dx = b[0] - a[0], dy = b[1] - a[1];
  const l2 = dx * dx + dy * dy;
  let t = l2 ? ((px - a[0]) * dx + (py - a[1]) * dy) / l2 : 0;
  t = Math.max(0, Math.min(1, t));
  return Math.hypot(px - (a[0] + t * dx), py - (a[1] + t * dy));
}

function rdp(pts, eps) {
  if (pts.length < 3) return pts.slice();
  const a = pts[0], b = pts[pts.length - 1];
  let idx = -1, max = 0;
  for (let i = 1; i < pts.length - 1; i++) {
    const d = distToSeg(pts[i][0], pts[i][1], a, b);
    if (d > max) { max = d; idx = i; }
  }
  if (max <= eps) return [a, b];
  const left = rdp(pts.slice(0, idx + 1), eps);
  const right = rdp(pts.slice(idx), eps);
  return left.slice(0, -1).concat(right);
}

/** Corners of a closed loop (Douglas–Peucker on the loop, then near-straight corners dropped). [[x, y], ...] */
export function closedCorners(points, eps) {
  const pts = points.map(p => [p[0], p[1]]);
  if (pts.length < 4) return pts;
  // Split the loop at the point farthest from the start, so both halves are open chains.
  let k = 1, far = 0;
  for (let i = 1; i < pts.length; i++) {
    const d = Math.hypot(pts[i][0] - pts[0][0], pts[i][1] - pts[0][1]);
    if (d > far) { far = d; k = i; }
  }
  const a = rdp(pts.slice(0, k + 1), eps);
  const b = rdp(pts.slice(k).concat([pts[0]]), eps);
  let corners = a.slice(0, -1).concat(b.slice(0, -1));
  // Drop corners closer than eps to the previous one, then corners that barely turn (the loop's start, mid-edge).
  let changed = true;
  while (changed && corners.length > 3) {
    changed = false;
    for (let i = 0; i < corners.length; i++) {
      const prev = corners[(i - 1 + corners.length) % corners.length];
      const cur = corners[i];
      const next = corners[(i + 1) % corners.length];
      const close = Math.hypot(cur[0] - prev[0], cur[1] - prev[1]) < eps;
      const turn = Math.abs(turnAngle(prev, cur, next));
      if (close || turn < 25 * DEG) {
        corners.splice(i, 1);
        changed = true;
        break;
      }
    }
  }
  return corners;
}

// Signed turn at b going a → b → c (0 = straight on).
function turnAngle(a, b, c) {
  const a1 = Math.atan2(b[1] - a[1], b[0] - a[0]);
  const a2 = Math.atan2(c[1] - b[1], c[0] - b[0]);
  let d = a2 - a1;
  while (d > Math.PI) d -= 2 * Math.PI;
  while (d < -Math.PI) d += 2 * Math.PI;
  return d;
}

// Interior angle at b (radians, 0..π).
function interiorAngle(a, b, c) {
  const v1 = [a[0] - b[0], a[1] - b[1]], v2 = [c[0] - b[0], c[1] - b[1]];
  const n = Math.hypot(...v1) * Math.hypot(...v2);
  if (!n) return Math.PI;
  return Math.acos(Math.max(-1, Math.min(1, (v1[0] * v2[0] + v1[1] * v2[1]) / n)));
}

function dirAngle(a, b) { return Math.atan2(b[1] - a[1], b[0] - a[0]); }

// Angle between two undirected lines, 0..π/2.
function lineGap(t1, t2) {
  let d = Math.abs(t1 - t2) % Math.PI;
  return d > Math.PI / 2 ? Math.PI - d : d;
}

function polygonError(points, corners) {
  let sum = 0;
  for (const p of points) {
    let best = Infinity;
    for (let i = 0; i < corners.length; i++) {
      const d = distToSeg(p[0], p[1], corners[i], corners[(i + 1) % corners.length]);
      if (d < best) best = d;
    }
    sum += best;
  }
  return sum / Math.max(1, points.length);
}

function ellipseError(points, b) {
  const cx = (b.minX + b.maxX) / 2, cy = (b.minY + b.maxY) / 2;
  const rx = Math.max(1, b.w / 2), ry = Math.max(1, b.h / 2);
  let sum = 0;
  for (const p of points) {
    const r = Math.hypot((p[0] - cx) / rx, (p[1] - cy) / ry);
    sum += Math.abs(r - 1) * (rx + ry) / 2;
  }
  return sum / Math.max(1, points.length);
}

// ---------- P7: polygon fit ----------

export const POLY_EPS_FRAC = 0.07;
export const AXIS_SNAP_DEG = 8;

// Make sides near horizontal/vertical exactly so, by moving corners (each corner keeps the mean of its claims).
function squareUp(corners) {
  const out = corners.map(c => [c[0], c[1]]);
  const n = out.length;
  for (let i = 0; i < n; i++) {
    const a = out[i], b = out[(i + 1) % n];
    const t = lineGap(dirAngle(a, b), 0);
    if (t <= AXIS_SNAP_DEG * DEG) { const y = (a[1] + b[1]) / 2; a[1] = y; b[1] = y; }
    else if (lineGap(dirAngle(a, b), Math.PI / 2) <= AXIS_SNAP_DEG * DEG) { const x = (a[0] + b[0]) / 2; a[0] = x; b[0] = x; }
  }
  return out;
}

function rectFrom(corners) {
  // Rotation from the longest side; then the minimal rectangle in that frame.
  let best = 0, theta = 0;
  for (let i = 0; i < 4; i++) {
    const a = corners[i], b = corners[(i + 1) % 4];
    const l = Math.hypot(b[0] - a[0], b[1] - a[1]);
    if (l > best) { best = l; theta = dirAngle(a, b); }
  }
  if (lineGap(theta, 0) <= AXIS_SNAP_DEG * DEG || lineGap(theta, Math.PI / 2) <= AXIS_SNAP_DEG * DEG) theta = 0;
  const c = Math.cos(theta), s = Math.sin(theta);
  const loc = corners.map(p => [p[0] * c + p[1] * s, -p[0] * s + p[1] * c]);
  const b = boundsOf(loc);
  const box = [[b.minX, b.minY], [b.maxX, b.minY], [b.maxX, b.maxY], [b.minX, b.maxY]];
  return box.map(([u, v]) => [u * c - v * s, u * s + v * c]);
}

function tidyTrapezoid(corners, pairIdx) {
  // pairIdx: index i such that side i (i→i+1) is parallel to side i+2.
  let q = corners.map(c => [c[0], c[1]]);
  q = squareUp(q);
  const n = 4;
  const s1 = [q[pairIdx], q[(pairIdx + 1) % n]];
  const s2 = [q[(pairIdx + 2) % n], q[(pairIdx + 3) % n]];
  const horizontal = Math.abs(s1[0][1] - s1[1][1]) < 1e-9 && Math.abs(s2[0][1] - s2[1][1]) < 1e-9;
  if (horizontal) {
    const leg1 = Math.hypot(q[(pairIdx + 1) % n][0] - q[(pairIdx + 2) % n][0], q[(pairIdx + 1) % n][1] - q[(pairIdx + 2) % n][1]);
    const leg2 = Math.hypot(q[(pairIdx + 3) % n][0] - q[pairIdx][0], q[(pairIdx + 3) % n][1] - q[pairIdx][1]);
    if (Math.abs(leg1 - leg2) <= 0.2 * Math.max(leg1, leg2)) {
      // Isosceles: both parallel sides centred on one vertical axis.
      const cx = (s1[0][0] + s1[1][0] + s2[0][0] + s2[1][0]) / 4;
      for (const side of [[pairIdx, (pairIdx + 1) % n], [(pairIdx + 2) % n, (pairIdx + 3) % n]]) {
        const [i, j] = side;
        const half = Math.abs(q[j][0] - q[i][0]) / 2;
        const sign = q[j][0] >= q[i][0] ? 1 : -1;
        q[i][0] = cx - sign * half;
        q[j][0] = cx + sign * half;
      }
    }
  }
  return q;
}

/**
 * Fits a closed loop to a triangle, right triangle, rectangle, trapezoid, quadrilateral or pentagon.
 * Returns { name, corners: [[x, y], ...] } or null when the loop reads better as an ellipse (or isn't a polygon).
 */
export function fitPolygon(points) {
  if (!Array.isArray(points) || points.length < 4) return null;
  const b = boundsOf(points);
  const size = Math.max(b.w, b.h);
  if (!(size > 0)) return null;
  const corners = closedCorners(points, POLY_EPS_FRAC * size);
  const n = corners.length;
  if (n < 3 || n > 5) return null;
  const pe = polygonError(points, corners);
  const ee = ellipseError(points, b);
  if (!(pe < 0.6 * ee)) return null;
  // Too flat to be a polygon (a doubled-back line).
  if (Math.min(b.w, b.h) < 0.12 * size) return null;

  const angles = corners.map((c, i) => interiorAngle(corners[(i - 1 + n) % n], c, corners[(i + 1) % n]));

  if (n === 3) {
    const right = angles.findIndex(a => Math.abs(a - Math.PI / 2) <= 12 * DEG);
    if (right >= 0) {
      // Legs along the axes when they nearly are: the right-angle corner shares x with one end, y with the other.
      const q = corners.map(c => [c[0], c[1]]);
      const r = q[right], p1 = q[(right + 1) % 3], p2 = q[(right + 2) % 3];
      const t = dirAngle(r, p1);
      if (lineGap(t, 0) <= AXIS_SNAP_DEG * DEG || lineGap(t, Math.PI / 2) <= AXIS_SNAP_DEG * DEG) {
        if (lineGap(t, 0) <= AXIS_SNAP_DEG * DEG) { p1[1] = r[1]; p2[0] = r[0]; }
        else { p1[0] = r[0]; p2[1] = r[1]; }
      } else {
        // Keep the leg r→p1, set p2 perpendicular at its own length.
        const l2 = Math.hypot(p2[0] - r[0], p2[1] - r[1]);
        const side = Math.sign(turnAngle(p1, r, p2)) || 1;
        const tt = t - side * Math.PI / 2;
        p2[0] = r[0] + l2 * Math.cos(tt);
        p2[1] = r[1] + l2 * Math.sin(tt);
      }
      return { name: 'right-triangle', corners: q };
    }
    return { name: 'triangle', corners: squareUp(corners) };
  }

  if (n === 4) {
    if (angles.every(a => Math.abs(a - Math.PI / 2) <= 15 * DEG)) {
      return { name: 'rectangle', corners: rectFrom(corners) };
    }
    const g0 = lineGap(dirAngle(corners[0], corners[1]), dirAngle(corners[2], corners[3]));
    const g1 = lineGap(dirAngle(corners[1], corners[2]), dirAngle(corners[3], corners[0]));
    if (Math.min(g0, g1) <= 12 * DEG) {
      return { name: 'trapezoid', corners: tidyTrapezoid(corners, g0 <= g1 ? 0 : 1) };
    }
    return { name: 'quad', corners: squareUp(corners) };
  }

  // n === 5: regular when every corner sits near the mean radius.
  const cx = corners.reduce((s, c) => s + c[0], 0) / 5;
  const cy = corners.reduce((s, c) => s + c[1], 0) / 5;
  const radii = corners.map(c => Math.hypot(c[0] - cx, c[1] - cy));
  const mean = radii.reduce((s, r) => s + r, 0) / 5;
  if (radii.every(r => Math.abs(r - mean) <= 0.25 * mean)) {
    // Orientation from the corner nearest to straight up, so a "house" pentagon stands upright.
    const top = corners.reduce((best, c) => (c[1] < best[1] ? c : best), corners[0]);
    let a0 = Math.atan2(top[1] - cy, top[0] - cx);
    if (Math.abs(a0 + Math.PI / 2) <= 10 * DEG) a0 = -Math.PI / 2;
    const dir = Math.sign(turnAngle(corners[0], corners[1], corners[2])) || 1;
    const out = [];
    for (let i = 0; i < 5; i++) {
      const a = a0 + dir * i * 2 * Math.PI / 5;
      out.push([cx + mean * Math.cos(a), cy + mean * Math.sin(a)]);
    }
    return { name: 'pentagon', corners: out };
  }
  return { name: 'pentagon', corners: corners.map(c => [c[0], c[1]]) };
}

/** The stroke points for a polygon: its corners plus the first again (old builds then draw it closed). */
export function polygonPoints(corners, pressure = 0.5, t0 = 0, t1 = t0) {
  const n = corners.length;
  const pts = corners.map((c, i) => [c[0], c[1], pressure, t0 + ((t1 - t0) * i) / n]);
  pts.push([corners[0][0], corners[0][1], pressure, t1]);
  return pts;
}

/** A polygon stroke's corners (its points without the repeated closing corner). */
export function polygonCorners(stroke) {
  const pts = stroke?.points || [];
  if (pts.length > 1) {
    const a = pts[0], z = pts[pts.length - 1];
    if (Math.abs(a[0] - z[0]) < 1e-6 && Math.abs(a[1] - z[1]) < 1e-6) return pts.slice(0, -1);
  }
  return pts.slice();
}

/** Handle points for a snapped stroke: polygon corners, or a line's two ends. [[x, y], ...] */
export function shapeHandles(stroke) {
  if (stroke?.shape?.kind === 'polygon') return polygonCorners(stroke).map(p => [p[0], p[1]]);
  if (stroke?.shape?.kind === 'line') return [[stroke.shape.x1, stroke.shape.y1], [stroke.shape.x2, stroke.shape.y2]];
  return [];
}

/** Moves handle i of a polygon or line stroke to (x, y); returns a new stroke. */
export function moveHandle(stroke, i, x, y) {
  const s = cloneStroke(stroke);
  if (s.shape?.kind === 'line') {
    if (i === 0) { s.shape.x1 = x; s.shape.y1 = y; s.points[0] = [x, y, ...s.points[0].slice(2)]; }
    else { s.shape.x2 = x; s.shape.y2 = y; const k = s.points.length - 1; s.points[k] = [x, y, ...s.points[k].slice(2)]; }
    return s;
  }
  if (s.shape?.kind === 'polygon') {
    const closed = polygonCorners(stroke).length !== s.points.length;
    s.points[i] = [x, y, ...s.points[i].slice(2)];
    if (closed && i === 0) s.points[s.points.length - 1] = [x, y, ...s.points[s.points.length - 1].slice(2)];
  }
  return s;
}

// ---------- P8: closed-shape hit test ----------

export function pointInPolygon(x, y, poly) {
  let inside = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const xi = poly[i][0], yi = poly[i][1], xj = poly[j][0], yj = poly[j][1];
    if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

export function pointInEllipse(x, y, { cx, cy, rx, ry, rot = 0 }) {
  const c = Math.cos(-rot), s = Math.sin(-rot);
  const dx = x - cx, dy = y - cy;
  const u = dx * c - dy * s, v = dx * s + dy * c;
  return (u * u) / (rx * rx) + (v * v) / (ry * ry) <= 1;
}

export function isClosedShape(stroke) {
  return stroke?.shape?.kind === 'ellipse' || stroke?.shape?.kind === 'polygon';
}

export function pointInStroke(stroke, x, y) {
  if (stroke?.shape?.kind === 'ellipse') return pointInEllipse(x, y, stroke.shape);
  if (stroke?.shape?.kind === 'polygon') return pointInPolygon(x, y, polygonCorners(stroke));
  return false;
}

/** The topmost closed shape (on pageIndex, when given) under (x, y), or null. */
export function closedShapeAt(strokes, x, y, pageIndex = null) {
  for (let i = (strokes || []).length - 1; i >= 0; i--) {
    const s = strokes[i];
    if (pageIndex !== null && s.anchor && typeof s.anchor.pageIndex === 'number' && s.anchor.pageIndex !== pageIndex) continue;
    if (isClosedShape(s) && pointInStroke(s, x, y)) return s;
  }
  return null;
}

// ---------- P9: lasso ----------

/**
 * Ids of the strokes caught by a lasso. mode 'freeform': the loop (closed by its chord);
 * 'boxed': the rectangle spanned by the drag. A stroke is caught when at least half its sample points are inside.
 * Selecting one stroke of a group selects the whole group.
 */
export function selectInLasso(strokes, lasso, mode = 'freeform', pageIndex = null) {
  if (!Array.isArray(lasso) || lasso.length < 2) return [];
  let inside;
  if (mode === 'boxed') {
    const b = boundsOf(lasso);
    inside = (x, y) => x >= b.minX && x <= b.maxX && y >= b.minY && y <= b.maxY;
  } else {
    if (lasso.length < 3) return [];
    inside = (x, y) => pointInPolygon(x, y, lasso);
  }
  const ids = [];
  for (const s of strokes || []) {
    if (pageIndex !== null && s.anchor && typeof s.anchor.pageIndex === 'number' && s.anchor.pageIndex !== pageIndex) continue;
    const pts = s.points || [];
    if (!pts.length) continue;
    const hits = pts.filter(p => inside(p[0], p[1])).length;
    if (hits * 2 >= pts.length) ids.push(s.id);
  }
  return expandGroups(strokes, ids);
}

/** Adds every member of any group already touched by ids. */
export function expandGroups(strokes, ids) {
  const set = new Set(ids);
  const groups = new Set((strokes || []).filter(s => set.has(s.id) && s.group).map(s => s.group));
  if (!groups.size) return [...set];
  for (const s of strokes) if (s.group && groups.has(s.group)) set.add(s.id);
  return (strokes || []).filter(s => set.has(s.id)).map(s => s.id);
}

// ---------- P10: transforms ----------
// A 2-D affine matrix [a, b, c, d, e, f]: x' = a·x + c·y + e, y' = b·x + d·y + f.

export const IDENTITY = [1, 0, 0, 1, 0, 0];
export function translate(dx, dy) { return [1, 0, 0, 1, dx, dy]; }
export function scaleAbout(s, ox, oy) { return [s, 0, 0, s, ox - s * ox, oy - s * oy]; }
export function rotateAbout(theta, ox, oy) {
  const c = Math.cos(theta), s = Math.sin(theta);
  return [c, s, -s, c, ox - c * ox + s * oy, oy - s * ox - c * oy];
}
export function mirrorH(cx) { return [-1, 0, 0, 1, 2 * cx, 0]; }
export function mirrorV(cy) { return [1, 0, 0, -1, 0, 2 * cy]; }
/** m2 after m1. */
export function compose(m2, m1) {
  const [a1, b1, c1, d1, e1, f1] = m1, [a2, b2, c2, d2, e2, f2] = m2;
  return [
    a2 * a1 + c2 * b1, b2 * a1 + d2 * b1,
    a2 * c1 + c2 * d1, b2 * c1 + d2 * d1,
    a2 * e1 + c2 * f1 + e2, b2 * e1 + d2 * f1 + f2
  ];
}
export function applyPoint(m, x, y) { return [m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]]; }

export function cloneStroke(s) {
  return {
    ...s,
    points: (s.points || []).map(p => [...p]),
    anchor: s.anchor ? { ...s.anchor } : s.anchor ?? null,
    shape: s.shape ? { ...s.shape } : s.shape ?? null
  };
}

/** A copy of the stroke with m applied to its points and shape (widths kept). */
export function transformStroke(stroke, m) {
  const s = cloneStroke(stroke);
  s.points = s.points.map(p => { const [x, y] = applyPoint(m, p[0], p[1]); return [x, y, ...p.slice(2)]; });
  const sh = s.shape;
  if (sh?.kind === 'line') {
    [sh.x1, sh.y1] = applyPoint(m, sh.x1, sh.y1);
    [sh.x2, sh.y2] = applyPoint(m, sh.x2, sh.y2);
  } else if (sh?.kind === 'ellipse') {
    [sh.cx, sh.cy] = applyPoint(m, sh.cx, sh.cy);
    const rot = sh.rot || 0;
    const ux = Math.cos(rot), uy = Math.sin(rot);
    const vx = -Math.sin(rot), vy = Math.cos(rot);
    const au = [m[0] * ux + m[2] * uy, m[1] * ux + m[3] * uy];
    const av = [m[0] * vx + m[2] * vy, m[1] * vx + m[3] * vy];
    sh.rx = sh.rx * Math.hypot(...au);
    sh.ry = sh.ry * Math.hypot(...av);
    let r = Math.atan2(au[1], au[0]);
    // An ellipse is symmetric under a half turn: keep rot in (-π/2, π/2], 0 when (nearly) axis-aligned.
    while (r > Math.PI / 2) r -= Math.PI;
    while (r <= -Math.PI / 2) r += Math.PI;
    if (Math.abs(r) < 1e-9) r = 0;
    if (r) sh.rot = r; else delete sh.rot;
  }
  return s;
}

export function strokesBounds(strokes) {
  const pts = [];
  for (const s of strokes || []) {
    if (s.shape?.kind === 'ellipse') {
      const { cx, cy, rx, ry, rot = 0 } = s.shape;
      const ex = Math.hypot(rx * Math.cos(rot), ry * Math.sin(rot));
      const ey = Math.hypot(rx * Math.sin(rot), ry * Math.cos(rot));
      pts.push([cx - ex, cy - ey], [cx + ex, cy + ey]);
    } else {
      for (const p of s.points || []) pts.push(p);
    }
  }
  return boundsOf(pts);
}

// ---------- P11: duplicate, group ----------

let idSeq = 0;
export function newStrokeId(now = Date.now()) {
  idSeq = (idSeq + 1) % 1e6;
  return `stroke-${now}-${idSeq.toString(36)}${Math.random().toString(36).slice(2, 6)}`;
}

/** Copies with fresh ids, moved by (dx, dy); groups get fresh ids too (copies stay grouped together). */
export function duplicateStrokes(strokes, dx = 16, dy = 16, makeId = newStrokeId, now = Date.now()) {
  const groupMap = new Map();
  return (strokes || []).map((s, i) => {
    const c = transformStroke(s, translate(dx, dy));
    c.id = makeId(now);
    c.at = now + i * 1e-3;   // keep their order, above everything older
    delete c.edited;
    if (s.group) {
      if (!groupMap.has(s.group)) groupMap.set(s.group, `group-${makeId(now)}`);
      c.group = groupMap.get(s.group);
    }
    return c;
  });
}

/** Group ids (all one fresh group id), or ungroup when they already are exactly one group. Returns new strokes. */
export function toggleGroup(strokes, groupId) {
  const gs = new Set((strokes || []).map(s => s.group || null));
  const ungroup = gs.size === 1 && !gs.has(null);
  return (strokes || []).map(s => {
    const c = cloneStroke(s);
    if (ungroup) delete c.group; else c.group = groupId;
    return c;
  });
}

// ---------- P12: style ----------

export const STROKE_STYLES = ['solid', 'pressure', 'dashed', 'dotted'];
export const FILL_OPACITY = 0.35;

/** Applies { width, style, color, fill } (any subset; fill null = none) to copies of the strokes. */
export function applyStyle(strokes, change = {}) {
  return (strokes || []).map(s => {
    const c = cloneStroke(s);
    if (typeof change.width === 'number' && change.width > 0) c.width = change.width;
    if (STROKE_STYLES.includes(change.style)) c.style = change.style;
    if (typeof change.color === 'string') c.color = change.color;
    if ('fill' in change && isClosedShape(c)) {
      if (change.fill) c.fill = change.fill; else delete c.fill;
    }
    return c;
  });
}

/** The stroke's effective style: its own, or its tool's default (pen: pressure; others: solid). */
export function strokeStyleOf(stroke) {
  if (STROKE_STYLES.includes(stroke?.style)) return stroke.style;
  return stroke?.tool === 'pen' && !stroke?.shape ? 'pressure' : 'solid';
}

/** SVG stroke-dasharray for a style at width w ('' for none). */
export function dashFor(style, w) {
  if (style === 'dashed') return `${3 * w} ${2 * w}`;
  if (style === 'dotted') return `0.01 ${2 * w}`;
  return '';
}
