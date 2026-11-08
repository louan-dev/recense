// Draftpad's page library: every page is ephemeral like a new Recense episode, unless saved.
//
// · A page lives 14 days (Rules.newKeepDays in shared/ShowsKit, the same 14 days a new episode keeps its media) from
//   the later of the date in its heading and its last edit (coordinator, 2026-11-08: a page still being written must
//   never expire). Last edits are kept per page in draftpad.pages.json: { "edited": { "<heading>#<n>": "YYYY-MM-DD" } },
//   keyed by the date heading and which page with that heading it is. Pages without a date heading never expire.
// · Saving a page writes one hidden line right under its heading:  <!-- saved k3x9q2 -->  (plain text: it syncs with
//   the note, Obsidian hides it in reading view, and the id lets playlists and the Saved list find the page again).
// · Playlists live beside the note in draftpad.playlists.json (format below), modelled on the playlist research
//   (~/.claude/context/recense/research/playlist-ios/NOTES.md): one owner or shared, items appended at the end,
//   mixed kinds, removal without asking.
//
// draftpad.playlists.json
//   { "version": 1,
//     "playlists": [ { "id": "pl-…", "name": "Contracts", "description": "", "private": true,
//                      "owner": "me", "collaborators": [], "created": "<ISO>", "updated": "<ISO>",
//                      "items": [ { "kind": "page", "ref": "<page id>", "added": "<ISO>", "addedBy": "me",
//                                   "note": "" } ] } ] }
//   kind: "page" (ref = page id), "episode" (ref = Recense content key), "audio" (ref = vault path). Only pages are
//   added from Draftpad today; the other kinds are kept as they are so Recense can share the same file.

import { inspectDraftpadPages, META_RE, isMetaLine } from './pages.js';

export { META_RE, isMetaLine };

export const PAGE_KEEP_DAYS = 14;
export const DAY_MS = 86_400_000;
/** Words a minute when a page is read aloud (Recense's read-aloud pace), for a playlist's listening time. */
export const LISTEN_WPM = 150;

export function newPageId(rand = Math.random) {
  let s = '';
  const abc = 'abcdefghijklmnopqrstuvwxyz0123456789';
  for (let i = 0; i < 6; i++) s += abc[Math.floor(rand() * abc.length) % abc.length];
  return s;
}

/** The page's saved id, or null. */
export function pageSavedId(page) {
  if (!page) return null;
  for (const line of String(page.rawContent || '').split('\n')) {
    const m = META_RE.exec(line.trim());
    if (m) return m[1];
  }
  return null;
}

/** The page's text without its date heading and hidden lines (what a reader or listener gets). */
export function pageBody(page) {
  const lines = String(page?.rawContent || '').split('\n').filter(l => !isMetaLine(l));
  if (page?.dateLine) {
    const k = lines.findIndex(l => l.trim() === page.dateLine);
    if (k >= 0) lines.splice(k, 1);
  }
  return lines.join('\n').trim();
}

export function wordCount(text) {
  const m = String(text || '').match(/[\p{L}\p{N}][\p{L}\p{N}'’-]*/gu);
  return m ? m.length : 0;
}

/** A page's key in draftpad.pages.json: its date heading and which page with that heading it is (null: undated). */
export function pageKey(pages, index) {
  const p = pages[index];
  if (!p || !p.dateLine) return null;
  let n = 0;
  for (let i = 0; i < index; i++) if (pages[i].dateLine === p.dateLine) n++;
  return `${p.dateLine}#${n}`;
}

/** "YYYY-MM-DD" (local day) → ms at noon UTC of that day, like a date heading; anything else → null. */
export function editedMs(day) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(day || ''));
  return m ? Date.UTC(+m[1], +m[2] - 1, +m[3], 12) : null;
}

export function todayKey(now = Date.now()) {
  const d = new Date(now);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

/** The day the 14 days count from: the later of the heading's date and the last edit. */
export function lifeStart(page, edited) {
  const e = editedMs(edited);
  return e !== null && e > page.dateMs ? e : page.dateMs;
}

/** Whole days left before the page expires (0 = expires today or already due), or null when it never expires. */
export function daysLeft(page, now = Date.now(), edited = null) {
  if (!page || pageSavedId(page) || typeof page.dateMs !== 'number') return null;
  const end = lifeStart(page, edited) + PAGE_KEEP_DAYS * DAY_MS;
  return Math.max(0, Math.ceil((end - now) / DAY_MS));
}

/** Two devices' edit days merged: the later day wins for each page. */
export function mergeEdited(a = {}, b = {}) {
  const out = { ...a };
  for (const [k, v] of Object.entries(b || {})) if (!out[k] || String(v) > String(out[k])) out[k] = v;
  return out;
}

/**
 * Indices of pages that have expired: 14 days or more since the later of their date and last edit (`edited`, keyed
 * by pageKey), not saved, never the newest page and never `keepIndex` (the one on screen).
 */
export function expiredPageIndices(text, { now = Date.now(), keepIndex = -1, edited = {} } = {}) {
  const pages = inspectDraftpadPages(text);
  const out = [];
  for (const p of pages) {
    if (p.index === 0 || p.index === keepIndex) continue;
    if (typeof p.dateMs !== 'number') continue;
    if (pageSavedId(p)) continue;               // saved, or in a playlist (adding to one saves the page)
    const start = lifeStart(p, edited[pageKey(pages, p.index)]);
    if (now - start >= PAGE_KEEP_DAYS * DAY_MS) out.push(p.index);
  }
  return out;
}

/** Removes the pages at `indices` and returns { text, removed: [rawContent…] } (the page order of the rest is kept). */
export function removePages(text, indices) {
  const pages = inspectDraftpadPages(text);
  const drop = new Set(indices.filter(i => i >= 0 && i < pages.length));
  if (!drop.size || drop.size >= pages.length) return { text, removed: [] };
  const kept = pages.filter(p => !drop.has(p.index));
  const removed = pages.filter(p => drop.has(p.index)).map(p => p.rawContent);
  // Rebuild from the kept pages' own bytes, joined the way Draftpad joins pages.
  const out = kept.map(p => text.slice(p.from, p.to)).join('\n\n<!-- page -->\n\n');
  return { text: out, removed };
}

/**
 * Saves or unsaves page `index`. Saving adds  <!-- saved id -->  under the date heading (or as the page's first line
 * when it has none); unsaving removes it. Returns { text, id, changes } where `changes` is a CodeMirror change spec.
 */
export function setPageSaved(text, index, saved, { id = null, rand } = {}) {
  const pages = inspectDraftpadPages(text);
  const p = pages[index];
  if (!p) return { text, id: null, changes: null };
  const have = pageSavedId(p);
  if (saved && have) return { text, id: have, changes: null };
  if (!saved && !have) return { text, id: null, changes: null };
  if (saved) {
    const nid = id || newPageId(rand);
    const line = `<!-- saved ${nid} -->`;
    let at, insert;
    if (p.dateLine) {
      const lineStart = text.indexOf(p.dateLine, p.from);
      at = lineStart + p.dateLine.length;
      const eol = text.indexOf('\n', at);
      at = eol === -1 ? text.length : eol;          // after any trailing spaces on the heading line
      insert = '\n' + line;
    } else {
      at = p.from;
      insert = line + '\n';
    }
    const changes = { from: at, to: at, insert };
    return { text: text.slice(0, at) + insert + text.slice(at), id: nid, changes };
  }
  // unsave: remove the meta line and the newline that joins it
  const re = new RegExp(`(^|\\n)<!-- saved ${have} -->(?=\\n|$)`);
  const seg = text.slice(p.from, p.to);
  const m = re.exec(seg);
  if (!m) return { text, id: null, changes: null };
  let from = p.from + m.index;
  let to = from + m[0].length;
  if (!m[1] && text[to] === '\n') to += 1;               // first line of the page: take its newline instead
  const changes = { from, to, insert: '' };
  return { text: text.slice(0, from) + text.slice(to), id: null, changes };
}

/** Every saved page: { id, index, title, dateMs, words }. */
export function savedPages(text) {
  return inspectDraftpadPages(text)
    .map(p => ({ p, id: pageSavedId(p) }))
    .filter(x => x.id)
    .map(({ p, id }) => ({ id, index: p.index, title: pageTitle(p), dateMs: p.dateMs, words: wordCount(pageBody(p)) }));
}

/** A page's title: its first line of text under the heading, else its date, else "Page n". */
export function pageTitle(p) {
  const body = pageBody(p).split('\n').map(l => l.replace(/^#+\s*/, '').trim()).find(Boolean);
  return (body ? body.slice(0, 80) : '') || p.dateLine || `Page ${p.index + 1}`;
}

export function findPageById(text, id) {
  if (!id) return null;
  return inspectDraftpadPages(text).find(p => pageSavedId(p) === id) || null;
}

// ── Playlists ──────────────────────────────────────────────────────────────────────────────────────────────────────

export function emptyPlaylists() {
  return { version: 1, playlists: [] };
}

export function parsePlaylists(json) {
  try {
    const d = typeof json === 'string' ? JSON.parse(json) : json;
    if (d && Array.isArray(d.playlists)) {
      return { version: 1, ...d, playlists: d.playlists.filter(p => p && p.id).map(p => ({ items: [], ...p })) };
    }
  } catch { /* fall through */ }
  return emptyPlaylists();
}

export function createPlaylist(state, name, { now = new Date(), rand } = {}) {
  const iso = now.toISOString();
  const pl = {
    id: 'pl-' + newPageId(rand), name: String(name || '').trim() || 'New playlist', description: '',
    private: true, owner: 'me', collaborators: [], created: iso, updated: iso, items: []
  };
  return { state: { ...state, playlists: [...state.playlists, pl] }, playlist: pl };
}

function mapPlaylist(state, id, f) {
  return { ...state, playlists: state.playlists.map(p => (p.id === id ? f(p) : p)) };
}

/** Appends an item at the end (as Spotify does); an item already there is left where it is. */
export function addToPlaylist(state, id, item, { now = new Date() } = {}) {
  return mapPlaylist(state, id, p => {
    if (p.items.some(i => i.kind === item.kind && i.ref === item.ref)) return p;
    const iso = now.toISOString();
    return { ...p, updated: iso, items: [...p.items, { kind: item.kind, ref: item.ref, added: iso, addedBy: 'me', note: '' }] };
  });
}

export function removeFromPlaylist(state, id, ref, { now = new Date() } = {}) {
  return mapPlaylist(state, id, p => ({ ...p, updated: now.toISOString(), items: p.items.filter(i => i.ref !== ref) }));
}

export function editPlaylist(state, id, { name, description }, { now = new Date() } = {}) {
  return mapPlaylist(state, id, p => ({
    ...p, updated: now.toISOString(),
    name: name !== undefined ? (String(name).trim() || p.name) : p.name,
    description: description !== undefined ? String(description) : p.description
  }));
}

export function deletePlaylist(state, id) {
  return { ...state, playlists: state.playlists.filter(p => p.id !== id) };
}

/** Page ids any playlist holds (they never expire). */
export function playlistPageIds(state) {
  const s = new Set();
  for (const p of state.playlists) for (const i of p.items) if (i.kind === 'page') s.add(i.ref);
  return s;
}

export function playlistsWith(state, ref) {
  return state.playlists.filter(p => p.items.some(i => i.ref === ref)).map(p => p.id);
}

/** "3 pages · 12 min" — read-aloud time at LISTEN_WPM; pages that are gone count as 0. */
export function playlistSummary(pl, text) {
  const pages = inspectDraftpadPages(text);
  let words = 0, n = 0;
  for (const it of pl.items) {
    n++;
    if (it.kind !== 'page') continue;
    const p = pages.find(pp => pageSavedId(pp) === it.ref);
    if (p) words += wordCount(pageBody(p));
  }
  const min = Math.max(n ? 1 : 0, Math.round(words / LISTEN_WPM));
  const dur = min >= 60 ? `${Math.floor(min / 60)}h ${min % 60}m` : `${min} min`;
  return `${n} ${n === 1 ? 'page' : 'pages'} · ${dur}`;
}
