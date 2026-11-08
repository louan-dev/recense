// Draftpad's page library: ephemeral pages (Recense's 14-day episode rule), the saved bookmark, playlists.
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  PAGE_KEEP_DAYS, DAY_MS, daysLeft, expiredPageIndices, removePages, setPageSaved, savedPages, pageSavedId,
  findPageById, pageBody, pageTitle, emptyPlaylists, parsePlaylists, createPlaylist, addToPlaylist,
  removeFromPlaylist, editPlaylist, playlistSummary, playlistsWith, pageKey, todayKey, mergeEdited
} from '../src/library.js';
import { inspectDraftpadPages, findPageDecorations } from '../src/pages.js';

const J = '\n\n<!-- page -->\n\n';
const now = Date.UTC(2026, 10, 8, 18, 0, 0);
const doc = [
  'Sunday, November 8, 2026\n\nToday notes',
  'Saturday, October 24, 2026\n\nTwo weeks and a day ago',
  'Monday, October 26, 2026\n\nThirteen days ago',
  'Undated page\nkept forever'
].join(J);

test('a page lives 14 days from its date heading, like a new episode', () => {
  assert.equal(PAGE_KEEP_DAYS, 14);
  const pages = inspectDraftpadPages(doc);
  assert.equal(daysLeft(pages[1], now), 0);
  assert.equal(daysLeft(pages[2], now), 1);
  assert.equal(daysLeft(pages[3], now), null, 'no date: never expires');
  assert.deepEqual(expiredPageIndices(doc, { now }), [1]);
});

test('a page edited recently lives 14 days from that edit (coordinator: work in progress never expires)', () => {
  const pages = inspectDraftpadPages(doc);
  const key = pageKey(pages, 1);
  assert.equal(key, 'Saturday, October 24, 2026#0');
  assert.deepEqual(expiredPageIndices(doc, { now, edited: { [key]: '2026-11-01' } }), []);
  assert.equal(daysLeft(pages[1], now, '2026-11-01'), 7);
  assert.deepEqual(expiredPageIndices(doc, { now, edited: { [key]: '2026-10-20' } }), [1], 'an older edit changes nothing');
  assert.equal(todayKey(new Date(2026, 10, 8, 23).getTime()), '2026-11-08');
  assert.deepEqual(mergeEdited({ a: '2026-11-01', b: '2026-11-05' }, { a: '2026-11-03', c: '2026-11-02' }),
    { a: '2026-11-03', b: '2026-11-05', c: '2026-11-02' });
});

test('the newest page and the page on screen never expire', () => {
  const old = ['Saturday, October 3, 2026\n\nold top', 'Friday, October 2, 2026\n\nold'].join(J);
  assert.deepEqual(expiredPageIndices(old, { now }), [1]);
  assert.deepEqual(expiredPageIndices(old, { now, keepIndex: 1 }), []);
});

test('saving writes a hidden line under the heading; saved pages never expire; unsaving restores the bytes', () => {
  const r = setPageSaved(doc, 1, true, { id: 'abc123' });
  assert.equal(r.id, 'abc123');
  assert.match(r.text, /Saturday, October 24, 2026\n<!-- saved abc123 -->\n\nTwo weeks/);
  const pages = inspectDraftpadPages(r.text);
  assert.equal(pageSavedId(pages[1]), 'abc123');
  assert.equal(pages[1].dateLine, 'Saturday, October 24, 2026', 'heading still parsed');
  assert.equal(pageBody(pages[1]), 'Two weeks and a day ago');
  assert.deepEqual(expiredPageIndices(r.text, { now }), []);
  assert.equal(findPageById(r.text, 'abc123').index, 1);
  const back = setPageSaved(r.text, 1, false);
  assert.equal(back.text, doc);
});

test('an undated page is saved on its first line, and its title skips the hidden line', () => {
  const r = setPageSaved(doc, 3, true, { id: 'zz9900' });
  const p = inspectDraftpadPages(r.text)[3];
  assert.equal(pageSavedId(p), 'zz9900');
  assert.equal(pageTitle(p), 'Undated page');
  assert.equal(setPageSaved(r.text, 3, false).text, doc);
  const { metaLines } = findPageDecorations(r.text);
  assert.equal(metaLines.length, 1, 'the hidden line is found for the editor to hide');
});

test('savedPages lists saved pages with titles', () => {
  const r = setPageSaved(doc, 2, true, { id: 'qq1122' });
  assert.deepEqual(savedPages(r.text).map(s => [s.id, s.index, s.title]), [['qq1122', 2, 'Thirteen days ago']]);
});

test('removing an expired page keeps the others byte for byte', () => {
  const { text, removed } = removePages(doc, [1]);
  assert.equal(removed.length, 1);
  assert.equal(text, [doc.split(J)[0], doc.split(J)[2], doc.split(J)[3]].join(J));
  assert.equal(removePages('only one', [0]).text, 'only one', 'never removes the last page');
});

test('playlists: items append at the end, no duplicates, remove without asking, listening time', () => {
  let st = emptyPlaylists();
  const c = createPlaylist(st, 'Contracts', { rand: () => 0.1 });
  st = c.state;
  const saved = setPageSaved(setPageSaved(doc, 1, true, { id: 'aaaaaa' }).text, 2, true, { id: 'bbbbbb' }).text;
  st = addToPlaylist(st, c.playlist.id, { kind: 'page', ref: 'aaaaaa' });
  st = addToPlaylist(st, c.playlist.id, { kind: 'page', ref: 'bbbbbb' });
  st = addToPlaylist(st, c.playlist.id, { kind: 'page', ref: 'aaaaaa' });
  assert.deepEqual(st.playlists[0].items.map(i => i.ref), ['aaaaaa', 'bbbbbb']);
  assert.equal(playlistSummary(st.playlists[0], saved), '2 pages · 1 min');
  assert.deepEqual(playlistsWith(st, 'bbbbbb'), [c.playlist.id]);
  st = removeFromPlaylist(st, c.playlist.id, 'aaaaaa');
  assert.deepEqual(st.playlists[0].items.map(i => i.ref), ['bbbbbb']);
  st = editPlaylist(st, c.playlist.id, { name: 'Contracts I', description: 'serene' });
  assert.equal(st.playlists[0].name, 'Contracts I');
  const round = parsePlaylists(JSON.stringify(st));
  assert.deepEqual(round, st);
  assert.deepEqual(parsePlaylists('not json'), emptyPlaylists());
});

test('DAY_MS is a day', () => assert.equal(DAY_MS, 86400000));
