// Inline embeds: a line that holds only `![caption](target)` shows the PDF or image under it. The text stays plain
// Markdown (Obsidian reads the same line). Inside Recense, targets go through the host's `recense-file:` scheme,
// which serves a vault file or a cached copy of a web file, so an embed opened once opens again offline.
import { StateField } from '@codemirror/state';
import { Decoration, EditorView, WidgetType } from '@codemirror/view';

const EMBED_RE = /^\s*!\[([^\]]*)\]\(<?([^)\s>]+)>?\)\s*$/;
const PDF_RE = /\.pdf(?:[?#].*)?$/i;
const IMAGE_RE = /\.(?:png|jpe?g|gif|webp|heic|svg)(?:[?#].*)?$/i;

export function parseEmbedLine(line) {
  const m = EMBED_RE.exec(line);
  if (!m) return null;
  const target = m[2];
  const kind = PDF_RE.test(target) ? 'pdf' : IMAGE_RE.test(target) ? 'image' : null;
  return kind ? { kind, target, caption: m[1] } : null;
}

function hasHost() {
  return typeof window !== 'undefined' && Boolean(window.webkit && window.webkit.messageHandlers &&
    window.webkit.messageHandlers.editor);
}

/** Where the widget loads `target` from: the host's scheme inside Recense, the target itself elsewhere. */
export function embedSource(target, host = hasHost()) {
  if (!host) return target;
  if (/^https?:\/\//i.test(target)) return `recense-file://remote/${encodeURIComponent(target)}`;
  if (/^[a-z][a-z0-9+.-]*:/i.test(target)) return target;
  return `recense-file://vault/${target.split('/').map(encodeURIComponent).join('/')}`;
}

class EmbedWidget extends WidgetType {
  constructor(kind, src, caption) {
    super();
    this.kind = kind;
    this.src = src;
    this.caption = caption;
  }
  eq(other) { return other.kind === this.kind && other.src === this.src; }
  get estimatedHeight() { return this.kind === 'pdf' ? 520 : 320; }
  toDOM() {
    const wrap = document.createElement('div');
    wrap.className = `cm-embed cm-embed-${this.kind}`;
    if (this.kind === 'pdf') {
      const frame = document.createElement('iframe');
      frame.src = this.src;
      frame.title = this.caption || 'PDF';
      frame.loading = 'lazy';
      wrap.appendChild(frame);
    } else {
      const img = document.createElement('img');
      img.src = this.src;
      img.alt = this.caption || '';
      img.loading = 'lazy';
      wrap.appendChild(img);
    }
    return wrap;
  }
  ignoreEvent() { return true; }
}

export function findEmbeds(text) {
  const out = [];
  let offset = 0;
  for (const line of text.split('\n')) {
    const e = parseEmbedLine(line);
    if (e) out.push({ ...e, end: offset + line.length });
    offset += line.length + 1;
  }
  return out;
}

function build(doc) {
  const items = findEmbeds(doc.toString()).map(e =>
    Decoration.widget({ widget: new EmbedWidget(e.kind, embedSource(e.target), e.caption), block: true, side: 1 })
      .range(e.end));
  return Decoration.set(items);
}

const embedField = StateField.define({
  create: state => build(state.doc),
  update: (decos, tr) => (tr.docChanged ? build(tr.state.doc) : decos),
  provide: f => EditorView.decorations.from(f)
});

export function embedsExtension() {
  return [embedField];
}
