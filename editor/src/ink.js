// Notability-style line-anchored ink whiteboard.
// Line-anchored plain JSON storage, shape snapping, whole/partial erasers,
// and CRDT-safe multi-device merge.

import { nextPressure } from './pressure.js';
import { createPalmGate, isTinyStroke, isBrush } from './palm.js';
import { outlinePath } from './strokeoutline.js';
import { createRadialMenu } from './radialmenu.js';
import {
  fitPolygon, polygonPoints, polygonCorners, strokeStyleOf, dashFor, FILL_OPACITY,
  shapeHandles, moveHandle, closedShapeAt
} from './inkshapes.js';
import { createInkSelection, LASSO_MODES, HANDLE_HIT } from './inkselection.js';

export const INK_TOOLS = [
  'pen',
  'highlighter',
  'underline',
  'circle',
  'eraser-whole',
  'eraser-partial'
];

// The palette's first button: the pointer selects text and draws nothing. Underline and Circle aren't buttons
// (owner, 11-08): holding the pen still at a stroke's end already snaps it to a line or an ellipse. They stay in
// INK_TOOLS so strokes saved with them still draw. One eraser (the partial one went, owner 11-08).
export const SELECT_TOOL = 'select';
// Derived from Spec: UI-04 P9 — Lasso sits between the Highlighter and the Eraser (the wheel stays right after the eraser).
export const LASSO_TOOL = 'lasso';
export const PALETTE_TOOLS = [SELECT_TOOL, 'pen', 'highlighter', LASSO_TOOL, 'eraser-whole'];

export const INK_TOOL_NAMES = {
  select: 'Select text',
  pen: 'Pen',
  highlighter: 'Highlighter',
  lasso: 'Lasso',
  underline: 'Underline',
  circle: 'Circle',
  'eraser-whole': 'Eraser',
  'eraser-partial': 'Partial eraser'
};

// 16-px line icons in the text colour, so each tool reads at a glance.
const ICON = body =>
  `<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;
export const INK_TOOL_ICONS = {
  // A text cursor (I-beam).
  select: ICON('<path d="M6 2.5h4M6 13.5h4M8 2.5v11"/>'),
  pen: ICON('<path d="M3 13l1-3.5 7-7 2.5 2.5-7 7z"/><path d="M9.5 4l2.5 2.5"/>'),
  // A marker over a wide translucent band, unlike the pen's slim nib.
  highlighter: ICON('<path d="M2 13.5h12" stroke-width="3.5" stroke-opacity="0.45"/><path d="M6.5 10.5l3.5-7.5 3 1.5-3 7.5z"/>'),
  // A dashed loop with a tail: the lasso.
  lasso: ICON('<ellipse cx="8.5" cy="6.5" rx="5.5" ry="4" stroke-dasharray="2 1.6"/><path d="M5 10c-1 1.5-1.5 2.5-0.5 3.5"/>'),
  underline: ICON('<path d="M5 3v4a3 3 0 0 0 6 0V3"/><path d="M3 13.5h10"/>'),
  circle: ICON('<ellipse cx="8" cy="8" rx="5.5" ry="4.5"/>'),
  // A solid eraser block: wipes whole strokes.
  'eraser-whole': ICON('<path d="M6.5 13.5L2.5 9.5 9 3l4.5 4.5-6 6z" fill="currentColor" fill-opacity="0.35"/><path d="M6.5 13.5h7"/>'),
  // A stroke with a gap cut out of it: wipes only the part the pen crosses.
  'eraser-partial': ICON('<path d="M2 11c1.5-3 3-3 4-1.5"/><path d="M10 9.5c1-1.5 2.5-1.5 4 1.5"/><path d="M7.2 6.5l1.6 1.6M8.8 6.5L7.2 8.1" stroke-width="1.2"/>')
};

export const INK_COLORS = [
  '#38bdf8',
  '#facc15',
  '#4ade80',
  '#f472b6',
  '#a78bfa',
  '#fb923c',
  '#f87171',
  '#e6edf3'
];

export const DEFAULT_LINE_HEIGHT = 28;

/**
 * Handwriting groups for recognition: pen strokes not read yet, clustered by place and time (a stroke joins a group
 * when its box, grown by a line height, touches the group's and it was written within 8 s of the group's last).
 */
export function groupHandwriting(strokes, lineHeight = DEFAULT_LINE_HEIGHT) {
  const pens = (Array.isArray(strokes) ? strokes : [])
    .filter(st => st && st.tool === 'pen' && !st.ocr && Array.isArray(st.points) && st.points.length > 0)
    .sort((a, b) => (a.at || 0) - (b.at || 0));
  const boxOf = st => {
    const xs = st.points.map(p => p[0]), ys = st.points.map(p => p[1]);
    return { x0: Math.min(...xs), y0: Math.min(...ys), x1: Math.max(...xs), y1: Math.max(...ys) };
  };
  const groups = [];
  for (const st of pens) {
    const b = boxOf(st);
    const g = groups.find(gr => {
      const m = lineHeight;
      return Math.abs((st.at || 0) - gr.lastAt) <= 8000 &&
        b.x0 <= gr.box.x1 + m && b.x1 >= gr.box.x0 - m && b.y0 <= gr.box.y1 + m && b.y1 >= gr.box.y0 - m;
    });
    if (g) {
      g.strokes.push(st);
      g.lastAt = Math.max(g.lastAt, st.at || 0);
      g.box = { x0: Math.min(g.box.x0, b.x0), y0: Math.min(g.box.y0, b.y0), x1: Math.max(g.box.x1, b.x1), y1: Math.max(g.box.y1, b.y1) };
    } else {
      groups.push({ id: `ink-${st.id}`, strokes: [st], lastAt: st.at || 0, box: b });
    }
  }
  return groups;
}

/** Find in handwriting: the read groups whose text holds `query` (any case, accents ignored). */
export function findInkText(strokes, query) {
  const fold = t => String(t || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/đ/g, 'd').replace(/Đ/g, 'D').toLowerCase();
  const q = fold(query).trim();
  if (!q) return [];
  const seen = new Map();
  for (const st of Array.isArray(strokes) ? strokes : []) {
    const o = st && st.ocr;
    if (!o || !o.t || seen.has(o.g) || !fold(o.t).includes(q)) continue;
    seen.set(o.g, { id: o.g, text: o.t, stroke: st });
  }
  return [...seen.values()];
}

/** HSL (h 0-360, s and l 0-1) to #rrggbb. */
export function hslToHex(h, sat, light) {
  const k = n => (n + h / 30) % 12;
  const a = sat * Math.min(light, 1 - light);
  const f = n => light - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
  const hex = x => Math.round(Math.max(0, Math.min(1, x)) * 255).toString(16).padStart(2, '0');
  return `#${hex(f(0))}${hex(f(8))}${hex(f(4))}`;
}

/** A point on the colour wheel (centre-relative, radius R) as hue (the angle, red at the top) and saturation (out from the centre). */
export function wheelColor(dx, dy, R, light = 0.5) {
  const hue = ((Math.atan2(dx, -dy) * 180) / Math.PI + 360) % 360;
  const sat = Math.min(1, Math.hypot(dx, dy) / R);
  return hslToHex(hue, sat, light);
}

/** How far each eraser reaches from the pointer, in page points; the eraser's ring is drawn at exactly this size. */
export const ERASER_RADIUS = { 'eraser-whole': 12, 'eraser-partial': 10 };
export const DEFAULT_DEBOUNCE_MS = 300;

const EMBED_RE = /^\s*!\[([^\]]*)\]\((?:<([^>]+)>|([^)\s]+))\)\s*$/;

export function parseEmbedTarget(line) {
  if (typeof line !== 'string') return null;
  const m = EMBED_RE.exec(line.trim());
  if (!m) return null;
  return m[2] ?? m[3] ?? null;
}

/**
 * Deterministic fast 32-bit FNV-1a string hash for line context.
 * Captures lineText, prevLineText, and nextLineText so the anchor
 * stays stable even when other distant lines move.
 */
export function hashLineContext(lineText = '', prevLineText = '', nextLineText = '') {
  const clean = s => (typeof s === 'string' ? s.replace(/\r$/, '') : '');
  const str = `${clean(prevLineText)}\n${clean(lineText)}\n${clean(nextLineText)}`;
  let h = 2166136261 >>> 0;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 16777619) >>> 0;
  }
  return h.toString(16).padStart(8, '0');
}

/**
 * Splits document into isolated window pages demarcated by `<!-- page -->`.
 */
export function getDocumentPages(docText) {
  const rawLines = typeof docText === 'string' ? docText.split(/\r?\n/) : [''];
  const pages = [];
  let curStartLine = 1;
  let curLines = [];

  for (let i = 0; i < rawLines.length; i++) {
    const line = typeof rawLines[i] === 'string' ? rawLines[i].replace(/\r$/, '') : '';
    if (line.trim() === '<!-- page -->') {
      pages.push({
        index: pages.length,
        startLine: curStartLine,
        endLine: i,
        lines: curLines
      });
      curStartLine = i + 2;
      curLines = [];
    } else {
      curLines.push(line);
    }
  }

  pages.push({
    index: pages.length,
    startLine: curStartLine,
    endLine: rawLines.length,
    lines: curLines
  });

  return pages;
}

/**
 * Computes anchor from the stroke's top-left point and the current document lines.
 * In isolated mini-document windows, each window pageIndex starts at Y = 0 at page.startLine.
 * Stores lineIndexInPage = lineNumber - page.startLine in anchor.offsetInPage.
 */
export function anchorStrokeToDoc(
  stroke,
  docText = '',
  lineHeight = DEFAULT_LINE_HEIGHT,
  pageIndex = null
) {
  const points = stroke && Array.isArray(stroke.points) ? stroke.points : [];
  let minX = 0;
  let minY = 0;
  if (points.length > 0) {
    minX = Math.min(...points.map(p => p[0]));
    minY = Math.min(...points.map(p => p[1]));
  }

  const rawLines = typeof docText === 'string' ? docText.split(/\r?\n/) : [''];
  const pages = getDocumentPages(docText);

  let pIdx = 0;
  if (typeof pageIndex === 'number' && pageIndex >= 0) {
    pIdx = Math.min(pages.length - 1, pageIndex);
  } else if (stroke?.anchor && typeof stroke.anchor.pageIndex === 'number') {
    pIdx = Math.min(pages.length - 1, stroke.anchor.pageIndex);
  } else {
    // If minY exceeds total lines in doc, find which page contains that line
    const globalLineIdx = Math.max(0, Math.min(rawLines.length - 1, Math.floor(minY / lineHeight)));
    const targetLineNumber = globalLineIdx + 1;
    for (const p of pages) {
      if (targetLineNumber >= p.startLine && targetLineNumber <= p.endLine) {
        pIdx = p.index;
        break;
      }
    }
  }

  const targetPage = pages[pIdx] || pages[0];
  const lineCountInPage = Math.max(1, targetPage.lines.length);
  const lineIndexInPage = Math.max(0, Math.min(lineCountInPage - 1, Math.floor(minY / lineHeight)));
  const lineNumber = targetPage.startLine + lineIndexInPage;

  const lineText = targetPage.lines[lineIndexInPage] ?? '';
  const prevLineText = lineIndexInPage > 0 ? targetPage.lines[lineIndexInPage - 1] : '';
  const nextLineText = lineIndexInPage < targetPage.lines.length - 1 ? targetPage.lines[lineIndexInPage + 1] : '';

  const lineHash = hashLineContext(lineText, prevLineText, nextLineText);
  const embedTarget = parseEmbedTarget(lineText);

  const relX = minX;
  const relY = minY - lineIndexInPage * lineHeight;

  const anchor = {
    pageIndex: pIdx,
    lineHash,
    lineText,
    lineNumber,
    offsetInPage: lineIndexInPage,
    embedTarget,
    relX,
    relY
  };

  if (stroke && typeof stroke === 'object') {
    stroke.anchor = anchor;
  }
  return anchor;
}

/**
 * Re-computes vertical deltaY when lines are typed or deleted within the anchored page.
 * Matches stroke within its anchor.pageIndex (or across pages if reordered).
 * Computes deltaLines = newLineIndexInPage - (anchor.offsetInPage ?? 0) so changes
 * in earlier/later windows do NOT shift this window's ink!
 */
export function resolveStrokeAnchor(stroke, docText = '', lineHeight = DEFAULT_LINE_HEIGHT) {
  const points = stroke && Array.isArray(stroke.points) ? stroke.points : [];
  const anchor = stroke?.anchor;

  if (!anchor || typeof anchor !== 'object') {
    return {
      points: points.map(p => [...p]),
      orphaned: true,
      pageIndex: 0,
      deltaY: 0,
      shape: stroke?.shape ? { ...stroke.shape } : null
    };
  }

  const pages = getDocumentPages(docText);
  const targetPageIndex = typeof anchor.pageIndex === 'number' ? anchor.pageIndex : 0;

  function findLineInPage(p) {
    if (!p) return -1;
    // 1. embedTarget
    if (anchor.embedTarget) {
      for (let i = 0; i < p.lines.length; i++) {
        if (parseEmbedTarget(p.lines[i]) === anchor.embedTarget) return i;
      }
    }
    // 2. exact context hash
    if (anchor.lineHash) {
      for (let i = 0; i < p.lines.length; i++) {
        const prev = i > 0 ? p.lines[i - 1] : '';
        const next = i < p.lines.length - 1 ? p.lines[i + 1] : '';
        if (hashLineContext(p.lines[i], prev, next) === anchor.lineHash) return i;
      }
    }
    // 3. exact line text
    if (typeof anchor.lineText === 'string') {
      const candidates = [];
      for (let i = 0; i < p.lines.length; i++) {
        if (p.lines[i] === anchor.lineText) candidates.push(i);
      }
      if (candidates.length === 1) return candidates[0];
      if (candidates.length > 1) {
        const target = anchor.offsetInPage ?? 0;
        candidates.sort((a, b) => Math.abs(a - target) - Math.abs(b - target));
        return candidates[0];
      }
    }
    // 4. trimmed line text
    if (typeof anchor.lineText === 'string' && anchor.lineText.trim().length > 0) {
      const trimmed = anchor.lineText.trim();
      const candidates = [];
      for (let i = 0; i < p.lines.length; i++) {
        if (p.lines[i].trim() === trimmed) candidates.push(i);
      }
      if (candidates.length > 0) {
        const target = anchor.offsetInPage ?? 0;
        candidates.sort((a, b) => Math.abs(a - target) - Math.abs(b - target));
        return candidates[0];
      }
    }
    return -1;
  }

  let matchedPageIndex = targetPageIndex;
  let matchedLineIdxInPage = -1;

  if (pages[targetPageIndex]) {
    matchedLineIdxInPage = findLineInPage(pages[targetPageIndex]);
  }

  // If not found in original pageIndex, search other pages in case pages were prepended/reordered
  if (matchedLineIdxInPage === -1) {
    for (let pIdx = 0; pIdx < pages.length; pIdx++) {
      if (pIdx === targetPageIndex) continue;
      const idx = findLineInPage(pages[pIdx]);
      if (idx !== -1) {
        matchedPageIndex = pIdx;
        matchedLineIdxInPage = idx;
        break;
      }
    }
  }

  // If still not found anywhere, keep stroke orphaned at last spot
  if (matchedLineIdxInPage === -1) {
    return {
      points: points.map(p => [...p]),
      orphaned: true,
      pageIndex: targetPageIndex,
      deltaY: 0,
      shape: stroke?.shape ? { ...stroke.shape } : null
    };
  }

  const deltaLines = matchedLineIdxInPage - (anchor.offsetInPage ?? 0);
  const deltaY = deltaLines * lineHeight;
  const shiftedPoints = points.map(([x, y, p, t]) => [x, y + deltaY, p, t]);

  let updatedShape = null;
  if (stroke?.shape) {
    if (stroke.shape.kind === 'ellipse') {
      updatedShape = { ...stroke.shape, cy: stroke.shape.cy + deltaY };
    } else if (stroke.shape.kind === 'line') {
      updatedShape = {
        ...stroke.shape,
        y1: stroke.shape.y1 + deltaY,
        y2: stroke.shape.y2 + deltaY
      };
    } else {
      updatedShape = { ...stroke.shape };
    }
  }

  return {
    points: shiftedPoints,
    orphaned: false,
    pageIndex: matchedPageIndex,
    deltaY,
    shape: updatedShape
  };
}

/**
 * CRDT-safe union of strokes by id plus union of removed tombstone IDs.
 */
export function mergeInkDocuments(localDoc, remoteDoc) {
  const localStrokes = Array.isArray(localDoc?.strokes) ? localDoc.strokes : [];
  const remoteStrokes = Array.isArray(remoteDoc?.strokes) ? remoteDoc.strokes : [];
  const localRemoved = Array.isArray(localDoc?.removed) ? localDoc.removed : [];
  const remoteRemoved = Array.isArray(remoteDoc?.removed) ? remoteDoc.removed : [];

  const removedSet = new Set([...localRemoved, ...remoteRemoved]);
  const strokesById = new Map();

  for (const s of localStrokes) {
    if (s && s.id && !removedSet.has(s.id)) {
      strokesById.set(s.id, s);
    }
  }

  for (const s of remoteStrokes) {
    if (s && s.id && !removedSet.has(s.id)) {
      const existing = strokesById.get(s.id);
      if (!existing) {
        strokesById.set(s.id, s);
      } else {
        // Derived from Spec: UI-04 P7–P13 — an edited stroke (moved, styled) keeps the later edit.
        const existingAt = typeof existing.edited === 'number' ? existing.edited : typeof existing.at === 'number' ? existing.at : 0;
        const remoteAt = typeof s.edited === 'number' ? s.edited : typeof s.at === 'number' ? s.at : 0;
        if (remoteAt >= existingAt) {
          strokesById.set(s.id, s);
        }
      }
    }
  }

  const strokes = Array.from(strokesById.values());
  strokes.sort((a, b) => {
    const diff = (a.at || 0) - (b.at || 0);
    if (diff !== 0) return diff;
    return String(a.id).localeCompare(String(b.id));
  });

  return {
    version: 1,
    strokes,
    removed: Array.from(removedSet).sort()
  };
}

/**
 * Snaps a horizontal-ish stroke to a clean, level underline [ [minX, snapY, p, t], [maxX, snapY, p, t] ].
 */
export function snapUnderlineStroke(points, lineHeight = DEFAULT_LINE_HEIGHT) {
  if (!Array.isArray(points) || points.length === 0) return [];
  if (points.length === 1) {
    const pt = points[0];
    return [
      [pt[0], pt[1], pt[2] ?? 0.5, pt[3] ?? 0],
      [pt[0], pt[1], pt[2] ?? 0.5, pt[3] ?? 0]
    ];
  }

  const xs = points.map(p => p[0]);
  const ys = points.map(p => p[1]);
  const minX = Math.min(...xs);
  const maxX = Math.max(...xs);
  const avgY = ys.reduce((sum, y) => sum + y, 0) / ys.length;

  const snapY = avgY;
  const pStart = points[0][2] ?? 0.5;
  const pEnd = points[points.length - 1][2] ?? pStart;
  const tStart = points[0][3] ?? 0;
  const tEnd = points[points.length - 1][3] ?? tStart;

  return [
    [minX, snapY, pStart, tStart],
    [maxX, snapY, pEnd, tEnd]
  ];
}

// Hold the pen still this long at the end of a stroke to turn it into a shape.
export const SNAP_HOLD_MS = 500;
// Strokes smaller than this (in px, on 28-px lines) are letters and never become shapes.
export const SNAP_MIN_SIZE = 40;
// Derived from Spec: BUG-03. A fresh mount's first Pencil touch under this much movement is a
// cursor-placement tap, not a mark — well under SNAP_MIN_SIZE, which is about shape detection, not this.
export const AUTO_PEN_TAP_PX = 3;

/**
 * How long the pen stayed still (within radius px, allowing for Pencil jitter, of where it lifted) before lifting.
 * points: [[x, y, p, t], ...]; upTime: the lift's timestamp, same clock as t.
 */
export function endHoldMs(points, upTime, radius = 6) {
  if (!Array.isArray(points) || points.length === 0) return 0;
  const last = points[points.length - 1];
  let stillSince = last[3] ?? upTime;
  for (let i = points.length - 2; i >= 0; i--) {
    if (Math.hypot(points[i][0] - last[0], points[i][1] - last[1]) > radius) break;
    stillSince = points[i][3] ?? stillSince;
  }
  return Math.max(0, (upTime ?? stillSince) - stillSince);
}

/**
 * Snaps a freehand stroke to an ellipse or a line (the Circle tool always; the pen only when held at the end).
 * - forceCircle === true: always snaps to ellipse.
 * - forceCircle === false: NEVER snaps unless the pen held still at the stroke's end for
 *   holdDurationMs >= SNAP_HOLD_MS (see endHoldMs), and the stroke is bigger than a letter
 *   (SNAP_MIN_SIZE). Handwriting therefore stays handwriting.
 * - When held: a closed loop (ends meet) becomes an ellipse; a nearly straight stroke becomes a line;
 *   anything else (letters, curves, scribbles) stays as drawn.
 */
export function detectAndSnapShape(points, { holdDurationMs = 0, forceCircle = false } = {}) {
  if (!Array.isArray(points) || points.length === 0) {
    return { snapped: false, shape: null, points: [] };
  }
  if (points.length < 2) {
    return { snapped: false, shape: null, points: points.map(p => [...p]) };
  }

  const xs = points.map(p => p[0]);
  const ys = points.map(p => p[1]);
  const minX = Math.min(...xs);
  const maxX = Math.max(...xs);
  const minY = Math.min(...ys);
  const maxY = Math.max(...ys);
  const w = maxX - minX;
  const h = maxY - minY;

  let perimeter = 0;
  for (let i = 1; i < points.length; i++) {
    perimeter += Math.hypot(points[i][0] - points[i - 1][0], points[i][1] - points[i - 1][1]);
  }

  const chord = Math.hypot(
    points[points.length - 1][0] - points[0][0],
    points[points.length - 1][1] - points[0][1]
  );

  const aspect = h > 0 ? w / h : 1;
  function makeEllipse() {
    const cx = (minX + maxX) / 2;
    const cy = (minY + maxY) / 2;
    const rx = Math.max(1, w / 2);
    const ry = Math.max(1, h / 2);

    const snappedPoints = [];
    const pAvg = points.reduce((sum, p) => sum + (p[2] ?? 0.5), 0) / points.length;
    const t0 = points[0]?.[3] ?? 0;
    const t1 = points[points.length - 1]?.[3] ?? t0;

    for (let i = 0; i < 48; i++) {
      const theta = (i / 48) * (2 * Math.PI);
      const x = cx + rx * Math.cos(theta);
      const y = cy + ry * Math.sin(theta);
      const t = t0 + (t1 - t0) * (i / 48);
      snappedPoints.push([x, y, pAvg, t]);
    }

    return {
      snapped: true,
      shape: { kind: 'ellipse', cx, cy, rx, ry },
      points: snappedPoints
    };
  }

  if (forceCircle) {
    return makeEllipse();
  }

  // Draw-and-hold check: NEVER snap freehand strokes unless held still at the end,
  // and never snap anything letter-sized.
  if (holdDurationMs < SNAP_HOLD_MS || Math.max(w, h) < SNAP_MIN_SIZE) {
    return {
      snapped: false,
      shape: null,
      points: points.map(p => [...p])
    };
  }

  // Held: a closed loop (the two ends brought together) becomes a polygon (UI-04 P7) or an ellipse.
  const size = Math.max(w, h);
  // Derived from Spec: UI-04 P7 — corners first: a triangle, rectangle, trapezoid or pentagon that fits better
  // than an ellipse snaps to it. Long thin boxes are allowed here (the ellipse keeps its aspect limits).
  if (chord <= Math.max(8, 0.15 * size) && perimeter >= 2.2 * size) {
    const poly = fitPolygon(points);
    if (poly) {
      const pAvg = points.reduce((sum, p) => sum + (p[2] ?? 0.5), 0) / points.length;
      const t0 = points[0]?.[3] ?? 0;
      const t1 = points[points.length - 1]?.[3] ?? t0;
      return {
        snapped: true,
        shape: { kind: 'polygon', name: poly.name },
        points: polygonPoints(poly.corners, pAvg, t0, t1)
      };
    }
  }
  const endsJoined =
    chord <= Math.max(8, 0.15 * size) &&
    perimeter >= 2.2 * size &&
    aspect >= 0.35 &&
    aspect <= 2.8;

  if (endsJoined) {
    return makeEllipse();
  }

  // Held at one end and already nearly straight: straighten it (a held horizontal line, say).
  // A letter or a curve bends too far from the start-to-end line to pass.
  const x1 = points[0][0];
  const y1 = points[0][1];
  const x2 = points[points.length - 1][0];
  const y2 = points[points.length - 1][1];
  let maxDev = 0;
  if (chord > 0) {
    for (const pt of points) {
      const dev = Math.abs((x2 - x1) * (y1 - pt[1]) - (x1 - pt[0]) * (y2 - y1)) / chord;
      if (dev > maxDev) maxDev = dev;
    }
  }
  const nearlyStraight =
    chord >= SNAP_MIN_SIZE &&
    perimeter <= chord * 1.12 &&
    maxDev <= Math.max(5, 0.08 * chord);

  if (nearlyStraight) {
    const p1 = points[0][2] ?? 0.5;
    const p2 = points[points.length - 1][2] ?? p1;
    const t0 = points[0][3] ?? 0;
    const t1 = points[points.length - 1][3] ?? t0;
    return {
      snapped: true,
      shape: { kind: 'line', x1, y1, x2, y2 },
      points: [
        [x1, y1, p1, t0],
        [x2, y2, p2, t1]
      ]
    };
  }

  return {
    snapped: false,
    shape: null,
    points: points.map(p => [...p])
  };
}

function distToSegmentSquared(px, py, x1, y1, x2, y2) {
  const dx = x2 - x1;
  const dy = y2 - y1;
  const l2 = dx * dx + dy * dy;
  if (l2 === 0) {
    const ex = px - x1;
    const ey = py - y1;
    return ex * ex + ey * ey;
  }
  let t = ((px - x1) * dx + (py - y1) * dy) / l2;
  t = Math.max(0, Math.min(1, t));
  const cx = x1 + t * dx;
  const cy = y1 + t * dy;
  const ex = px - cx;
  const ey = py - cy;
  return ex * ex + ey * ey;
}

function strokeIntersectsEraser(stroke, eraserPoints, radius) {
  const r2 = radius * radius;
  const pts = stroke.points || [];
  if (pts.length === 0) return false;

  for (const ep of eraserPoints) {
    const epx = ep[0];
    const epy = ep[1];

    if (pts.length === 1) {
      const dx = pts[0][0] - epx;
      const dy = pts[0][1] - epy;
      if (dx * dx + dy * dy <= r2) return true;
      continue;
    }

    for (let i = 0; i < pts.length - 1; i++) {
      const d2 = distToSegmentSquared(epx, epy, pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1]);
      if (d2 <= r2) return true;
    }
  }
  return false;
}

/**
 * Removes any stroke whose segments intersect eraserPoints within radius.
 * Returns { remaining, removedIds }.
 */
export function eraseWholeStrokes(strokes, eraserPoints, radius = 12) {
  const list = Array.isArray(strokes) ? strokes : [];
  const eps = Array.isArray(eraserPoints) ? eraserPoints : [];
  const remaining = [];
  const removedIds = [];

  for (const stroke of list) {
    if (strokeIntersectsEraser(stroke, eps, radius)) {
      if (stroke.id) removedIds.push(stroke.id);
    } else {
      remaining.push(stroke);
    }
  }

  const out = { remaining, removedIds };
  out[Symbol.iterator] = function* () { yield* remaining; };
  Object.defineProperty(out, 'length', { get: () => remaining.length });
  return out;
}

function isPointInEraser(x, y, eraserPoints, radius) {
  const r2 = radius * radius;
  for (const ep of eraserPoints) {
    const dx = x - ep[0];
    const dy = y - ep[1];
    if (dx * dx + dy * dy <= r2) return true;
  }
  return false;
}

/**
 * Splits any intersected stroke at the erased points into 0, 1, or 2+ clean sub-strokes
 * (each with a fresh deterministic id and updated anchor), removing only the erased segment.
 * Returns { remaining, removedIds }.
 */
export function erasePartialStrokes(
  strokes,
  eraserPoints,
  radius = 10,
  docText = '',
  lineHeight = DEFAULT_LINE_HEIGHT,
  pageIndex = null
) {
  const list = Array.isArray(strokes) ? strokes : [];
  const eps = Array.isArray(eraserPoints) ? eraserPoints : [];
  const remaining = [];
  const removedIds = [];

  for (const stroke of list) {
    const pts = stroke.points || [];
    if (pts.length === 0) continue;

    if (!strokeIntersectsEraser(stroke, eps, radius)) {
      remaining.push(stroke);
      continue;
    }

    if (stroke.id) {
      removedIds.push(stroke.id);
    }

    const sampled = [];
    for (let i = 0; i < pts.length; i++) {
      if (i === 0) {
        sampled.push(pts[0]);
      } else {
        const p1 = pts[i - 1];
        const p2 = pts[i];
        const dist = Math.hypot(p2[0] - p1[0], p2[1] - p1[1]);
        const steps = Math.max(1, Math.ceil(dist / 3));
        for (let s = 1; s <= steps; s++) {
          const frac = s / steps;
          const x = p1[0] + (p2[0] - p1[0]) * frac;
          const y = p1[1] + (p2[1] - p1[1]) * frac;
          const p = (p1[2] ?? 0.5) + ((p2[2] ?? 0.5) - (p1[2] ?? 0.5)) * frac;
          const t = (p1[3] ?? 0) + ((p2[3] ?? 0) - (p1[3] ?? 0)) * frac;
          sampled.push([x, y, p, t]);
        }
      }
    }

    const runs = [];
    let currentRun = [];
    for (const pt of sampled) {
      if (!isPointInEraser(pt[0], pt[1], eps, radius)) {
        currentRun.push(pt);
      } else {
        if (currentRun.length > 0) {
          runs.push(currentRun);
          currentRun = [];
        }
      }
    }
    if (currentRun.length > 0) {
      runs.push(currentRun);
    }

    let subIndex = 0;
    for (const run of runs) {
      if (run.length === 0) continue;
      subIndex++;
      const subStroke = {
        ...stroke,
        id: `${stroke.id}-part-${subIndex}`,
        points: run,
        shape: null,
        at: stroke.at ?? Date.now()
      };

      if (docText) {
        anchorStrokeToDoc(subStroke, docText, lineHeight, pageIndex ?? stroke.anchor?.pageIndex);
      } else if (stroke.anchor) {
        const subMinX = Math.min(...run.map(p => p[0]));
        const subMinY = Math.min(...run.map(p => p[1]));
        const lineTopY = (stroke.anchor.offsetInPage ?? 0) * lineHeight;
        subStroke.anchor = {
          ...stroke.anchor,
          relX: subMinX,
          relY: subMinY - lineTopY
        };
      }

      remaining.push(subStroke);
    }
  }

  const out = { remaining, removedIds };
  out[Symbol.iterator] = function* () { yield* remaining; };
  Object.defineProperty(out, 'length', { get: () => remaining.length });
  return out;
}

export function getToolDefaultWidth(tool) {
  switch (tool) {
    case 'highlighter':
      return 18;
    case 'underline':
      return 3;
    case 'circle':
      return 2.5;
    case 'pen':
    default:
      return 2.5;
  }
}

/**
 * Creates and mounts the SVG ink layer and palette inside view.scrollDOM.
 */
export function createInkLayer(view, options = {}) {
  const {
    lineHeight = DEFAULT_LINE_HEIGHT,
    initialInk = null,
    debounceMs = DEFAULT_DEBOUNCE_MS,
    globalObj = typeof window !== 'undefined' ? window : null,
    onInkChange = null,
    allowMouse = true,
    getPageIndex = null,
    activePageIndex = 0,
    // Where the pill and palette float. Never the text's scroller: a child there joins
    // CodeMirror's flex row and squeezes the text column.
    mount = null,
    onToolChange = null,
    // UI-04 P2 outer ring: [{ id, label, pick() }] read when the radial menu opens (FEAT-08 matter actions).
    radialOuter = null,
    onStrokeAdded = null   // FEAT-08 #2: called with each new drawn stroke (word attachment)
  } = options;

  // Regression guard: BUG-07 — prefer the view's own live, measured line height over the
  // 28px guess, read fresh each time (not cached), so it tracks a setFontSize change too.
  function currentLineHeight() {
    return view && typeof view.defaultLineHeight === 'number' && view.defaultLineHeight > 0
      ? view.defaultLineHeight
      : lineHeight;
  }

  let inkDoc = initialInk && typeof initialInk === 'object'
    ? {
        version: 1,
        strokes: Array.isArray(initialInk.strokes) ? [...initialInk.strokes] : [],
        removed: Array.isArray(initialInk.removed) ? [...initialInk.removed] : []
      }
    : { version: 1, strokes: [], removed: [] };

  // Select until a Pencil touches the page or a tool is picked, so a mouse drag selects text.
  let currentTool = SELECT_TOOL;
  let toolChosen = false;
  let previousDrawingTool = 'pen';
  let awake = false;
  let currentColor = null;
  let isDrawing = false;
  let activePoints = [];
  // Derived from Spec: UI-04 P7 — the just-snapped shape's corner handles, and a handle being dragged.
  let handlesFor = null;
  let handleDrag = null;   // { id, index, original }
  let handleGroup = null;
  // Derived from Spec: UI-04 P8 — hold inside a closed shape to fill it.
  let fillTimer = null;
  let fillDone = false;
  // Derived from Spec: UI-04 P9 — the Lasso's pointer.
  let lassoing = false;
  // Derived from Spec: UI-04 P6 — which pointer draws, and whether a touch is still on probation.
  let drawingId = null;
  let inkLive = true;
  const palm = createPalmGate({
    viewport: () => ({ w: Number(globalObj?.innerWidth) || 0, h: Number(globalObj?.innerHeight) || 0 })
  });
  let strokeStartTime = 0;
  let debounceTimer = null;

  const docNode = globalObj?.document || (typeof document !== 'undefined' ? document : null);
  const scrollDOM = view?.scrollDOM || (view instanceof (globalObj?.HTMLElement || Object) ? view : null);

  let svg = null;
  let highlightGroup = null;
  let penGroup = null;
  let activeGroup = null;
  let eraserRing = null;
  let palette = null;
  const colorDots = [];
  const toolDots = [];
  let wheelBtn = null;
  let wheel = null;
  let wheelDisc = null;
  let wheelMark = null;
  let wheelLight = null;
  let wheelOpen = false;
  let wheelCheck = null;
  let pendingColor = null;
  // The eight dots' colours: the defaults, or the ones the wheel put there (kept on this device).
  const COLORS_KEY = 'rc-ink-colors';
  const paletteColors = (() => {
    try {
      const saved = JSON.parse(globalObj?.localStorage?.getItem(COLORS_KEY) || 'null');
      if (Array.isArray(saved) && saved.length === INK_COLORS.length && saved.every(c => /^#[0-9a-fA-F]{6}$/.test(c))) return saved;
    } catch { /* no storage: the defaults */ }
    return [...INK_COLORS];
  })();
  currentColor = paletteColors[0];

  function getCurrentPageIndex() {
    if (typeof getPageIndex === 'function') {
      return getPageIndex();
    }
    return activePageIndex ?? 0;
  }

  function getDocText() {
    if (view && view.state && view.state.doc && typeof view.state.doc.toString === 'function') {
      return view.state.doc.toString();
    }
    return '';
  }

  // 1. Build SVG Layer
  if (docNode && scrollDOM && typeof docNode.createElementNS === 'function') {
    svg = docNode.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('class', 'rc-ink-svg');
    svg.style.position = 'absolute';
    svg.style.top = '0';
    svg.style.left = '0';
    svg.style.width = '100%';
    svg.style.height = '100%';
    svg.style.pointerEvents = 'none';
    svg.style.zIndex = '3';

    highlightGroup = docNode.createElementNS('http://www.w3.org/2000/svg', 'g');
    highlightGroup.setAttribute('class', 'rc-ink-highlight-group');
    highlightGroup.style.mixBlendMode = 'multiply';

    penGroup = docNode.createElementNS('http://www.w3.org/2000/svg', 'g');
    penGroup.setAttribute('class', 'rc-ink-pen-group');

    activeGroup = docNode.createElementNS('http://www.w3.org/2000/svg', 'g');
    activeGroup.setAttribute('class', 'rc-ink-active-group');

    // The eraser's ring: replaces the pointer while an eraser is picked, at exactly the size it erases.
    eraserRing = docNode.createElementNS('http://www.w3.org/2000/svg', 'circle');
    eraserRing.setAttribute('class', 'rc-ink-eraser-ring');
    eraserRing.setAttribute('fill', 'none');
    eraserRing.setAttribute('stroke-width', '1');
    eraserRing.style.display = 'none';

    svg.appendChild(highlightGroup);
    svg.appendChild(penGroup);
    svg.appendChild(activeGroup);
    svg.appendChild(eraserRing);
    handleGroup = docNode.createElementNS('http://www.w3.org/2000/svg', 'g');
    handleGroup.setAttribute('class', 'rc-ink-handles');
    svg.appendChild(handleGroup);

    if (typeof scrollDOM.appendChild === 'function') {
      scrollDOM.appendChild(svg);
    }
  }

  // 2. The pill and its palette. The pill always rests under the top edge (asleep); a tap,
  // or a Pencil double-tap or squeeze, wakes the palette, which hangs over the text without
  // moving it. A tap anywhere outside puts it back to sleep.
  let dock = null;
  let pill = null;
  let lassoModes = null;
  let selection = null;   // UI-04 P9–P12, made once the SVG exists (below)
  if (docNode && typeof docNode.createElement === 'function') {
    dock = docNode.createElement('div');
    dock.className = 'rc-ink-dock';

    pill = docNode.createElement('button');
    pill.className = 'rc-ink-pill';
    pill.setAttribute('type', 'button');
    pill.setAttribute('aria-label', 'Ink tools');
    pill.setAttribute('title', 'Ink tools');
    pill.setAttribute('aria-expanded', 'false');
    pill.textContent = '';
    pill.addEventListener('click', e => {
      if (typeof e.preventDefault === 'function') e.preventDefault();
      toggleMenu();
    });

    palette = docNode.createElement('div');
    palette.className = 'rc-ink-palette';
    palette.hidden = true;
    palette.setAttribute('aria-label', 'Ink palette');

    // Tools first (Select, then the ink tools), each with its own icon (no words)
    for (const tool of PALETTE_TOOLS) {
      const dot = docNode.createElement('button');
      dot.className = `rc-ink-tool-dot${tool === currentTool ? ' rc-active' : ''}`;
      dot.setAttribute('type', 'button');
      dot.setAttribute('data-tool', tool);
      dot.setAttribute('aria-label', INK_TOOL_NAMES[tool] || tool);
      dot.setAttribute('title', INK_TOOL_NAMES[tool] || tool);
      dot.textContent = '';
      dot.innerHTML = INK_TOOL_ICONS[tool] || '';
      dot.addEventListener('click', e => {
        if (typeof e.preventDefault === 'function') e.preventDefault();
        setTool(tool);
      });
      palette.appendChild(dot);
      toolDots.push(dot);
    }

    // The colour wheel, right after the eraser: a gradient to pick from, a lightness slider, and an eyedropper
    // that takes the colour of anything under it. The colour picked replaces the selected dot's colour.
    wheelBtn = docNode.createElement('button');
    wheelBtn.className = 'rc-ink-wheel-btn';
    wheelBtn.setAttribute('type', 'button');
    wheelBtn.setAttribute('aria-label', 'Colour wheel');
    wheelBtn.setAttribute('title', 'Colour wheel');
    wheelBtn.setAttribute('aria-expanded', 'false');
    wheelBtn.textContent = '';
    wheelBtn.addEventListener('click', e => {
      if (typeof e.preventDefault === 'function') e.preventDefault();
      setWheelOpen(!wheelOpen);
    });
    palette.appendChild(wheelBtn);

    // 8 colour dots (the wheel can replace any of them); picking one while on Select or the eraser picks the pen back up
    for (let i = 0; i < paletteColors.length; i++) {
      const dot = docNode.createElement('button');
      dot.className = `rc-ink-color-dot${paletteColors[i] === currentColor ? ' rc-active' : ''}`;
      dot.setAttribute('type', 'button');
      dot.setAttribute('data-color', paletteColors[i]);
      dot.setAttribute('aria-label', paletteColors[i]);
      dot.style.backgroundColor = paletteColors[i];
      dot.textContent = '';
      dot.addEventListener('click', e => {
        if (typeof e.preventDefault === 'function') e.preventDefault();
        setColor(dot.getAttribute('data-color'));
        if (!isInkTool(currentTool)) setTool(previousDrawingTool);
      });
      palette.appendChild(dot);
      colorDots.push(dot);
    }

    wheel = docNode.createElement('div');
    wheel.className = 'rc-ink-wheel';
    wheel.hidden = true;
    wheel.setAttribute('aria-label', 'Pick a colour');
    wheelDisc = docNode.createElement('div');
    wheelDisc.className = 'rc-ink-wheel-disc';
    wheelDisc.setAttribute('role', 'slider');
    wheelDisc.setAttribute('aria-label', 'Hue and saturation');
    wheelMark = docNode.createElement('div');
    wheelMark.className = 'rc-ink-wheel-mark';
    wheelDisc.appendChild(wheelMark);
    const side = docNode.createElement('div');
    side.className = 'rc-ink-wheel-side';
    wheelLight = docNode.createElement('input');
    wheelLight.className = 'rc-ink-wheel-light';
    wheelLight.setAttribute('type', 'range');
    wheelLight.setAttribute('min', '10');
    wheelLight.setAttribute('max', '90');
    wheelLight.setAttribute('value', '50');
    wheelLight.setAttribute('aria-label', 'Lightness');
    const dropper = docNode.createElement('button');
    dropper.className = 'rc-ink-dropper';
    dropper.setAttribute('type', 'button');
    dropper.setAttribute('aria-label', 'Eyedropper: take a colour from the screen');
    dropper.setAttribute('title', 'Eyedropper');
    dropper.innerHTML = ICON('<path d="M10.5 2.5l3 3-1.5 1.5-3-3z" fill="currentColor" fill-opacity="0.35"/><path d="M9 4l3 3-6.5 6.5H2.5v-3z"/>');
    dropper.addEventListener('click', e => {
      if (typeof e.preventDefault === 'function') e.preventDefault();
      sampleColor();
    });
    // The pending shade and its check mark: nothing changes until the check is pressed.
    wheelCheck = docNode.createElement('button');
    wheelCheck.className = 'rc-ink-wheel-check';
    wheelCheck.setAttribute('type', 'button');
    wheelCheck.setAttribute('aria-label', 'Use this colour');
    wheelCheck.setAttribute('title', 'Use this colour');
    wheelCheck.hidden = true;
    wheelCheck.innerHTML = ICON('<path d="M3.5 8.5l3 3 6-7" stroke-width="2"/>');
    wheelCheck.addEventListener('click', e => {
      if (typeof e.preventDefault === 'function') e.preventDefault();
      if (pendingColor) replaceSelectedColor(pendingColor);
      setWheelOpen(false);
    });
    side.appendChild(wheelLight);
    side.appendChild(dropper);
    side.appendChild(wheelCheck);
    wheel.appendChild(wheelDisc);
    wheel.appendChild(side);

    let wheelPoint = null;   // where on the disc (dx, dy, R) the last pick was
    const pickAt = e => {
      const r = wheelDisc.getBoundingClientRect ? wheelDisc.getBoundingClientRect() : { left: 0, top: 0, width: 160, height: 160 };
      const R = r.width / 2;
      let dx = e.clientX - (r.left + R), dy = e.clientY - (r.top + R);
      const d = Math.hypot(dx, dy);
      if (d > R) { dx = (dx / d) * R; dy = (dy / d) * R; }
      wheelPoint = { dx, dy, R };
      wheelMark.style.left = `${R + dx}px`;
      wheelMark.style.top = `${R + dy}px`;
      setPending(wheelColor(dx, dy, R, Number(wheelLight.value) / 100));
    };
    let wheelDown = false;
    wheelDisc.addEventListener('pointerdown', e => {
      wheelDown = true;
      if (typeof wheelDisc.setPointerCapture === 'function' && e.pointerId !== undefined) {
        try { wheelDisc.setPointerCapture(e.pointerId); } catch { /* capture is a nicety */ }
      }
      pickAt(e);
    });
    wheelDisc.addEventListener('pointermove', e => { if (wheelDown) pickAt(e); });
    wheelDisc.addEventListener('pointerup', () => { wheelDown = false; });
    wheelDisc.addEventListener('pointercancel', () => { wheelDown = false; });
    wheelLight.addEventListener('input', () => {
      wheelDisc.style.setProperty?.('--rc-wheel-l', `${wheelLight.value}%`);
      if (wheelPoint) setPending(wheelColor(wheelPoint.dx, wheelPoint.dy, wheelPoint.R, Number(wheelLight.value) / 100));
    });

    dock.appendChild(pill);
    dock.appendChild(palette);
    dock.appendChild(wheel);
    // Derived from Spec: UI-04 P9 — Freeform | Boxed, under the palette while the Lasso is picked.
    lassoModes = docNode.createElement('div');
    lassoModes.className = 'rc-ink-lassomodes';
    lassoModes.setAttribute('role', 'group');
    lassoModes.setAttribute('aria-label', 'Lasso mode');
    lassoModes.hidden = true;
    for (const m of LASSO_MODES) {
      const b = docNode.createElement('button');
      b.setAttribute('type', 'button');
      b.setAttribute('data-lasso-mode', m);
      b.textContent = m === 'freeform' ? 'Freeform' : 'Boxed';
      b.addEventListener('click', e => {
        if (typeof e.preventDefault === 'function') e.preventDefault();
        selection?.setMode(m);
        updateLassoModes();
      });
      lassoModes.appendChild(b);
    }
    dock.appendChild(lassoModes);
    const host = mount || scrollDOM?.parentNode || null;
    if (host && typeof host.appendChild === 'function') {
      host.appendChild(dock);
    }
  }

  function isInkTool(tool) {
    return INK_TOOLS.includes(tool) && !tool.startsWith('eraser');
  }

  function contains(node, target) {
    for (let n = target; n; n = n.parentNode) {
      if (n === node) return true;
    }
    return false;
  }

  // Any press outside the pill and palette puts the palette to sleep (it doesn't eat the press).
  function onOutsidePress(e) {
    if (!awake || !dock) return;
    // The colour wheel open: only its disc, lightness, eyedropper and check mark keep it; any other press puts the
    // wheel and the palette away and keeps the current colour.
    if (wheelOpen) {
      const keeps = [wheelDisc, wheelLight, wheelCheck, wheel && wheel.querySelector ? wheel.querySelector('.rc-ink-dropper') : null];
      if (keeps.some(k => k && contains(k, e.target))) return;
      hidePalette();
      return;
    }
    if (contains(dock, e.target)) return;
    hidePalette();
  }
  function onKey(e) {
    if (awake && e.key === 'Escape') hidePalette();
    if (e.key === 'Escape' && selection && selection.selectedIds().length) selection.clear();
  }
  if (docNode && typeof docNode.addEventListener === 'function') {
    docNode.addEventListener('pointerdown', onOutsidePress, true);
    docNode.addEventListener('keydown', onKey, true);
  }

  function updateLassoModes() {
    if (!lassoModes) return;
    lassoModes.hidden = currentTool !== LASSO_TOOL;
    const mode = selection ? selection.mode() : 'freeform';
    for (const b of lassoModes.children || []) {
      const on = b.getAttribute('data-lasso-mode') === mode;
      b.className = on ? 'rc-active' : '';
      b.setAttribute('aria-pressed', String(on));
    }
  }

  function updatePaletteActive() {
    for (const dot of colorDots) {
      const c = dot.getAttribute('data-color');
      if (c === currentColor) {
        dot.className = 'rc-ink-color-dot rc-active';
      } else {
        dot.className = 'rc-ink-color-dot';
      }
    }
    for (const dot of toolDots) {
      const t = dot.getAttribute('data-tool');
      if (t === currentTool) {
        dot.className = 'rc-ink-tool-dot rc-active';
      } else {
        dot.className = 'rc-ink-tool-dot';
      }
    }
  }

  function setWheelOpen(on) {
    wheelOpen = Boolean(on) && awake;
    if (wheel) wheel.hidden = !wheelOpen;
    if (wheelBtn) wheelBtn.setAttribute('aria-expanded', String(wheelOpen));
    if (!wheelOpen) setPending(null);
  }

  /** A shade picked (wheel, lightness or eyedropper) waits under its check mark; null clears it. */
  function setPending(hex) {
    pendingColor = /^#[0-9a-fA-F]{6}$/.test(String(hex)) ? String(hex) : null;
    if (wheelCheck) {
      wheelCheck.hidden = !pendingColor;
      wheelCheck.style.backgroundColor = pendingColor || '';
    }
    return pendingColor;
  }

  /** The host's eyedropper answer: shown under the check mark (the wheel opens for it if it was closed). */
  function offerColor(hex) {
    if (!awake) setAwake(true);
    if (!wheelOpen) setWheelOpen(true);
    return setPending(hex);
  }

  /** The colour picked (wheel or eyedropper) replaces the selected dot's colour, and the pen picks it up. */
  function replaceSelectedColor(hex) {
    if (!/^#[0-9a-fA-F]{6}$/.test(String(hex))) return null;
    let i = paletteColors.indexOf(currentColor);
    if (i < 0) i = 0;
    paletteColors[i] = hex;
    const dot = colorDots[i];
    if (dot) {
      dot.setAttribute('data-color', hex);
      dot.setAttribute('aria-label', hex);
      dot.style.backgroundColor = hex;
    }
    try { globalObj?.localStorage?.setItem(COLORS_KEY, JSON.stringify(paletteColors)); } catch { /* kept for this session */ }
    currentColor = hex;
    if (!isInkTool(currentTool)) setTool(previousDrawingTool);
    updatePaletteActive();
    return hex;
  }

  /** The eyedropper: the browser's own where it has one, else the host's (macOS's sampler, iOS's colour picker). */
  function sampleColor() {
    const Dropper = globalObj?.EyeDropper;
    if (typeof Dropper === 'function') {
      new Dropper().open().then(r => offerColor(r.sRGBHex)).catch(() => {});
      return;
    }
    globalObj?.webkit?.messageHandlers?.ui?.postMessage?.({ sampleColor: true });
  }

  function setAwake(on) {
    awake = Boolean(on);
    if (!awake) setWheelOpen(false);
    if (palette) palette.hidden = !awake;
    if (dock) dock.className = awake ? 'rc-ink-dock rc-awake' : 'rc-ink-dock';
    if (pill) pill.setAttribute('aria-expanded', String(awake));
  }

  function showPalette() {
    setAwake(true);
  }

  function hidePalette() {
    setAwake(false);
  }

  function toggleMenu() {
    setAwake(!awake);
    return awake;
  }

  function isAwake() {
    return awake;
  }

  function schedulePost() {
    if (debounceTimer !== null) {
      clearTimeout(debounceTimer);
    }
    debounceTimer = setTimeout(() => {
      debounceTimer = null;
      const data = getInk();
      const handler =
        globalObj &&
        globalObj.webkit &&
        globalObj.webkit.messageHandlers &&
        globalObj.webkit.messageHandlers.ink;
      if (handler && typeof handler.postMessage === 'function') {
        handler.postMessage(JSON.stringify(data));
      }
      if (typeof onInkChange === 'function') {
        onInkChange(data);
      }
    }, debounceMs);
  }

  function renderStrokeElement(stroke, targetGroup) {
    if (!docNode || !targetGroup || typeof docNode.createElementNS !== 'function') return;
    const pts = stroke.points || [];
    if (pts.length === 0) return;

    const isHighlighter = stroke.tool === 'highlighter';
    const isOrphaned = Boolean(stroke.orphaned);
    const strokeWidth = stroke.width || getToolDefaultWidth(stroke.tool);
    // Derived from Spec: UI-04 P12 — solid / pressure / dashed / dotted; no `style` = the tool's default.
    const lineStyle = strokeStyleOf(stroke);
    const dash = dashFor(lineStyle, strokeWidth);
    // Derived from Spec: UI-04 P8 — a filled closed shape (fill under its outline, translucent).
    const applyFill = el => {
      if (stroke.fill) {
        el.setAttribute('fill', stroke.fill);
        el.setAttribute('fill-opacity', String(FILL_OPACITY));
      } else {
        el.setAttribute('fill', 'none');
      }
      if (dash) el.setAttribute('stroke-dasharray', dash);
    };

    if (stroke.shape?.kind === 'ellipse') {
      const el = docNode.createElementNS('http://www.w3.org/2000/svg', 'ellipse');
      el.setAttribute('cx', String(stroke.shape.cx));
      el.setAttribute('cy', String(stroke.shape.cy));
      el.setAttribute('rx', String(stroke.shape.rx));
      el.setAttribute('ry', String(stroke.shape.ry));
      if (stroke.shape.rot) {
        el.setAttribute('transform', `rotate(${(stroke.shape.rot * 180) / Math.PI} ${stroke.shape.cx} ${stroke.shape.cy})`);
      }
      applyFill(el);
      el.setAttribute('stroke', stroke.color || currentColor);
      el.setAttribute('stroke-width', String(strokeWidth));
      el.setAttribute('stroke-linecap', 'round');
      if (isHighlighter) el.setAttribute('opacity', '0.45');
      else if (isOrphaned) el.setAttribute('opacity', '0.38');
      targetGroup.appendChild(el);
      return;
    }

    // Derived from Spec: UI-04 P7 — a snapped polygon: its corners, closed.
    if (stroke.shape?.kind === 'polygon') {
      const corners = polygonCorners(stroke);
      if (corners.length >= 2) {
        const el = docNode.createElementNS('http://www.w3.org/2000/svg', 'path');
        el.setAttribute('d', corners.map((c, i) => `${i ? 'L' : 'M'} ${c[0].toFixed(2)} ${c[1].toFixed(2)}`).join(' ') + ' Z');
        applyFill(el);
        el.setAttribute('stroke', stroke.color || currentColor);
        el.setAttribute('stroke-width', String(strokeWidth));
        el.setAttribute('stroke-linecap', 'round');
        el.setAttribute('stroke-linejoin', 'round');
        if (isHighlighter) el.setAttribute('opacity', '0.45');
        else if (isOrphaned) el.setAttribute('opacity', '0.38');
        targetGroup.appendChild(el);
        return;
      }
    }

    if (stroke.shape?.kind === 'line') {
      const el = docNode.createElementNS('http://www.w3.org/2000/svg', 'line');
      el.setAttribute('x1', String(stroke.shape.x1));
      el.setAttribute('y1', String(stroke.shape.y1));
      el.setAttribute('x2', String(stroke.shape.x2));
      el.setAttribute('y2', String(stroke.shape.y2));
      if (dash) el.setAttribute('stroke-dasharray', dash);
      el.setAttribute('stroke', stroke.color || currentColor);
      el.setAttribute('stroke-width', String(strokeWidth));
      el.setAttribute('stroke-linecap', 'round');
      if (isHighlighter) el.setAttribute('opacity', '0.45');
      else if (isOrphaned) el.setAttribute('opacity', '0.38');
      targetGroup.appendChild(el);
      return;
    }

    if (pts.length === 1) {
      const el = docNode.createElementNS('http://www.w3.org/2000/svg', 'circle');
      el.setAttribute('cx', String(pts[0][0]));
      el.setAttribute('cy', String(pts[0][1]));
      el.setAttribute('r', String(strokeWidth / 2));
      el.setAttribute('fill', stroke.color || currentColor);
      if (isHighlighter) el.setAttribute('opacity', '0.45');
      else if (isOrphaned) el.setAttribute('opacity', '0.38');
      targetGroup.appendChild(el);
      return;
    }

    // Derived from Spec: T-0094 — the pen is a filled outline whose width follows pressure.
    if (stroke.tool === 'pen' && lineStyle === 'pressure') {
      const outline = outlinePath(pts, strokeWidth);
      if (outline) {
        const el = docNode.createElementNS('http://www.w3.org/2000/svg', 'path');
        el.setAttribute('d', outline);
        el.setAttribute('fill', stroke.color || currentColor);
        el.setAttribute('fill-rule', 'nonzero');
        if (isOrphaned) el.setAttribute('opacity', '0.38');
        targetGroup.appendChild(el);
        return;
      }
    }

    const path = docNode.createElementNS('http://www.w3.org/2000/svg', 'path');
    let d = `M ${pts[0][0].toFixed(2)} ${pts[0][1].toFixed(2)}`;
    for (let i = 1; i < pts.length; i++) {
      d += ` L ${pts[i][0].toFixed(2)} ${pts[i][1].toFixed(2)}`;
    }
    path.setAttribute('d', d);
    path.setAttribute('fill', 'none');
    path.setAttribute('stroke', stroke.color || currentColor);
    path.setAttribute('stroke-width', String(strokeWidth));
    path.setAttribute('stroke-linecap', 'round');
    path.setAttribute('stroke-linejoin', 'round');
    if (dash) path.setAttribute('stroke-dasharray', dash);
    if (isHighlighter) path.setAttribute('opacity', '0.45');
    else if (isOrphaned) path.setAttribute('opacity', '0.38');
    targetGroup.appendChild(path);
  }

  function render() {
    if (!docNode) return;
    if (highlightGroup) highlightGroup.innerHTML = '';
    if (penGroup) penGroup.innerHTML = '';
    if (activeGroup) activeGroup.innerHTML = '';

    const activePage = getCurrentPageIndex();

    for (const stroke of inkDoc.strokes) {
      // Filter by active page window so Window 0 ink only shows on Window 0
      if (
        stroke.anchor &&
        typeof stroke.anchor.pageIndex === 'number' &&
        stroke.anchor.pageIndex !== activePage
      ) {
        continue;
      }

      const targetGroup = stroke.tool === 'highlighter' ? highlightGroup : penGroup;
      renderStrokeElement(stroke, targetGroup);
      // Find marks handwriting that holds the search (a glow on its strokes).
      if (stroke.ocr && inkMarks.has(stroke.ocr.g) && targetGroup.lastChild?.setAttribute) {
        targetGroup.lastChild.setAttribute('class', 'rc-ink-found');
      }
    }
    drawHandles();
    if (selection) selection.draw();
  }

  function renderActiveStroke() {
    if (!docNode || !activeGroup) return;
    activeGroup.innerHTML = '';
    if (activePoints.length === 0) return;

    const stroke = {
      tool: currentTool,
      color: currentColor,
      width: getToolDefaultWidth(currentTool),
      points: activePoints
    };
    renderStrokeElement(stroke, activeGroup);
  }

  function relayout() {
    const docText = getDocText();
    for (const stroke of inkDoc.strokes) {
      const res = resolveStrokeAnchor(stroke, docText, currentLineHeight());
      stroke.points = res.points;
      stroke.orphaned = res.orphaned;
      if (stroke.anchor) {
        stroke.anchor.pageIndex = res.pageIndex;
      }
      if (res.shape) {
        stroke.shape = res.shape;
      }
    }
    render();
  }

  function getInk() {
    return {
      version: 1,
      strokes: inkDoc.strokes.map(s => ({
        ...s,
        points: s.points ? s.points.map(p => [...p]) : [],
        anchor: s.anchor ? { ...s.anchor } : null,
        shape: s.shape ? { ...s.shape } : null
      })),
      removed: [...inkDoc.removed]
    };
  }

  function setInk(data) {
    inkDoc = data && typeof data === 'object'
      ? {
          version: 1,
          strokes: Array.isArray(data.strokes) ? [...data.strokes] : [],
          removed: Array.isArray(data.removed) ? [...data.removed] : []
        }
      : { version: 1, strokes: [], removed: [] };
    render();
  }

  function addStroke(stroke) {
    if (!stroke || typeof stroke !== 'object') return;
    if (!stroke.id) {
      stroke.id = `stroke-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;
    }
    if (!stroke.at) {
      stroke.at = Date.now();
    }
    if (!stroke.tool) {
      stroke.tool = currentTool;
    }
    if (!stroke.color) {
      stroke.color = currentColor;
    }
    if (!stroke.width) {
      stroke.width = getToolDefaultWidth(stroke.tool);
    }
    if (!stroke.anchor) {
      anchorStrokeToDoc(stroke, getDocText(), currentLineHeight(), getCurrentPageIndex());
    }
    inkDoc.strokes.push(stroke);
    render();
    schedulePost();
  }

  function eraseAt(points, mode = null) {
    const effectiveMode = mode || (currentTool === 'eraser-partial' ? 'partial' : 'whole');
    const docText = getDocText();
    let res;
    if (effectiveMode === 'partial' || effectiveMode === 'eraser-partial') {
      res = erasePartialStrokes(inkDoc.strokes, points, ERASER_RADIUS['eraser-partial'], docText, currentLineHeight(), getCurrentPageIndex());
    } else {
      res = eraseWholeStrokes(inkDoc.strokes, points, ERASER_RADIUS['eraser-whole']);
    }

    inkDoc.strokes = res.remaining;
    if (res.removedIds && res.removedIds.length > 0) {
      const set = new Set([...inkDoc.removed, ...res.removedIds]);
      inkDoc.removed = Array.from(set);
    }
    render();
    schedulePost();
  }

  function setTool(tool) {
    if (!PALETTE_TOOLS.includes(tool)) return;
    if (isInkTool(tool)) {
      previousDrawingTool = tool;
    }
    toolChosen = true;
    currentTool = tool;
    if (selection) selection.clear();
    handlesFor = null;
    drawHandles();
    updatePaletteActive();
    updateLassoModes();
    updateCursor();
    if (typeof onToolChange === 'function') onToolChange(tool);
  }

  // An eraser hides the pointer and draws its ring instead; any other tool gives the pointer back.
  function updateCursor() {
    const erasing = currentTool.startsWith('eraser');
    if (scrollDOM?.style) scrollDOM.style.cursor = erasing ? 'none' : '';
    // Derived from Spec: BUG-21 — WebKit pans on a finger drag unless touch-action is set before the touch starts.
    if (scrollDOM?.style) scrollDOM.style.touchAction = currentTool === SELECT_TOOL ? '' : 'none';
    if (!erasing) hideRing();
  }

  function hideRing() {
    if (eraserRing) eraserRing.style.display = 'none';
  }

  function moveRing(e) {
    if (!eraserRing || !currentTool.startsWith('eraser') || e.pointerType === 'touch') return;
    const rect = scrollDOM?.getBoundingClientRect ? scrollDOM.getBoundingClientRect() : { left: 0, top: 0 };
    eraserRing.setAttribute('cx', String(e.clientX - rect.left + (scrollDOM?.scrollLeft || 0)));
    eraserRing.setAttribute('cy', String(e.clientY - rect.top + (scrollDOM?.scrollTop || 0)));
    eraserRing.setAttribute('r', String(ERASER_RADIUS[currentTool] || 12));
    eraserRing.style.display = '';
  }

  // Derived from Spec: UI-04 P2 — the held squeeze's radial menu: the palette's tools on the inner ring
  // (every item is also a palette button), `::` macros on the outer ring (none exist yet).
  let radial = null;
  function radialMenu() {
    if (!radial) {
      radial = createRadialMenu({
        doc: docNode,
        mount: docNode?.body || null,   // fixed to the viewport: no transformed ancestor
        items: () => ({
          inner: PALETTE_TOOLS.map(t => ({ id: t, label: INK_TOOL_NAMES[t] || t, icon: INK_TOOL_ICONS[t] || '' })),
          outer: typeof radialOuter === 'function' ? (radialOuter() || []) : []
        }),
        onPick: (item, ring) => {
          if (ring === 'outer') { if (typeof item.pick === 'function') item.pick(); }
          else setTool(item.id);
          haptic('snap');
        },
        reduceMotion: () => Boolean(globalObj?.matchMedia?.('(prefers-reduced-motion: reduce)')?.matches),
        viewport: () => ({ w: Number(globalObj?.innerWidth) || 0, h: Number(globalObj?.innerHeight) || 0 })
      });
    }
    return radial;
  }

  // Posts a haptic to the native host (iOS); extra fields (a point for the Pencil's own haptic) ride along.
  function haptic(kind, extra = null) {
    const h = globalObj?.webkit?.messageHandlers?.ui;
    if (h && typeof h.postMessage === 'function') h.postMessage({ haptic: kind, ...(extra || {}) });
  }

  function getTool() {
    return currentTool;
  }

  function setColor(color) {
    if (paletteColors.includes(color) || /^#[0-9a-fA-F]{6}$/.test(color)) {
      currentColor = color;
      updatePaletteActive();
    }
  }

  function getColor() {
    return currentColor;
  }

  function toggleEraser() {
    setTool(currentTool.startsWith('eraser') ? previousDrawingTool : 'eraser-whole');
    return currentTool;
  }

  // Whether this press draws. Select never draws; the first Pencil touch on an untouched
  // palette picks the pen, so the iPad writes at once while the Mac's mouse selects text.
  // Regression guard: BUG-06 — once a tool is chosen, a finger draws too (iPhone has no Pencil).
  function inks(e) {
    if (!allowMouse && e.pointerType === 'mouse') return false;
    if (currentTool === SELECT_TOOL && !toolChosen && e.pointerType === 'pen') {
      currentTool = 'pen';
      updatePaletteActive();
      updateCursor();
      if (typeof onToolChange === 'function') onToolChange(currentTool);
    }
    return currentTool !== SELECT_TOOL;
  }

  const sameId = (a, b) => a === undefined || a === null || b === undefined || b === null || a === b;
  const prevent = e => { if (typeof e.preventDefault === 'function') e.preventDefault(); };

  // Derived from Spec: UI-04 P6 — the page moves only by the gate's two-finger (or Pencil-mode) scroll.
  function scrollBy(dx, dy) {
    if (!scrollDOM) return;
    if (dy) scrollDOM.scrollTop = (scrollDOM.scrollTop || 0) - dy;
    if (dx) scrollDOM.scrollLeft = (scrollDOM.scrollLeft || 0) - dx;
  }

  function dropActive() {
    isDrawing = false;
    drawingId = null;
    inkLive = true;
    activePoints = [];
    if (activeGroup) activeGroup.innerHTML = '';
  }

  function drawHandles() {
    if (!handleGroup || !docNode) return;
    handleGroup.innerHTML = '';
    if (!handlesFor) return;
    const st = inkDoc.strokes.find(x => x.id === handlesFor);
    if (!st) { handlesFor = null; return; }
    for (const [x, y] of shapeHandles(st)) {
      const c = docNode.createElementNS('http://www.w3.org/2000/svg', 'circle');
      c.setAttribute('cx', String(x));
      c.setAttribute('cy', String(y));
      c.setAttribute('r', '5');
      c.setAttribute('class', 'rc-ink-handle rc-ink-handle-corner');
      handleGroup.appendChild(c);
    }
  }

  function handleAt(x, y) {
    if (!handlesFor) return -1;
    const st = inkDoc.strokes.find(q => q.id === handlesFor);
    if (!st) return -1;
    const hs = shapeHandles(st);
    let best = -1, bestD = HANDLE_HIT;
    hs.forEach(([hx, hy], i) => { const d = Math.hypot(hx - x, hy - y); if (d <= bestD) { bestD = d; best = i; } });
    return best;
  }

  function stopFillTimer() {
    if (fillTimer !== null) { (globalObj?.clearTimeout || clearTimeout)(fillTimer); fillTimer = null; }
  }

  // Derived from Spec: UI-04 P8 — the pen held still for SNAP_HOLD_MS inside a closed shape fills it.
  function startFillTimer() {
    stopFillTimer();
    if (currentTool !== 'pen' && currentTool !== 'highlighter') return;
    const set = globalObj?.setTimeout || setTimeout;
    fillTimer = set(() => {
      fillTimer = null;
      if (!isDrawing || !inkLive || activePoints.length === 0) return;
      const [x0, y0] = activePoints[0];
      if (activePoints.some(q => Math.hypot(q[0] - x0, q[1] - y0) > 6)) return;
      const target = closedShapeAt(inkDoc.strokes, x0, y0, getCurrentPageIndex());
      if (!target) return;
      fillDone = true;
      activePoints = [];
      if (activeGroup) activeGroup.innerHTML = '';
      replaceStrokes([{ ...target, fill: currentColor }], true);
      haptic('shapeSnap');
    }, SNAP_HOLD_MS);
  }

  // Derived from Spec: UI-04 P13 — a 2x loupe above the point while a finger or the Pencil drags a corner handle or
  // a selection, so the hand doesn't hide what moves. Shows the ink (not the text under it).
  const LOUPE_R = 56, LOUPE_ZOOM = 2, LOUPE_LIFT = 96;
  let loupe = null, loupeSvg = null;
  function showLoupe(e, x, y) {
    if (e.pointerType === 'mouse' || !svg || !docNode || typeof docNode.createElement !== 'function') return;
    if (!loupe) {
      loupe = docNode.createElement('div');
      loupe.className = 'rc-ink-loupe';
      loupe.setAttribute('aria-hidden', 'true');
      loupeSvg = docNode.createElementNS('http://www.w3.org/2000/svg', 'svg');
      loupeSvg.setAttribute('width', String(2 * LOUPE_R));
      loupeSvg.setAttribute('height', String(2 * LOUPE_R));
      loupe.appendChild(loupeSvg);
      (docNode.body || null)?.appendChild?.(loupe);
    }
    const half = LOUPE_R / LOUPE_ZOOM;
    loupeSvg.setAttribute('viewBox', `${x - half} ${y - half} ${2 * half} ${2 * half}`);
    loupeSvg.innerHTML = [highlightGroup, penGroup, handleGroup, svg.querySelector?.('.rc-ink-selection')]
      .map(g => (g && typeof g.outerHTML === 'string' ? g.outerHTML : '')).join('');
    const [cx, cy] = contentToClient(x, y);
    loupe.style.left = `${cx}px`;
    loupe.style.top = `${Math.max(LOUPE_R, cy - LOUPE_LIFT)}px`;
    loupe.hidden = false;
  }
  function hideLoupe() { if (loupe) loupe.hidden = true; }

  function contentPoint(e) {
    const rect = scrollDOM?.getBoundingClientRect ? scrollDOM.getBoundingClientRect() : { left: 0, top: 0 };
    return [e.clientX - rect.left + (scrollDOM?.scrollLeft || 0), e.clientY - rect.top + (scrollDOM?.scrollTop || 0)];
  }

  function onPointerDown(e) {
    if (!inks(e)) return;
    const gate = palm.down(e);
    if (gate.cancel && isDrawing) dropActive();
    if (gate.act === 'scroll' || gate.act === 'ignore') { prevent(e); return; }
    if (isDrawing) return;

    const [px0, py0] = contentPoint(e);
    // Derived from Spec: UI-04 P9 — the Lasso draws a selection loop, or drags the selection it already has.
    if (currentTool === LASSO_TOOL) {
      isDrawing = true;
      drawingId = e.pointerId;
      inkLive = true;
      lassoing = true;
      if (selection) selection.down(px0, py0);
      prevent(e);
      return;
    }
    // Derived from Spec: UI-04 P7 — a press on a just-snapped shape's corner handle drags that corner.
    const hi = handleAt(px0, py0);
    if (hi >= 0) {
      const st = inkDoc.strokes.find(q => q.id === handlesFor);
      handleDrag = { id: st.id, index: hi, original: st };
      isDrawing = true;
      drawingId = e.pointerId;
      inkLive = true;
      prevent(e);
      return;
    }
    if (handlesFor) { handlesFor = null; drawHandles(); }
    fillDone = false;

    isDrawing = true;
    drawingId = e.pointerId;
    inkLive = gate.act !== 'wait';
    strokeStartTime = e.timeStamp || Date.now();

    const rect = scrollDOM?.getBoundingClientRect ? scrollDOM.getBoundingClientRect() : { left: 0, top: 0 };
    const scrollLeft = scrollDOM?.scrollLeft || 0;
    const scrollTop = scrollDOM?.scrollTop || 0;
    const x = e.clientX - rect.left + scrollLeft;
    const y = e.clientY - rect.top + scrollTop;
    const t = strokeStartTime;
    const p = nextPressure(e, x, y, t, null);

    activePoints = [[x, y, p, t]];

    if (inkLive) startLive();
    startFillTimer();
    prevent(e);
  }

  // Draw what has been buffered so far: the whole stroke from where the pointer landed.
  function startLive() {
    inkLive = true;
    if (currentTool.startsWith('eraser')) {
      eraseAt(activePoints.map(q => [q[0], q[1]]), currentTool === 'eraser-partial' ? 'partial' : 'whole');
    } else {
      renderActiveStroke();
    }
  }

  function onPointerMove(e) {
    moveRing(e);   // also while hovering (mouse, or a Pencil above the glass)
    if (currentTool === SELECT_TOOL) return;
    const gate = palm.move(e);
    if (gate.act === 'scroll') { scrollBy(gate.dx, gate.dy); prevent(e); return; }
    if (!isDrawing || !sameId(drawingId, e.pointerId)) return;
    if (lassoing || handleDrag) {
      const [mx, my] = contentPoint(e);
      if (lassoing) { if (selection) selection.move(mx, my); }
      else replaceStrokes([moveHandle(handleDrag.original, handleDrag.index, mx, my)], false);
      if (handleDrag || selection?.isDragging()) showLoupe(e, mx, my);
      prevent(e);
      return;
    }
    if (fillDone) { prevent(e); return; }
    if (gate.act === 'ignore') { if (gate.cancel) dropActive(); prevent(e); return; }
    const goLive = gate.act === 'start';

    const rect = scrollDOM?.getBoundingClientRect ? scrollDOM.getBoundingClientRect() : { left: 0, top: 0 };
    const scrollLeft = scrollDOM?.scrollLeft || 0;
    const scrollTop = scrollDOM?.scrollTop || 0;

    // 240Hz Apple Pencil Pro: capture every coalesced event sample
    const rawEvents = typeof e.getCoalescedEvents === 'function' ? e.getCoalescedEvents() : [e];
    const events = Array.isArray(rawEvents) && rawEvents.length > 0 ? rawEvents : [e];

    for (const ev of events) {
      const x = ev.clientX - rect.left + scrollLeft;
      const y = ev.clientY - rect.top + scrollTop;
      const t = ev.timeStamp || Date.now();
      const p = nextPressure(ev, x, y, t, activePoints[activePoints.length - 1] || null);

      activePoints.push([x, y, p, t]);

      if (inkLive && currentTool.startsWith('eraser')) {
        eraseAt([[x, y]], currentTool === 'eraser-partial' ? 'partial' : 'whole');
      }
    }

    if (goLive) startLive();
    else if (inkLive && !currentTool.startsWith('eraser')) renderActiveStroke();
    prevent(e);
  }

  function onPointerUp(e) {
    const gate = palm.up(e);
    if (!isDrawing || !sameId(drawingId, e.pointerId)) return;
    stopFillTimer();
    hideLoupe();
    if (lassoing || handleDrag || fillDone) {
      const [ux, uy] = contentPoint(e);
      if (lassoing) { lassoing = false; isDrawing = false; drawingId = null; if (selection) selection.up(ux, uy); }
      else if (handleDrag) {
        const hd = handleDrag;
        handleDrag = null;
        isDrawing = false;
        drawingId = null;
        replaceStrokes([moveHandle(hd.original, hd.index, ux, uy)], true);
      }
      fillDone = false;
      dropActive();
      return;
    }
    const live = inkLive;
    isDrawing = false;
    drawingId = null;
    inkLive = true;
    if (!live || gate.cancel) { dropActive(); render(); return; }

    if (currentTool.startsWith('eraser')) {
      activePoints = [];
      if (activeGroup) activeGroup.innerHTML = '';
      return;
    }

    if (activePoints.length === 0) return;

    // Derived from Spec: BUG-03. toolChosen false here means currentTool only got to 'pen' via the
    // auto-detect in inks(), never an explicit pick (setTool is the only other place it's set, and it
    // always sets toolChosen true first) — that touch can't be told apart from a cursor-placement tap
    // until it either moves or doesn't: discard it here if it didn't.
    if (!toolChosen && e.pointerType === 'pen') {
      const [x0, y0] = activePoints[0];
      const moved = activePoints.some(p => Math.hypot(p[0] - x0, p[1] - y0) >= AUTO_PEN_TAP_PX);
      if (!moved) {
        activePoints = [];
        if (activeGroup) activeGroup.innerHTML = '';
        render();
        return;
      }
    }

    // Derived from Spec: UI-04 P6 — a finger or trackpad tap, or a trackpad brush, leaves no mark.
    const upTime = e.timeStamp || Date.now();
    if ((e.pointerType === 'touch' || e.pointerType === 'mouse') && isTinyStroke(activePoints)
        || e.pointerType === 'mouse' && isBrush(activePoints, upTime)) {
      dropActive();
      render();
      return;
    }

    // Only the stillness at the end counts, not the whole stroke's length.
    const holdDurationMs = endHoldMs(activePoints, e.timeStamp || Date.now());
    let finalPoints = activePoints;
    let finalShape = null;

    if (currentTool === 'underline') {
      finalPoints = snapUnderlineStroke(activePoints, currentLineHeight());
      finalShape = null;
    } else if (currentTool === 'circle') {
      const res = detectAndSnapShape(activePoints, { forceCircle: true });
      finalPoints = res.points;
      finalShape = res.shape;
    } else {
      const res = detectAndSnapShape(activePoints, { holdDurationMs, forceCircle: false });
      finalPoints = res.points;
      finalShape = res.shape;
      // Derived from Spec: UI-04 P3 — the snap is felt in the Pencil Pro, where the nib lifted (viewport point).
      if (res.snapped) haptic('shapeSnap', { x: Number(e.clientX) || 0, y: Number(e.clientY) || 0 });
    }

    const stroke = {
      id: `stroke-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`,
      tool: currentTool,
      color: currentColor,
      width: getToolDefaultWidth(currentTool),
      points: finalPoints,
      shape: finalShape,
      device: e.pointerType || 'pen',
      at: Date.now()
    };

    anchorStrokeToDoc(stroke, getDocText(), currentLineHeight(), getCurrentPageIndex());
    inkDoc.strokes.push(stroke);
    if (stroke.tool === 'pen') scheduleRecognition();
    // Derived from Spec: UI-04 P7 — corner handles on the shape that just snapped.
    if (finalShape && (finalShape.kind === 'polygon' || finalShape.kind === 'line') && currentTool !== 'underline') {
      handlesFor = stroke.id;
    }
    if (typeof onStrokeAdded === 'function') { try { onStrokeAdded(stroke); } catch { /* never lose the stroke */ } }

    activePoints = [];
    if (activeGroup) activeGroup.innerHTML = '';
    render();
    schedulePost();
  }

  // Handwriting → text, for Find: 1.5 s after the pen rests, each new group goes to the host as a picture.
  let ocrTimer = null;
  const ocrSent = new Map();   // group id → its strokes, while the host reads it
  function scheduleRecognition() {
    if (ocrTimer !== null) clearTimeout(ocrTimer);
    ocrTimer = setTimeout(() => {
      ocrTimer = null;
      recognizeNow();
    }, 1500);
  }
  function recognizeNow() {
    const post = globalObj?.webkit?.messageHandlers?.ui?.postMessage;
    if (typeof post !== 'function' || !docNode || typeof docNode.createElement !== 'function') return 0;
    const pending = new Set([...ocrSent.values()].flat());
    const groups = groupHandwriting(inkDoc.strokes.filter(st => !pending.has(st)), currentLineHeight());
    let sent = 0;
    for (const g of groups) {
      const png = renderGroupPNG(g);
      if (!png) continue;
      ocrSent.set(g.id, g.strokes);
      globalObj.webkit.messageHandlers.ui.postMessage({ inkOCR: { id: g.id, png } });
      sent++;
    }
    return sent;
  }
  /** One group, dark on white, at twice its size (the recogniser reads larger letters better), as base64 PNG. */
  function renderGroupPNG(g) {
    const pad = 12, k = 2;
    const w = Math.ceil((g.box.x1 - g.box.x0 + pad * 2) * k), h = Math.ceil((g.box.y1 - g.box.y0 + pad * 2) * k);
    if (w < 8 || h < 8 || w > 4096 || h > 4096) return null;
    const c = docNode.createElement('canvas');
    const ctx = c && typeof c.getContext === 'function' ? c.getContext('2d') : null;
    if (!ctx) return null;
    c.width = w;
    c.height = h;
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, w, h);
    ctx.strokeStyle = '#000000';
    ctx.lineWidth = 3 * k;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    for (const st of g.strokes) {
      ctx.beginPath();
      st.points.forEach((p, i) => {
        const x = (p[0] - g.box.x0 + pad) * k, y = (p[1] - g.box.y0 + pad) * k;
        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
      });
      if (st.points.length === 1) ctx.lineTo((st.points[0][0] - g.box.x0 + pad) * k + 0.1, (st.points[0][1] - g.box.y0 + pad) * k);
      ctx.stroke();
    }
    const url = typeof c.toDataURL === 'function' ? c.toDataURL('image/png') : '';
    return url.startsWith('data:image/png;base64,') ? url.slice('data:image/png;base64,'.length) : null;
  }
  /**
   * Pages `indices` of `docBefore` are being removed (an expired page): their strokes go (tombstoned, so a merge can't
   * bring them back) and strokes on later pages move up by the pages removed before them.
   */
  function removePageInk(indices, docBefore) {
    const drop = new Set(indices);
    const sorted = [...drop].sort((a, b) => a - b);
    const keep = [];
    let changed = false;
    for (const st of inkDoc.strokes) {
      const r = resolveStrokeAnchor(st, docBefore, currentLineHeight());
      const pi = r.pageIndex ?? 0;
      if (drop.has(pi)) { inkDoc.removed.push(st.id); changed = true; continue; }
      const shift = sorted.filter(i => i < pi).length;
      if (shift && st.anchor) { st.anchor = { ...st.anchor, pageIndex: pi - shift }; changed = true; }
      keep.push(st);
    }
    inkDoc.strokes = keep;
    if (changed) { schedulePost(); render(); }
    return changed;
  }
  /** The host's reading of a group: kept on its strokes (and saved with the ink), so Find sees it on every device. */
  function setInkText(id, text) {
    const strokes = ocrSent.get(id) || inkDoc.strokes.filter(st => st.ocr && st.ocr.g === id);
    ocrSent.delete(id);
    const live = new Set(inkDoc.strokes);
    let n = 0;
    for (const st of strokes) {
      if (!live.has(st)) continue;   // erased while it was being read
      st.ocr = { g: id, t: String(text ?? '') };
      n++;
    }
    if (n) schedulePost();
    return n;
  }
  function findInk(query) {
    return findInkText(inkDoc.strokes, query).map(m => {
      const r = resolveStrokeAnchor(m.stroke, getDocText(), currentLineHeight());
      const ys = (r.points || []).map(p => p[1]);
      return { id: m.id, text: m.text, pageIndex: r.pageIndex ?? 0, y: ys.length ? Math.min(...ys) : 0 };
    });
  }
  /** Marks the found groups' strokes (a glow), or clears the marks with an empty list. */
  let inkMarks = new Set();
  function markInk(ids) {
    inkMarks = new Set(ids || []);
    render();
  }

  function onPointerCancel(e) {
    if (e) palm.cancel(e);
    if (e && isDrawing && !sameId(drawingId, e.pointerId)) return;
    stopFillTimer();
    hideLoupe();
    fillDone = false;
    if (lassoing) { lassoing = false; if (selection) selection.cancel(); }
    if (handleDrag) { const hd = handleDrag; handleDrag = null; replaceStrokes([hd.original], false); }
    dropActive();
  }

  // Derived from Spec: UI-04 P6 — on the Mac, CodeMirror's mousedown starts a text-selection drag that
  // autoscrolls the page under the trackpad. While a tool inks, it never sees the press.
  function onMouseDownCapture(e) {
    if (!allowMouse || currentTool === SELECT_TOOL || (e && e.button !== undefined && e.button !== 0)) return;
    if (typeof e.stopPropagation === 'function') e.stopPropagation();
    prevent(e);
  }

  // Intercept Pencil events over .cm-embed with capture listeners
  function onPointerDownCapture(e) {
    if (e.pointerType === 'pen' && inks(e)) {
      if (typeof e.stopPropagation === 'function') e.stopPropagation();
      if (typeof e.preventDefault === 'function') e.preventDefault();
      onPointerDown(e);
    }
  }

  function onPointerEnterCapture(e) {
    if (e.pointerType === 'pen' && e.buttons > 0 && currentTool !== SELECT_TOOL) {
      if (typeof e.stopPropagation === 'function') e.stopPropagation();
      if (typeof e.preventDefault === 'function') e.preventDefault();
    }
  }

  if (scrollDOM && typeof scrollDOM.addEventListener === 'function') {
    scrollDOM.addEventListener('pointerdown', onPointerDownCapture, true);
    scrollDOM.addEventListener('pointerenter', onPointerEnterCapture, true);
    scrollDOM.addEventListener('mousedown', onMouseDownCapture, true);
    scrollDOM.addEventListener('pointerdown', onPointerDown);
    scrollDOM.addEventListener('pointermove', onPointerMove);
    scrollDOM.addEventListener('pointerup', onPointerUp);
    scrollDOM.addEventListener('pointercancel', onPointerCancel);
    scrollDOM.addEventListener('pointerleave', hideRing);
  }

  function destroy() {
    stopFillTimer();
    if (loupe) loupe.remove?.();
    if (selection) selection.clear();
    if (debounceTimer !== null) {
      clearTimeout(debounceTimer);
      debounceTimer = null;
    }
    if (ocrTimer !== null) {
      clearTimeout(ocrTimer);
      ocrTimer = null;
    }
    if (scrollDOM && typeof scrollDOM.removeEventListener === 'function') {
      scrollDOM.removeEventListener('pointerdown', onPointerDownCapture, true);
      scrollDOM.removeEventListener('pointerenter', onPointerEnterCapture, true);
      scrollDOM.removeEventListener('mousedown', onMouseDownCapture, true);
      scrollDOM.removeEventListener('pointerdown', onPointerDown);
      scrollDOM.removeEventListener('pointermove', onPointerMove);
      scrollDOM.removeEventListener('pointerup', onPointerUp);
      scrollDOM.removeEventListener('pointercancel', onPointerCancel);
      scrollDOM.removeEventListener('pointerleave', hideRing);
    }
    if (svg && svg.parentNode && typeof svg.parentNode.removeChild === 'function') {
      svg.parentNode.removeChild(svg);
    }
    if (docNode && typeof docNode.removeEventListener === 'function') {
      docNode.removeEventListener('pointerdown', onOutsidePress, true);
      docNode.removeEventListener('keydown', onKey, true);
    }
    if (dock && dock.parentNode && typeof dock.parentNode.removeChild === 'function') {
      dock.parentNode.removeChild(dock);
    }
  }

  // Derived from Spec: UI-04 P9–P12 — the Lasso's selection, menu and style panel.
  function pageStrokes() {
    const page = getCurrentPageIndex();
    return inkDoc.strokes.filter(st => !(st.anchor && typeof st.anchor.pageIndex === 'number' && st.anchor.pageIndex !== page));
  }
  function reanchor(st) {
    anchorStrokeToDoc(st, getDocText(), currentLineHeight(), getCurrentPageIndex());
  }
  function replaceStrokes(list, commit) {
    const byId = new Map(list.map(st => [st.id, st]));
    const now = Date.now();
    inkDoc.strokes = inkDoc.strokes.map(st => {
      const next = byId.get(st.id);
      if (!next) return st;
      if (commit) { next.edited = now; reanchor(next); }
      return next;
    });
    render();
    if (commit) schedulePost();
  }
  function addStrokes(list) {
    for (const st of list) { reanchor(st); inkDoc.strokes.push(st); }
    // Duplicates and pastes are new strokes, like a drawn one (FEAT-08 attaches them to a frozen passage's word).
    if (typeof onStrokeAdded === 'function') for (const st of list) { try { onStrokeAdded(st); } catch { /* keep the stroke */ } }
    render();
    schedulePost();
  }
  function removeStrokes(ids) {
    const gone = new Set(ids);
    if (!gone.size) return;
    inkDoc.strokes = inkDoc.strokes.filter(st => !gone.has(st.id));
    inkDoc.removed = Array.from(new Set([...inkDoc.removed, ...gone]));
    render();
    schedulePost();
  }
  function contentToClient(x, y) {
    const rect = scrollDOM?.getBoundingClientRect ? scrollDOM.getBoundingClientRect() : { left: 0, top: 0 };
    return [x + rect.left - (scrollDOM?.scrollLeft || 0), y + rect.top - (scrollDOM?.scrollTop || 0)];
  }
  if (svg) {
    selection = createInkSelection({
      doc: docNode,
      svg,
      globalObj,
      strokes: pageStrokes,
      replace: replaceStrokes,
      add: addStrokes,
      remove: removeStrokes,
      toClient: contentToClient,
      colors: () => [...paletteColors],
      haptic: kind => haptic(kind)
    });
  }
  updateLassoModes();

  // Initial render
  render();

  return {
    getInk,
    setInk,
    addStroke,
    eraseAt,
    setTool,
    getTool,
    setColor,
    getColor,
    toggleEraser,
    relayout,
    destroy,
    svg,
    palette,
    pill,
    dock,
    showPalette,
    hidePalette,
    toggleMenu,
    isAwake,
    replaceSelectedColor,
    offerColor,
    getPendingColor: () => pendingColor,
    setWheelOpen,
    getPaletteColors: () => [...paletteColors],
    setInkText,
    removePageInk,
    findInk,
    markInk,
    recognizeNow,
    radialMenu,
    selection: () => selection,
    handlesFor: () => handlesFor
  };
}
