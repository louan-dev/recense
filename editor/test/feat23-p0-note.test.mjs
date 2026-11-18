// Derived from Spec: FEAT-23 P0
// The note on one device: the editor swaps to keep/<key>/note.md, a pane tap writes a moment link, the link plays.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { momentLinks, momentLink, momentAt } from '../src/links.js';
import { createMediaNotes } from '../src/medianote.js';

const read = p => readFileSync(new URL(p, import.meta.url), 'utf8');
const KEY = '0123456789abcdef01234567';
const OTHER = 'fedcba9876543210fedcba98';

test('FEAT-23 P0 check 1: [12:04](recense://<key>?t=724) round-trips: written by a pane tap, parsed back, label ignored', () => {
  const link = momentLink(KEY, 724.9);
  assert.equal(link, `[12:04](recense://${KEY}?t=724)`);
  const [m] = momentLinks(`Holding ${link} here`);
  assert.deepEqual({ key: m.key, t: m.t, label: m.label }, { key: KEY, t: 724, label: '12:04' });
  const [relabelled] = momentLinks(`[the dissent](recense://${KEY}?t=724)`);
  assert.equal(relabelled.t, 724, 'the label is for the eye; only t= is read');
  assert.equal(momentLink(KEY, 3725), `[1:02:05](recense://${KEY}?t=3725)`, 'over an hour the label is h:mm:ss');
});

test('FEAT-23 A2 rule 1: the link grammar counts exactly these, nothing else', () => {
  const ok = [
    `[a](recense://${KEY}?t=12)`, `[a](recense://${KEY})`, `![pic](recense://${KEY})`, `see recense://${KEY}?t=5 now`, `recense://${KEY}`
  ];
  for (const s of ok) assert.equal(momentLinks(s).length, 1, s);
  const bad = [
    `[a](recense://${KEY.toUpperCase()}?t=12)`, `[a](recense://${KEY.slice(1)}?t=12)`, `[a](recense://${KEY}?t=-1)`,
    `[a](recense://${KEY}?t=1.5)`, `[a](recense://${KEY}?t=1&x=2)`, `recense://${KEY}0`
  ];
  for (const s of bad) assert.equal(momentLinks(s).length, 0, s);
  const [img] = momentLinks(`![pic](recense://${KEY})`);
  assert.equal(img.image, true);
  assert.equal(img.t, null);
  const multi = momentLinks(`one [00:01](recense://${KEY}?t=1)\ntwo [00:02](recense://${OTHER}?t=2)`);
  assert.deepEqual(multi.map(x => [x.key, x.t, x.line]), [[KEY, 1, 1], [OTHER, 2, 2]]);
});

test('FEAT-23 rule 5: a tap inside a moment link finds it (column on the line); elsewhere nothing', () => {
  const line = `x [12:04](recense://${KEY}?t=724) y`;
  assert.deepEqual(momentAt(line, 4), { key: KEY, t: 724 });
  assert.deepEqual(momentAt(line, line.indexOf('?t=')), { key: KEY, t: 724 });
  assert.equal(momentAt(line, 0), null);
  assert.equal(momentAt(line, line.length), null);
});

function fakeEditor({ text = 'Draftpad page\n', ink = { version: 1, strokes: [{ id: 'd1' }], removed: [] }, matter = { version: 1, passages: {}, log: [] } } = {}) {
  const posts = [];
  const ed = { text, ink, matter, flushed: 0, history: 0 };
  const notes = createMediaNotes({
    getText: () => ed.text, setText: t => { ed.text = t; },
    getInk: () => ed.ink, setInk: i => { ed.ink = i; },
    getMatter: () => ed.matter, setMatter: m => { ed.matter = m; },
    flush: () => { ed.flushed++; },
    resetHistory: () => { ed.history++; },
    post: (channel, body) => posts.push({ channel, body }),
    now: () => 1000
  });
  return { ed, notes, posts };
}

test('FEAT-23 P0 check 2 (editor): typing in the note never reaches draftpad.md; the host\'s draftpad text waits beside it', () => {
  const { ed, notes, posts } = fakeEditor();
  assert.equal(notes.open(KEY, { text: 'Old note\n', title: 'Song' }), true);
  assert.equal(ed.flushed, 1, 'draftpad\'s pending save went out before the swap');
  assert.equal(ed.history, 1, 'undo never crosses documents');
  assert.equal(ed.text, 'Old note\n');
  assert.deepEqual(ed.ink.strokes, [], 'the note starts with its own ink');
  assert.equal(notes.hostText(), 'Draftpad page\n', 'the host\'s flush still reads draftpad.md');
  ed.text = 'Old note\nnew line\n';
  assert.equal(notes.routeText(ed.text), true, 'the note takes the save');
  assert.deepEqual(posts.at(-1), { channel: 'note', body: { action: 'save', key: KEY, text: 'Old note\nnew line\n' } });
  assert.ok(!posts.some(p => p.channel === 'editor'), 'nothing went to draftpad.md');
  assert.equal(notes.absorbHostText('Draftpad page merged\n'), true, 'a merge of draftpad.md lands beside the note');
  assert.equal(ed.text, 'Old note\nnew line\n', 'the note on screen is unchanged');
  assert.equal(notes.routeInk('{"version":1,"strokes":[],"removed":[]}'), true);
  assert.equal(posts.at(-1).body.action, 'ink');
  assert.equal(notes.routeMatter('{"version":1,"passages":{},"log":[]}'), true);
  assert.equal(posts.at(-1).body.action, 'matter');
  notes.close();
  assert.equal(ed.text, 'Draftpad page merged\n', 'draftpad.md comes back with what arrived meanwhile');
  assert.deepEqual(ed.ink.strokes, [{ id: 'd1' }], 'and its ink');
  assert.equal(notes.routeText('Draftpad page merged!\n'), false, 'closed: saves go to draftpad.md again');
  assert.equal(notes.absorbHostText('x'), false);
});

test('FEAT-23 rule 3: one document at a time; a second note swaps the first out, draftpad stays stashed once', () => {
  const { ed, notes } = fakeEditor();
  notes.open(KEY, { text: 'A\n' });
  notes.open(OTHER, { text: 'B\n' });
  assert.equal(notes.key(), OTHER);
  assert.equal(ed.text, 'B\n');
  notes.close();
  assert.equal(ed.text, 'Draftpad page\n', 'the stash is draftpad, never note A');
  assert.equal(notes.open('BAD', { text: 'x' }), false, 'a key that is not 24 lowercase hex opens nothing');
});

test('FEAT-23 P0: a pane tap writes [mm:ss](recense://<key>?t=<s>) then a space, only while a note is open', () => {
  const { notes } = fakeEditor();
  assert.equal(notes.linkForLine({ start: 724.6 }), null);
  notes.open(KEY, { text: '' });
  assert.equal(notes.linkForLine({ start: 724.6 }), `[12:04](recense://${KEY}?t=724) `);
});

test('FEAT-23 P0: the editor wires the note: bridge calls, routes, link taps play, hosts store keep/<key>/note.md', () => {
  const idx = read('../src/index.js');
  for (const k of ['openNote:', 'closeNote:', 'noteKey:', 'createMediaNotes(', 'routeInk:', "playMedia(m.key, m.t, 'link')"]) {
    assert.ok(idx.includes(k), `index.js has ${k}`);
  }
  assert.ok(read('../src/bridge.js').includes('routeText'), 'the bridge asks the note before posting to draftpad.md');
  for (const p of ['../../strip/editorhost.swift', '../../mobile/HostApp/iOS/Draftpad.swift']) {
    const s = read(p);
    assert.ok(/"matter", "note"/.test(s) || /"note"/.test(s), `${p} listens on the note channel`);
    assert.ok(s.includes('MediaNoteFiles'), `${p} stores notes through the shared MediaNoteFiles`);
    assert.ok(s.includes('func openNote('), `${p} can open a note`);
  }
  const shared = read('../../shared/medianotefiles.swift');
  assert.ok(shared.includes('"note.md"') && shared.includes('trashItem'), 'one file per item; clearing goes through the Trash');
});
