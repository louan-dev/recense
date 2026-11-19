// Regression guard: FEAT-23 review of work/a2-underlay @ d2aac81 (items 1, 3, 4, 5, 7)
import test from 'node:test';
import assert from 'node:assert/strict';
import { EditorState } from '@codemirror/state';
import { createEditorBridge } from '../src/bridge.js';
import { createMediaNotes } from '../src/medianote.js';
import { createAudioSidecar } from '../src/audio.js';

const KEY = '0123456789abcdef01234567';

function rig({ handler = true } = {}) {
  const posts = [];
  const ed = { text: 'Draftpad page\n', ink: { version: 1, strokes: [], removed: [] }, matter: { version: 1, passages: {}, log: [] } };
  let pending = null;   // the page's 300 ms debounce, as the bridge holds it
  const notes = createMediaNotes({
    getText: () => ed.text, setText: t => { ed.text = t; },
    getInk: () => ed.ink, setInk: i => { ed.ink = i; },
    getMatter: () => ed.matter, setMatter: m => { ed.matter = m; },
    flush: () => { if (pending !== null) { const t = pending; pending = null; notes.routeText(t); } },
    resetHistory: () => {},
    post: (channel, body) => { if (!handler) return false; posts.push({ channel, body }); return true; },
    now: () => 0,
    log: () => {}
  });
  return { ed, notes, posts, type: t => { ed.text = t; pending = t; } };
}

test('review 1: a host text deferred mid-drag lands beside the note, never in it', () => {
  let state = EditorState.create({ doc: 'Draftpad page\n' });
  let dragging = true;
  const ed = { text: () => state.doc.toString() };
  const notes = createMediaNotes({
    getText: ed.text, setText: t => { state = state.update({ changes: { from: 0, to: state.doc.length, insert: t } }).state; },
    getInk: () => ({ version: 1, strokes: [], removed: [] }), setInk: () => {},
    getMatter: () => ({ version: 1, passages: {}, log: [] }), setMatter: () => {},
    post: () => true, log: () => {}
  });
  const posted = [];
  const bridge = createEditorBridge({
    getState: () => state, dispatch: spec => { state = state.update(spec).state; },
    isSelecting: () => dragging,
    routeText: t => notes.routeText(t), hostText: () => notes.hostText(), absorbText: t => notes.absorbHostText(t),
    globalObj: { webkit: { messageHandlers: { editor: { postMessage: t => posted.push(t) } } } }
  });
  bridge.api.setText('DRAFT merged from iPad');
  notes.open(KEY, { text: 'MY NOTE' });
  dragging = false;
  bridge.applyDeferredText();
  assert.equal(state.doc.toString(), 'MY NOTE', 'the note on screen is untouched');
  assert.equal(notes.stash().text, 'DRAFT merged from iPad');
});

test('review 3: the host\'s flush of draftpad.md first sends the note\'s pending typing to the note', () => {
  const { notes, posts, type } = rig();
  notes.open(KEY, { text: '' });
  type('typed under 300 ms');
  assert.equal(notes.hostText(), 'Draftpad page\n');
  assert.deepEqual(posts.find(p => p.body.action === 'save').body.text, 'typed under 300 ms');
});

test('review 4: with no note handler (web, PWA) a line note is not claimed, so the page keeps it', () => {
  const { notes } = rig({ handler: false });
  assert.equal(notes.lineNote(KEY, 4, 'x'), null);
  const seen = [];
  const sidecar = createAudioSidecar({
    cues: [{ id: 'c0', start: 4, end: 6, text: 'held' }],
    onInsertToPage: s => seen.push(s),
    onLineNote: ({ start, text }) => Boolean(notes.lineNote(KEY, start, text)),
    globalObj: null
  });
  sidecar.annotateCue(0, 'x', { lineNote: true });
  assert.equal(seen.length, 1, 'the insertBlock path ran');
});

test('review 5: strokes alone make the note written; erased, it goes to the Trash', () => {
  const { ed, notes, posts } = rig();
  notes.open(KEY, { text: '' });
  ed.ink = { version: 1, strokes: [{ id: 's1' }], removed: [] };
  notes.routeInk(JSON.stringify(ed.ink));
  ed.ink = { version: 1, strokes: [], removed: [] };
  notes.routeInk(JSON.stringify(ed.ink));
  assert.equal(notes.blur(), 'trashed');
  assert.ok(posts.some(p => p.body.action === 'trash'));
});

test('review 7: an empty annotation with no item key still quotes the line into the page once', () => {
  const seen = [];
  const sidecar = createAudioSidecar({
    cues: [{ id: 'c0', start: 4, end: 6, text: 'held' }],
    onInsertToPage: s => seen.push(s),
    onLineNote: () => false,
    globalObj: null
  });
  sidecar.annotateCue(0, '', { lineNote: true });
  assert.equal(seen.length, 1);
});
