// Derived from Spec: FEAT-23
// One note per media item, inside Draftpad (docs/specs/FEAT-23-media-notes.md). The one home of its rules:
// the hosts (strip/editorhost.swift, mobile/HostApp/iOS/Draftpad.swift) only read and write the files.
//
// Rule 3: one editor, one document at a time. Opening a note swaps the document in the editor that is open; draftpad.md
// waits beside it (its text, ink and sidecar), and anything the host hands draftpad.md meanwhile (a merge from another
// device) lands there, never in the note. While a note is open every save goes to the host's `note` channel, keyed by
// the item's key; nothing goes to draftpad.md (rule 2). Pure: no DOM; index.js gives it the editor's hands.
import { momentLink, momentLinks } from './links.js';
import { activeCueIndexAt, normalizeCues } from './audio.js';
import { logEvent } from './logevent.js';

export const KEY_RE = /^[0-9a-f]{24}$/;
const emptyInk = () => ({ version: 1, strokes: [], removed: [] });
const emptySide = () => ({ version: 1, passages: {}, log: [] });
const isBlank = t => !/\S/.test(String(t ?? ''));
const strokesOf = ink => (ink && Array.isArray(ink.strokes) ? ink.strokes.length : 0);
const parse = (v, d) => {
  if (v && typeof v === 'object') return v;
  if (typeof v === 'string' && v.trim()) { try { return JSON.parse(v); } catch { return d(); } }
  return d();
};

/**
 * deps: getText, setText (no save, no undo), getInk, setInk, getMatter, setMatter, flush (the page's pending saves go
 * now), resetHistory (undo never crosses documents), unlockPages (posts { pagesLocked: false }), post(channel, body),
 * now() in ms, log(name, fields).
 */
export function createMediaNotes(deps) {
  const now = deps.now || (() => Date.now());
  const log = deps.log || logEvent;
  // { key, title, openedAt, written (note.md holds words), input (what made the first one), dictating }
  let note = null;
  let stash = null;     // draftpad.md while a note is shown: { text, ink, matter }

  // True when a host handler took it (review 4: web / PWA have none).
  function post(action, body) { return deps.post('note', { action, key: note.key, ...body }) !== false; }

  function show(text, ink, matter) {
    deps.setText(text);
    deps.setInk(ink);
    deps.setMatter(matter);
    if (deps.resetHistory) deps.resetHistory();
  }

  /** Shows the note of item `key` ({ text, ink, matter, title, trigger }); false for a key that is not one. */
  function open(key, payload = {}) {
    if (typeof key !== 'string' || !KEY_RE.test(key)) return false;
    if (deps.flush) deps.flush();              // what was typed waits for no swap (A1 rule 11)
    if (note) closeQuietly();
    else stash = { text: deps.getText(), ink: deps.getInk(), matter: deps.getMatter() };
    const text = typeof payload.text === 'string' ? payload.text : '';
    const ink = parse(payload.ink, emptyInk);
    note = { key, title: String(payload.title || ''), openedAt: now(), written: !isBlank(text) || strokesOf(ink) > 0,
      input: 'type', dictating: false, layout: String(payload.layout || 'note') };
    show(text, ink, parse(payload.matter, emptySide));
    log('media-notes.underlay.open', { key, trigger: String(payload.trigger || 'note-button'), hasNote: /\S/.test(text) ? 1 : 0 });
    return true;
  }

  // A1 rule 3 · empty = no character that is not whitespace, no stroke, no dictation running.
  const isEmpty = () => isBlank(deps.getText()) && strokesOf(deps.getInk()) === 0 && !note.dictating;

  /** Focus left the note (another control, the player closing, the item changing, the app going away). */
  function blur() {
    if (!note) return 'none';
    if (deps.flush) deps.flush();
    if (!isEmpty()) return 'kept';
    if (!note.written) return 'none';         // nothing was ever written: nothing to remove (rule 8)
    note.written = false;
    deps.post('note', { action: 'trash', key: note.key });   // note.md and its sidecars to the Trash; never the media
    log('media-notes.underlay.empty', { key: note.key, outcome: 'trashed' });
    return 'trashed';
  }

  function closeQuietly() {
    blur();                                    // flushes first: the note's own pending saves still go to the note
    note = null;
  }

  /** Puts draftpad.md back, with whatever reached it while the note was shown. */
  function close() {
    if (!note) return false;
    if (deps.unlockPages) deps.unlockPages();  // A1 rule 10: no recognizer stays off when the region hides
    closeQuietly();
    const s = stash;
    stash = null;
    show(s.text, s.ink, s.matter);
    return true;
  }

  return {
    open,
    close,
    isOpen: () => !!note,
    key: () => (note ? note.key : null),
    title: () => (note ? note.title : ''),
    /** What the host's flush of draftpad.md reads: draftpad's text, also while a note is shown. */
    hostText: () => {
      if (!note) return deps.getText();
      if (deps.flush) deps.flush();     // review 3: the note's pending typing reaches the note first
      return stash.text;
    },
    /** The host handed draftpad.md new text (a save's merge, a poll): kept beside the note. True = taken. */
    absorbHostText(text) { if (!note) return false; stash.text = String(text ?? ''); return true; },
    absorbHostInk(ink) { if (!note) return false; stash.ink = parse(ink, emptyInk); return true; },
    absorbHostMatter(side) { if (!note) return false; stash.matter = parse(side, emptySide); return true; },
    stash: () => stash,
    /**
     * The page's debounced save. True = it was the note's, so draftpad.md gets nothing. A1 rule 2: note.md is first
     * written by the first save holding a character that is not whitespace; whitespace alone writes nothing.
     */
    routeText(text) {
      if (!note) return false;
      const s = String(text ?? '');
      if (!note.written) {
        if (isBlank(s)) return true;
        note.written = true;
        log('media-notes.underlay.first', { key: note.key, input: note.input, ms: now() - note.openedAt });
      }
      post('save', { text: s });
      log('media-notes.save', { key: note.key, bytes: s.length, strokes: strokesOf(deps.getInk()),
        links: momentLinks(s).filter(m => m.key === note.key).length, ms: 0 });
      return true;
    },
    routeInk(json) {
      if (!note) return false;
      const strokes = strokesOf(parse(json, emptyInk));
      if (!note.written && strokes === 0) return true;   // no empty sidecar is made
      if (!note.written) {                                // review 5: strokes alone are a written note
        note.written = true;
        log('media-notes.underlay.first', { key: note.key, input: 'ink', ms: now() - note.openedAt });
      }
      post('ink', { json: String(json) });
      return true;
    },
    routeMatter(json) {
      if (!note) return false;
      if (note.written || strokesOf(deps.getInk()) > 0) post('matter', { json: String(json) });
      return true;
    },
    blur,
    /** What made the next first note: 'type', 'ink' or 'dictate' (for the log). */
    setInput(kind) { if (note) note.input = String(kind); },
    /** A1 rule 2: a partial result writes nothing (null); a final one is the text to write at the caret. */
    dictation(text, final) {
      if (!note || !final) return null;
      const s = String(text ?? '');
      if (isBlank(s)) return null;
      note.input = 'dictate';
      return s;
    },
    dictationRunning(on) { if (note) note.dictating = Boolean(on); },
    layout: () => (note ? note.layout : ''),
    /** Every second this note ties to this item: its moment links, its passages' and strokes' note times (sorted). */
    noteTimes() {
      if (!note) return [];
      const times = momentLinks(deps.getText()).filter(m => m.key === note.key && m.t !== null).map(m => m.t);
      for (const st of (deps.getInk() || {}).strokes || []) if (Number.isFinite(st.t)) times.push(st.t);
      for (const p of Object.values((deps.getMatter() || {}).passages || {})) {
        const md = p && p.seed && p.seed.media;
        if (md && md.key === note.key && Number.isFinite(md.t)) times.push(md.t);
      }
      return times.sort((a, b) => a - b);
    },
    /**
     * A1 rule 8 · new lines from the host: the line each note time sits beside, recomputed. Every tie is a time in
     * seconds, so nothing is written: [{ t, line }]. Ticks and quiet marks (P1) read the same list.
     */
    reweave(cues, reason = 'load') {
      if (!note) return [];
      const t0 = now();
      const lines = normalizeCues(cues);
      const out = this.noteTimes().map(t => ({ t, line: activeCueIndexAt(lines, t) }));
      log('media-notes.reweave', { key: note.key, lines: lines.length, times: out.length, ms: now() - t0, reason });
      return out;
    },
    /**
     * A1 rule 9 · a transcript line's note (or a bookmark: no text) joins item `key`'s note as
     * `[mm:ss](recense://<key>?t=<s>) <text>`. Open: { insert } for the page to write; else the host appends it
     * ({ append }). null with no item key. Nothing is keyed by cueId.
     */
    lineNote(key, start, text) {
      if (typeof key !== 'string' || !KEY_RE.test(key)) return null;
      const t = String(text ?? '').trim();
      const line = t ? `${momentLink(key, start)} ${t}` : momentLink(key, start);
      if (note && note.key === key) return { insert: line };
      if (deps.post('note', { action: 'append', key, line }) === false) return null;   // review 4: no store here
      return { append: line };
    },
    /** Rule 5: a tapped transcript line's moment link, written at the caret then a space; null with no note. */
    linkForLine(cue) {
      if (!note || !cue) return null;
      return `${momentLink(note.key, cue.start)} `;
    }
  };
}
