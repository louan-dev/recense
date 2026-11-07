// Links you can open and list bullets you can see. Both are display only: the file keeps its plain Markdown.
// ⌘-click (or Ctrl-click) a URL or a [text](url) link to open it; the host opens it in the default browser.
import { RangeSetBuilder } from '@codemirror/state';
import { Decoration, EditorView, ViewPlugin, WidgetType } from '@codemirror/view';

const URL_RE = /\bhttps?:\/\/[^\s<>()\]]+[^\s<>()\].,;:!?'"]/g;
const MD_LINK_RE = /\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g;
const BULLET_RE = /^(\s*)([-*+]) (?!\[[ xX]\] )/;

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
