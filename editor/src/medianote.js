// Derived from Spec: FEAT-23
// One note per media item, inside Draftpad (docs/specs/FEAT-23-media-notes.md). The one home of its rules:
// the hosts (strip/editorhost.swift, mobile/HostApp/iOS/Draftpad.swift) only read and write the files.
//
// Rule 3: one editor, one document at a time. Opening a note swaps the document in the editor that is open; draftpad.md
// waits beside it (its text, ink and sidecar), and anything the host hands draftpad.md meanwhile (a merge from another
// device) lands there, never in the note. While a note is open every save goes to the host's `note` channel, keyed by
// the item's key; nothing goes to draftpad.md (rule 2). Pure: no DOM; index.js gives it the editor's hands.
import { momentLink } from './links.js';
import { logEvent } from './logevent.js';

export const KEY_RE = /^[0-9a-f]{24}$/;
const emptyInk = () => ({ version: 1, strokes: [], removed: [] });
const emptySide = () => ({ version: 1, passages: {}, log: [] });
const parse = (v, d) => {
  if (v && typeof v === 'object') return v;
  if (typeof v === 'string' && v.trim()) { try { return JSON.parse(v); } catch { return d(); } }
  return d();
};

/**
 * deps: getText, setText (no save, no undo), getInk, setInk, getMatter, setMatter, flush (the page's pending saves go
 * now), resetHistory (undo never crosses documents), post(channel, body), now() in ms, log(name, fields).
 */
export function createMediaNotes(deps) {
  const now = deps.now || (() => Date.now());
  const log = deps.log || logEvent;
  let note = null;      // { key, title, openedAt }
  let stash = null;     // draftpad.md while a note is shown: { text, ink, matter }

  function post(action, body) { deps.post('note', { action, key: note.key, ...body }); }

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
    note = { key, title: String(payload.title || ''), openedAt: now() };
    show(text, parse(payload.ink, emptyInk), parse(payload.matter, emptySide));
    log('media-notes.underlay.open', { key, trigger: String(payload.trigger || 'note-button'), hasNote: /\S/.test(text) ? 1 : 0 });
    return true;
  }

  function closeQuietly() {
    if (deps.flush) deps.flush();              // the note's own pending saves still go to the note
    note = null;
  }

  /** Puts draftpad.md back, with whatever reached it while the note was shown. */
  function close() {
    if (!note) return false;
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
    hostText: () => (note ? stash.text : deps.getText()),
    /** The host handed draftpad.md new text (a save's merge, a poll): kept beside the note. True = taken. */
    absorbHostText(text) { if (!note) return false; stash.text = String(text ?? ''); return true; },
    absorbHostInk(ink) { if (!note) return false; stash.ink = parse(ink, emptyInk); return true; },
    absorbHostMatter(side) { if (!note) return false; stash.matter = parse(side, emptySide); return true; },
    stash: () => stash,
    /** The page's debounced save. True = it was the note's (posted to `note`), so draftpad.md gets nothing. */
    routeText(text) {
      if (!note) return false;
      post('save', { text: String(text ?? '') });
      return true;
    },
    routeInk(json) { if (!note) return false; post('ink', { json: String(json) }); return true; },
    routeMatter(json) { if (!note) return false; post('matter', { json: String(json) }); return true; },
    /** Rule 5: a tapped transcript line's moment link, written at the caret then a space; null with no note. */
    linkForLine(cue) {
      if (!note || !cue) return null;
      return `${momentLink(note.key, cue.start)} `;
    }
  };
}
