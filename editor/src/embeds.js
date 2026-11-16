// Inline embeds: a line that holds only `![caption](target)` shows the PDF, image or recording under it. The text stays plain
// Markdown (Obsidian reads the same line). Inside Recense, targets go through the host's `recense-file:` scheme,
// which serves a vault file or a cached copy of a web file, so an embed opened once opens again offline.
import { StateField } from '@codemirror/state';
import { Decoration, EditorView, WidgetType } from '@codemirror/view';
// FEAT-19 P4: a recording plays in the note with the player's Lock Screen rules (the player's one home)
import { nowPlaying } from '../../library/src/client/nowplaying.js';

// `![caption](path)`, or `![caption](<path with spaces>)` as CommonMark and Obsidian write it.
const EMBED_RE = /^\s*!\[([^\]]*)\]\((?:<([^>]+)>|([^)\s]+))\)\s*$/;
const PDF_RE = /\.pdf(?:[?#].*)?$/i;
const IMAGE_RE = /\.(?:png|jpe?g|gif|webp|heic|svg)(?:[?#].*)?$/i;
const AUDIO_RE = /\.(?:m4a|mp3|wav|aac|aiff?|caf|flac|ogg|oga|opus)(?:[?#].*)?$/i;
const VIDEO_RE = /\.(?:mp4|m4v|mov|webm)(?:[?#].*)?$/i;

/** pdf, image, audio or video by the target's extension; null for anything else (a plain link stays a link). */
export function embedKind(target) {
  return PDF_RE.test(target) ? 'pdf' : IMAGE_RE.test(target) ? 'image'
    : AUDIO_RE.test(target) ? 'audio' : VIDEO_RE.test(target) ? 'video' : null;
}

export function parseEmbedLine(line) {
  const m = EMBED_RE.exec(line);
  if (!m) return null;
  const target = m[2] ?? m[3];
  const kind = embedKind(target);
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
  constructor(kind, src, caption, rawTarget = '') {
    super();
    this.kind = kind;
    this.src = src;
    this.caption = caption;
    this.rawTarget = rawTarget;
  }
  eq(other) { return other.kind === this.kind && other.src === this.src && other.rawTarget === this.rawTarget; }
  get estimatedHeight() { return this.kind === 'pdf' ? 520 : this.kind === 'audio' ? 72 : 320; }
  toDOM() {
    const wrap = document.createElement('div');
    wrap.className = `cm-embed cm-embed-${this.kind}`;
    if (this.rawTarget) wrap.setAttribute('data-embed-target', this.rawTarget);
    if (this.kind === 'pdf') {
      const frame = document.createElement('iframe');
      frame.src = this.src;
      frame.title = this.caption || 'PDF';
      frame.loading = 'lazy';
      wrap.appendChild(frame);
    } else if (this.kind === 'audio' || this.kind === 'video') {
      // A recording: plays here, goes on with the screen locked or the app left, and the Lock Screen shows its
      // name and a scrubber that seeks (FEAT-19 P4). Its name is the caption, else the file's name.
      if (this.kind === 'audio' && this.caption) {
        const label = document.createElement('div');
        label.className = 'cm-embed-caption';
        label.textContent = this.caption;
        wrap.appendChild(label);
      }
      wrap.appendChild(recording(this.kind, this.src, this.caption || nameOf(this.rawTarget)));
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
  destroy(dom) {
    const m = dom.querySelector('audio,video');
    if (m) keepOrStop(m);
  }
}

// A recording's element outlives its widget: CodeMirror removes a widget scrolled far out of view, and a removed
// element stops. So a playing one moves to a hidden holder in the page (it plays on, the Lock Screen keeps it) and
// comes back when its line is drawn again; one not playing stops and gives the Lock Screen back.
const live = new Map(); // src → { m, np }
let holder = null;

function nameOf(target) {
  let base = String(target || '').split(/[\\/]/).pop().replace(/[?#].*$/, '');
  try { base = decodeURIComponent(base); } catch { /* as written */ }
  return base.replace(/\.[^.]+$/, '');
}

function recording(kind, src, title) {
  const had = live.get(src);
  if (had && (!had.m.isConnected || had.m.parentNode === holder)) return had.m;
  const m = document.createElement(kind);
  m.controls = true;
  m.preload = 'metadata';
  if (kind === 'video') m.setAttribute('playsinline', '');
  m.src = src;
  const np = nowPlaying(m, { title });
  if (!had) live.set(src, { m, np });
  m.recense = { src, np };
  return m;
}

function keepOrStop(m) {
  if (!m.paused && typeof document !== 'undefined') {
    if (!holder) {
      holder = document.createElement('div');
      holder.hidden = true;
      holder.className = 'cm-embed-holder';
      document.body.appendChild(holder);
    }
    holder.appendChild(m); // in the same task as the removal, so it never pauses
    return;
  }
  m.pause();
  const r = m.recense;
  if (r) {
    r.np.drop();
    if (live.get(r.src)?.m === m) live.delete(r.src);
  }
}

export function formatDroppedEmbed(nameOrPath, explicitCaption = null) {
  const raw = String(nameOrPath ?? '').trim();
  if (!raw) return null;
  if (!embedKind(raw)) return null;
  const base = raw.split(/[\\/]/).pop().replace(/[?#].*$/, '');
  const caption = explicitCaption !== null
    ? String(explicitCaption)
    : base.replace(/\.[^.]+$/, '');
  const target = /\s/.test(raw) ? `<${raw}>` : raw;
  return `![${caption}](${target})`;
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
    Decoration.widget({ widget: new EmbedWidget(e.kind, embedSource(e.target), e.caption, e.target), block: true, side: 1 })
      .range(e.end));
  return Decoration.set(items);
}

const embedField = StateField.define({
  create: state => build(state.doc),
  update: (decos, tr) => (tr.docChanged ? build(tr.state.doc) : decos),
  provide: f => EditorView.decorations.from(f)
});

const embedDropHandler = EditorView.domEventHandlers({
  dragover(event) {
    const dt = event?.dataTransfer;
    if (dt && (dt.files?.length > 0 || dt.types?.includes?.('Files'))) {
      event.preventDefault();
      return true;
    }
    return false;
  },
  drop(event, view) {
    const dt = event?.dataTransfer;
    if (!dt) return false;
    const embeds = [];
    if (dt.files && dt.files.length > 0) {
      for (const f of Array.from(dt.files)) {
        const md = formatDroppedEmbed(f.path || f.name, f.name ? f.name.replace(/\.[^.]+$/, '') : null);
        if (md) embeds.push(md);
      }
    } else if (typeof dt.getData === 'function') {
      const uri = dt.getData('text/uri-list') || dt.getData('text/plain');
      const md = formatDroppedEmbed(uri);
      if (md) embeds.push(md);
    }
    if (embeds.length === 0) return false;
    event.preventDefault();
    const pos = view.state.selection.main.head;
    const line = view.state.doc.lineAt(pos);
    const prefix = line.text.trim().length > 0 ? '\n' : '';
    const insert = `${prefix}${embeds.join('\n')}`;
    view.dispatch({
      changes: { from: line.to, insert },
      selection: { anchor: line.to + insert.length },
      scrollIntoView: true,
      userEvent: 'input.drop'
    });
    return true;
  }
});

export function embedsExtension() {
  return [embedField, embedDropHandler];
}
