// Links you can open and list bullets you can see. Both are display only: the file keeps its plain Markdown.
// ⌘-click (or Ctrl-click) a URL or a [text](url) link to open it; the host opens it in the default browser.
import { RangeSetBuilder } from '@codemirror/state';
import { Decoration, EditorView, ViewPlugin, WidgetType } from '@codemirror/view';
import { formatTimestamp } from './audio.js';

const URL_RE = /\bhttps?:\/\/[^\s<>()\]]+[^\s<>()\].,;:!?'"]/g;
const MD_LINK_RE = /\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g;
const BULLET_RE = /^(\s*)([-*+]) (?!\[[ xX]\] )/;

// Derived from Spec: FEAT-23 A2 rule 1 · moment links. `recense://<key>` or `recense://<key>?t=<s>`: <key> is 24
// lowercase hex characters, <s> whole seconds, and the link ends there. Counted inside [label](…), ![label](…) or bare.
// Anything else (uppercase, another length, a fraction, another parameter) is text. The label is for the eye.
const MOMENT_URL = /^recense:\/\/([0-9a-f]{24})(?:\?t=(\d+))?$/;
const MOMENT_MD = /(!?)\[([^\]]*)\]\((recense:\/\/[^)\s]*)\)/g;
const MOMENT_BARE = /recense:\/\/[^\s()<>\]]*/g;

/** Every moment link in `text`: [{ key, t (whole seconds or null), label (or null), image, from, to, line (1-based) }]. */
export function momentLinks(text) {
  const s = String(text ?? '');
  const out = [];
  const taken = [];
  const lineOf = pos => { let n = 1; for (let i = s.indexOf('\n'); i !== -1 && i < pos; i = s.indexOf('\n', i + 1)) n++; return n; };
  for (const m of s.matchAll(MOMENT_MD)) {
    taken.push([m.index, m.index + m[0].length]);
    const u = MOMENT_URL.exec(m[3]);
    if (!u) continue;
    out.push({ key: u[1], t: u[2] === undefined ? null : Number(u[2]), label: m[2], image: m[1] === '!',
      from: m.index, to: m.index + m[0].length, line: lineOf(m.index) });
  }
  for (const m of s.matchAll(MOMENT_BARE)) {
    if (taken.some(([a, b]) => m.index >= a && m.index < b)) continue;
    const u = MOMENT_URL.exec(m[0]);
    if (!u) continue;
    out.push({ key: u[1], t: u[2] === undefined ? null : Number(u[2]), label: null, image: false,
      from: m.index, to: m.index + m[0].length, line: lineOf(m.index) });
  }
  return out.sort((a, b) => a.from - b.from);
}

/** `[mm:ss](recense://<key>?t=<whole seconds>)` (h:mm:ss over an hour). */
export function momentLink(key, seconds) {
  const t = Math.max(0, Math.floor(Number(seconds) || 0));
  return `[${formatTimestamp(t)}](recense://${key}?t=${t})`;
}

/** The moment link under column `col` of `line` as { key, t }, or null. */
export function momentAt(line, col) {
  for (const m of momentLinks(line)) if (col >= m.from && col < m.to) return { key: m.key, t: m.t };
  return null;
}

let onMoment = null;
/** FEAT-23 rule 5: the editor's player hook for a tapped moment link ({ key, t }). */
export function setMomentHandler(fn) { onMoment = typeof fn === 'function' ? fn : null; }

/** The URL under column `col` of `line`, or null. Markdown links win over the bare URL inside them. */
export function urlAt(line, col) {
  for (const m of line.matchAll(MD_LINK_RE)) {
    if (col >= m.index && col <= m.index + m[0].length) return m[2];
  }
  for (const m of line.matchAll(URL_RE)) {
    if (col >= m.index && col <= m.index + m[0].length) return m[0];
  }
  return null;
}

export function openURL(url, globalObj = typeof window !== 'undefined' ? window : null) {
  const h = globalObj && globalObj.webkit && globalObj.webkit.messageHandlers && globalObj.webkit.messageHandlers.link;
  if (h && typeof h.postMessage === 'function') { h.postMessage(url); return true; }
  if (globalObj && typeof globalObj.open === 'function') { globalObj.open(url, '_blank', 'noopener'); return true; }
  return false;
}

class BulletWidget extends WidgetType {
  eq() { return true; }
  toDOM() {
    const s = document.createElement('span');
    s.className = 'cm-bullet';
    s.textContent = '•';
    return s;
  }
}
const bullet = Decoration.replace({ widget: new BulletWidget() });
const linkMark = Decoration.mark({ class: 'cm-url-link' });

function build(view) {
  const b = new RangeSetBuilder();
  for (const { from, to } of view.visibleRanges) {
    let pos = from;
    while (pos <= to) {
      const line = view.state.doc.lineAt(pos);
      const items = [];
      const m = BULLET_RE.exec(line.text);
      if (m) items.push([line.from + m[1].length, line.from + m[1].length + 1, bullet]);
      for (const u of line.text.matchAll(URL_RE)) {
        items.push([line.from + u.index, line.from + u.index + u[0].length, linkMark]);
      }
      for (const u of momentLinks(line.text)) items.push([line.from + u.from, line.from + u.to, linkMark]);   // FEAT-23
      items.sort((a, c) => a[0] - c[0]);
      for (const [f, t, d] of items) b.add(f, t, d);
      pos = line.to + 1;
    }
  }
  return b.finish();
}

const decorations = ViewPlugin.fromClass(class {
  constructor(view) { this.decorations = build(view); }
  update(u) { if (u.docChanged || u.viewportChanged) this.decorations = build(u.view); }
}, { decorations: v => v.decorations });

const clicks = EditorView.domEventHandlers({
  // FEAT-23 rule 5: a tap or click on a moment link plays that item from that second. The caret still lands,
  // so the label stays editable; ⌘-click on a web link is unchanged.
  click(e, view) {
    if (!onMoment || e.metaKey || e.ctrlKey || e.button !== 0) return false;
    const pos = view.posAtCoords({ x: e.clientX, y: e.clientY });
    if (pos == null) return false;
    const line = view.state.doc.lineAt(pos);
    const m = momentAt(line.text, pos - line.from);
    if (!m) return false;
    onMoment(m);
    return false;
  },
  mousedown(e, view) {
    if (!(e.metaKey || e.ctrlKey) || e.button !== 0) return false;
    const pos = view.posAtCoords({ x: e.clientX, y: e.clientY });
    if (pos == null) return false;
    const line = view.state.doc.lineAt(pos);
    const url = urlAt(line.text, pos - line.from);
    if (!url) return false;
    e.preventDefault();
    openURL(url);
    return true;
  }
});

export function linksExtension() {
  return [decorations, clicks];
}
