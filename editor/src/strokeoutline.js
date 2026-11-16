// Derived from Spec: UI-04 P5 / T-0094 (F0). A pen stroke is a filled outline whose width follows pressure,
// not a constant-width line. Pure geometry: points are [x, y, pressure, time].
export const WIDTH_MIN = 0.25;   // × base width, at the lightest touch
export const WIDTH_MAX = 1.6;    // × base width, at the heaviest

/** Width at pressure p: pressure 0.5 (the default) draws the base width. */
export function widthAt(base, p) {
  const q = typeof p === 'number' && p > 0 ? p : 0.5;
  return base * Math.min(WIDTH_MAX, Math.max(WIDTH_MIN, q * 2));
}

/** SVG path data of the filled outline, or '' for fewer than 2 distinct points. */
export function outlinePath(points, base) {
  const pts = [];
  for (const p of points) {
    const last = pts[pts.length - 1];
    if (!last || Math.hypot(p[0] - last[0], p[1] - last[1]) > 0.01) pts.push(p);
  }
  if (pts.length < 2) return '';
  const n = pts.length;
  const left = [], right = [], r = [];
  for (let i = 0; i < n; i++) {
    const a = pts[Math.max(0, i - 1)], b = pts[Math.min(n - 1, i + 1)];
    let dx = b[0] - a[0], dy = b[1] - a[1];
    const len = Math.hypot(dx, dy) || 1;
    dx /= len; dy /= len;
    const h = widthAt(base, pts[i][2]) / 2;
    r.push(h);
    left.push([pts[i][0] - dy * h, pts[i][1] + dx * h]);
    right.push([pts[i][0] + dy * h, pts[i][1] - dx * h]);
  }
  const f = v => v.toFixed(2);
  let d = `M ${f(left[0][0])} ${f(left[0][1])}`;
  for (let i = 1; i < n; i++) d += ` L ${f(left[i][0])} ${f(left[i][1])}`;
  d += ` A ${f(r[n - 1])} ${f(r[n - 1])} 0 0 0 ${f(right[n - 1][0])} ${f(right[n - 1][1])}`;
  for (let i = n - 2; i >= 0; i--) d += ` L ${f(right[i][0])} ${f(right[i][1])}`;
  d += ` A ${f(r[0])} ${f(r[0])} 0 0 0 ${f(left[0][0])} ${f(left[0][1])} Z`;
  return d;
}
