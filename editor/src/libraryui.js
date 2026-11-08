// The page library on screen: the bookmark in the toolbar (save a page, "Saved in" sheet), the side panel's Saved and
// Playlists tabs, the toast, and the daily sweep of expired pages. Logic lives in library.js; this is the surface.
//
// Host messages (webkit.messageHandlers.ui):
//   { sidecar: { name: 'playlists', json } }       write draftpad.playlists.json beside the note
//   { sidecar: { name: 'pages', json } }           write draftpad.pages.json (each page's last edit day)
//   { archivePages: { token, pages: [text…] } }    append expired pages to "Draftpad expired/<YYYY-MM>.md"
// Host calls: setSidecar('playlists' | 'pages', json), pagesArchived(token, ok).

import { EditorView } from '@codemirror/view';
import { inspectDraftpadPages } from './pages.js';
import { currentPage, showPage } from './pagemode.js';
import {
  daysLeft, expiredPageIndices, setPageSaved, pageKey, todayKey, mergeEdited, savedPages, pageSavedId, pageTitle, findPageById, pageBody,
  parsePlaylists, emptyPlaylists, createPlaylist, addToPlaylist, removeFromPlaylist, editPlaylist, deletePlaylist,
  playlistSummary, playlistsWith
} from './library.js';

const BOOKMARK = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 3h12v18l-6-4-6 4z"/></svg>';
const LIST_ICON = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 6h11M4 11h11M4 16h7M17 13v8M13 17h8"/></svg>';

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}
function button(cls, text, label) {
  const b = el('button', cls, text);
  b.type = 'button';
  if (label) { b.setAttribute('aria-label', label); b.title = label; }
  return b;
}

export function createLibraryUI({ getView, toolbar, before, panel, header, title, outlineOnly = [], list, showPanel, hidePanel, ink, speaker,
  globalObj = typeof window !== 'undefined' ? window : null, now = () => Date.now() }) {
  const host = () => globalObj?.webkit?.messageHandlers?.ui;
  let playlists = emptyPlaylists();
  let edited = {};                 // page key → last edit day (YYYY-MM-DD), draftpad.pages.json
  let tab = 'outline';
  let openPlaylistId = null;
  const tabs = new Map();          // id → { btn, render }

  // ── Toolbar: bookmark + days left ────────────────────────────────────────────────────────────────────────────────
  const mark = button('rc-btn rc-bookmark-btn', '', 'Save page');
  mark.innerHTML = BOOKMARK;
  mark.setAttribute('aria-pressed', 'false');
  const left = el('span', 'rc-expiry');
  toolbar.insertBefore(left, before);
  toolbar.insertBefore(mark, before);

  function pageNow() {
    const v = getView();
    if (!v) return null;
    return inspectDraftpadPages(v.state.doc.toString())[currentPage(v.state)] || null;
  }

  function refreshMark() {
    const p = pageNow();
    const id = pageSavedId(p);
    mark.setAttribute('aria-pressed', String(Boolean(id)));
    const label = id ? 'Saved: change where it’s saved' : 'Save page';
    mark.setAttribute('aria-label', label);
    mark.title = label;
    const v0 = getView();
    const d = daysLeft(p, now(), p && v0 ? edited[pageKey(inspectDraftpadPages(v0.state.doc.toString()), p.index)] : null);
    left.textContent = d === null ? '' : d === 0 ? 'Expires today' : `${d} ${d === 1 ? 'day' : 'days'} left`;
    left.hidden = d === null;
  }

  function dispatchSave(index, saved, id) {
    const v = getView();
    const r = setPageSaved(v.state.doc.toString(), index, saved, { id });
    if (r.changes) v.dispatch({ changes: r.changes, userEvent: saved ? 'input.save' : 'delete.save' });
    return r.id;
  }

  mark.addEventListener('click', () => {
    const v = getView();
    if (!v) return;
    const i = currentPage(v.state);
    const p = pageNow();
    if (!pageSavedId(p)) {
      dispatchSave(i, true);
      toast('Saved to Saved pages', { action: 'Change', onAction: () => openSheet() });
      refresh();
    } else {
      openSheet();
    }
  });

  // ── Toast (fades in above the page, about 3.5 s, as in the playlist research) ────────────────────────────────────
  const toastEl = el('div', 'rc-toast');
  toastEl.setAttribute('role', 'status');
  toastEl.hidden = true;
  const layer = panel.parentNode || panel;
  layer.appendChild(toastEl);
  let toastTimer = null;
  function toast(text, { action, onAction } = {}) {
    toastEl.innerHTML = '';
    toastEl.append(el('span', 'rc-toast-text', text));
    if (action) {
      const b = button('rc-toast-action', action);
      b.addEventListener('click', () => { hideToast(); onAction?.(); });
      toastEl.append(b);
    }
    toastEl.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(hideToast, 3500);
  }
  function hideToast() { toastEl.hidden = true; }

  // ── "Saved in" sheet ──────────────────────────────────────────────────────────────────────────────────────────────
  const scrim = el('div', 'rc-sheet-scrim');
  scrim.hidden = true;
  const sheet = el('div', 'rc-sheet');
  sheet.setAttribute('role', 'dialog');
  sheet.setAttribute('aria-label', 'Saved in');
  scrim.append(sheet);
  layer.appendChild(scrim);
  scrim.addEventListener('pointerdown', e => { if (e.target === scrim) closeSheet(); });

  let pending = null;   // { saved: bool, in: Set<playlistId> }
  function openSheet() {
    const p = pageNow();
    const id = pageSavedId(p);
    pending = { saved: Boolean(id), in: new Set(id ? playlistsWith(playlists, id) : []) };
    renderSheet();
    scrim.hidden = false;
  }
  function closeSheet() { scrim.hidden = true; pending = null; }

  function renderSheet() {
    sheet.innerHTML = '';
    sheet.append(el('div', 'rc-sheet-grabber'));
    const head = el('div', 'rc-sheet-head');
    const cancel = button('rc-sheet-cancel', 'Cancel');
    const done = button('rc-sheet-done', 'Done');
    head.append(cancel, el('span', 'rc-sheet-title', 'Saved in'), done);
    cancel.addEventListener('click', closeSheet);
    done.addEventListener('click', applySheet);
    sheet.append(head);

    const rows = el('div', 'rc-sheet-rows');
    rows.append(sheetRow('Saved pages', 'Kept: never expires', pending.saved, () => {
      pending.saved = !pending.saved;
      if (!pending.saved) pending.in.clear();         // a page in a playlist is always saved
      renderSheet();
    }, BOOKMARK));
    const add = button('rc-sheet-new', 'New playlist');
    add.addEventListener('click', () => {
      const f = newPlaylistField(pl => { pending.in.add(pl.id); pending.saved = true; renderSheet(); });
      f.__button = add;
      add.replaceWith(f);
    });
    rows.append(add);
    for (const pl of playlists.playlists) {
      rows.append(sheetRow(pl.name, playlistSummary(pl, getView().state.doc.toString()), pending.in.has(pl.id), () => {
        if (pending.in.has(pl.id)) pending.in.delete(pl.id);
        else { pending.in.add(pl.id); pending.saved = true; }
        renderSheet();
      }, LIST_ICON));
    }
    sheet.append(rows);
  }

  /** "New playlist": a name field in place of the button (Return or Create makes it; Esc or empty cancels). */
  function newPlaylistField(onCreate) {
    const f = el('form', 'rc-library-newform');
    const input = el('input', 'rc-library-input');
    input.placeholder = 'Playlist name';
    input.setAttribute('aria-label', 'Playlist name');
    const ok = button('rc-library-listen', 'Create');
    ok.type = 'submit';
    f.append(input, ok);
    f.addEventListener('submit', e => {
      e.preventDefault();
      const r = createPlaylist(playlists, input.value);
      playlists = r.state;
      persist();
      onCreate(r.playlist);
    });
    input.addEventListener('keydown', e => { if (e.key === 'Escape') { e.stopPropagation(); f.replaceWith(f.__button); } });
    setTimeout(() => input.focus(), 0);
    return f;
  }

  function sheetRow(name, sub, on, toggle, icon) {
    const r = el('div', 'rc-sheet-row');
    const ic = el('span', 'rc-sheet-icon');
    ic.innerHTML = icon;
    const txt = el('div', 'rc-sheet-text');
    txt.append(el('div', 'rc-sheet-name', name), el('div', 'rc-sheet-sub', sub));
    const t = button(`rc-sheet-toggle${on ? ' on' : ''}`, on ? '✓' : '+', on ? `Remove from ${name}` : `Add to ${name}`);
    t.setAttribute('aria-pressed', String(on));
    t.addEventListener('click', toggle);
    r.append(ic, txt, t);
    return r;
  }

  function applySheet() {
    const v = getView();
    const i = currentPage(v.state);
    let id = pageSavedId(pageNow());
    if (pending.saved && !id) id = dispatchSave(i, true);
    if (!pending.saved && id) { dispatchSave(i, false); }
    const want = pending.saved ? pending.in : new Set();
    for (const pl of playlists.playlists) {
      const has = id && pl.items.some(it => it.ref === id);
      if (want.has(pl.id) && !has) playlists = addToPlaylist(playlists, pl.id, { kind: 'page', ref: id });
      if (!want.has(pl.id) && has) playlists = removeFromPlaylist(playlists, pl.id, id);
    }
    persist();
    const msg = !pending.saved ? 'Removed from Saved pages'
      : want.size ? `Saved in ${want.size} ${want.size === 1 ? 'playlist' : 'playlists'}` : 'Saved to Saved pages';
    closeSheet();
    toast(msg);
    refresh();
  }

  // ── Side panel tabs ───────────────────────────────────────────────────────────────────────────────────────────────
  const tabBar = el('div', 'rc-panel-tabs');
  tabBar.setAttribute('role', 'tablist');
  if (title) { header.insertBefore(tabBar, title); header.removeChild(title); }   // the "Outline" title becomes a tab
  else header.appendChild(tabBar);
  const libList = el('div', 'rc-library-list');
  libList.hidden = true;
  panel.append(libList);

  function addTab(id, label, render) {
    const b = button('rc-panel-tab', label);
    b.setAttribute('role', 'tab');
    b.setAttribute('aria-selected', String(id === tab));
    b.addEventListener('click', () => openTab(id));
    tabBar.append(b);
    tabs.set(id, { btn: b, render });
  }
  addTab('outline', 'Outline', null);
  addTab('saved', 'Saved', renderSaved);
  addTab('playlists', 'Playlists', renderPlaylists);

  function openTab(id) {
    if (!tabs.has(id)) return;
    tab = id;
    for (const [k, t] of tabs) t.btn.setAttribute('aria-selected', String(k === id));
    const outlineOn = id === 'outline';
    list.hidden = !outlineOn;
    libList.hidden = outlineOn;
    for (const b of outlineOnly) b.hidden = !outlineOn;   // "Newest first" belongs to the outline
    if (!outlineOn) { if (id !== 'playlists') openPlaylistId = null; renderTab(); }
    showPanel();
  }
  function renderTab() {
    if (tab === 'outline') return;
    libList.innerHTML = '';
    tabs.get(tab)?.render?.(libList);
  }

  function jumpTo(index) {
    const v = getView();
    if (!v || index < 0) return;
    showPage(v, index);
    v.dispatch({ effects: EditorView.scrollIntoView(inspectDraftpadPages(v.state.doc.toString())[index]?.from ?? 0, { y: 'start' }) });
    hidePanel();
    refresh();
  }

  function pageRow(title, sub, onOpen, extra) {
    const r = el('div', 'rc-library-row');
    const b = button('rc-library-open', '');
    b.append(el('span', 'rc-library-title', title), el('span', 'rc-library-sub', sub));
    b.addEventListener('click', onOpen);
    r.append(b);
    if (extra) r.append(extra);
    return r;
  }

  function dateText(ms) {
    if (typeof ms !== 'number') return 'Undated';
    return new Date(ms).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC' });
  }

  function renderSaved(c) {
    const text = getView().state.doc.toString();
    const items = savedPages(text);
    if (!items.length) {
      c.append(el('div', 'rc-outline-empty', 'No saved pages. Tap the bookmark on a page to keep it; other pages go after 14 days.'));
      return;
    }
    for (const s of items) c.append(pageRow(s.title, `${dateText(s.dateMs)} · ${s.words} words`, () => jumpTo(s.index)));
  }

  function renderPlaylists(c) {
    const text = getView().state.doc.toString();
    const pl = openPlaylistId && playlists.playlists.find(p => p.id === openPlaylistId);
    if (pl) return renderPlaylist(c, pl, text);
    const add = button('rc-library-new', '+ New playlist');
    add.addEventListener('click', () => {
      const f = newPlaylistField(pl => { openPlaylistId = pl.id; renderTab(); });
      f.__button = add;
      add.replaceWith(f);
    });
    c.append(add);
    if (!playlists.playlists.length) {
      c.append(el('div', 'rc-outline-empty', 'Group pages into a playlist: bookmark a page, then tap it again.'));
      return;
    }
    for (const p of playlists.playlists) {
      c.append(pageRow(p.name, playlistSummary(p, text), () => { openPlaylistId = p.id; renderTab(); }));
    }
  }

  let editing = false;
  let deleteArmed = false;
  function renderPlaylist(c, pl, text) {
    const back = button('rc-library-back', '‹ Playlists');
    back.addEventListener('click', () => { openPlaylistId = null; editing = false; renderTab(); });
    c.append(back);
    if (editing) return renderDetails(c, pl);
    c.append(el('h3', 'rc-library-h', pl.name));
    if (pl.description) c.append(el('p', 'rc-library-desc', pl.description));
    c.append(el('div', 'rc-library-sub', `${pl.private ? '🔒 Private' : 'Public'} · ${playlistSummary(pl, text)}`));
    const actions = el('div', 'rc-library-actions');
    const listen = button('rc-library-listen', speaker?.isSpeaking() ? '■ Stop' : '▶ Listen', 'Read the playlist aloud');
    listen.addEventListener('click', () => {
      if (speaker.isSpeaking()) { speaker.stop(); renderTab(); return; }
      const parts = pl.items.map(it => findPageById(getView().state.doc.toString(), it.ref)).filter(Boolean).map(pageBody).filter(Boolean);
      if (!parts.length) return;
      speaker.speak(parts, { onDone: () => renderTab() });
      renderTab();
    });
    const details = button('rc-library-details', 'Name & details');
    details.addEventListener('click', () => { editing = true; deleteArmed = false; renderTab(); });
    actions.append(listen, details);
    c.append(actions);
    if (!pl.items.length) c.append(el('div', 'rc-outline-empty', 'Empty. Bookmark a page, tap the bookmark again, and tick this playlist.'));
    for (const it of pl.items) {
      const p = it.kind === 'page' ? findPageById(text, it.ref) : null;
      const title = p ? pageTitle(p) : it.kind === 'page' ? 'Page no longer here' : it.ref;
      const rm = button('rc-library-remove', '×', `Remove ${title} from this playlist`);
      rm.addEventListener('click', () => {
        playlists = removeFromPlaylist(playlists, pl.id, it.ref);
        persist();
        toast(`Removed ${title}.`);
        renderTab();
      });
      c.append(pageRow(title, p ? dateText(p.dateMs) : it.kind, () => p && jumpTo(p.index), rm));
    }
  }

  function renderDetails(c, pl) {
    const form = el('form', 'rc-library-form');
    const name = el('input', 'rc-library-input');
    name.value = pl.name;
    name.setAttribute('aria-label', 'Name');
    const desc = el('textarea', 'rc-library-input');
    desc.value = pl.description || '';
    desc.rows = 3;
    desc.setAttribute('aria-label', 'Description');
    desc.placeholder = 'Description';
    const row = el('div', 'rc-library-actions');
    const cancel = button('rc-library-details', 'Cancel');
    const save = button('rc-library-listen', 'Save');
    save.type = 'submit';
    save.disabled = true;
    const dirty = () => { save.disabled = name.value === pl.name && desc.value === (pl.description || ''); };
    name.addEventListener('input', dirty);
    desc.addEventListener('input', dirty);
    cancel.addEventListener('click', () => { editing = false; renderTab(); });
    form.addEventListener('submit', e => {
      e.preventDefault();
      playlists = editPlaylist(playlists, pl.id, { name: name.value, description: desc.value });
      persist();
      editing = false;
      renderTab();
    });
    const del = button('rc-library-delete', deleteArmed ? 'Tap again to delete' : 'Delete playlist');
    del.addEventListener('click', () => {
      if (!deleteArmed) { deleteArmed = true; del.textContent = 'Tap again to delete'; return; }
      playlists = deletePlaylist(playlists, pl.id);
      persist();
      toast(`Deleted ${pl.name}. Its pages stay saved.`);
      editing = false; openPlaylistId = null; renderTab();
    });
    row.append(cancel, save);
    form.append(name, desc, row, del);
    c.append(form);
  }

  // ── Last edit per page (the 14 days count from it when it's later than the heading's date) ───────────────────────
  let editTimer = null;
  function noteEdit() {
    const v = getView();
    if (!v) return;
    const pages = inspectDraftpadPages(v.state.doc.toString());
    const key = pageKey(pages, currentPage(v.state));
    const day = todayKey(now());
    if (!key || edited[key] === day) return;
    edited = { ...edited, [key]: day };
    clearTimeout(editTimer);
    editTimer = setTimeout(() => persistSidecar('pages', JSON.stringify({ version: 1, edited })), 1500);
  }
  function setPagesJSON(json) {
    try { edited = mergeEdited(edited, JSON.parse(json)?.edited || {}); } catch { /* keep ours */ }
    refreshMark();
  }

  // ── Persistence ───────────────────────────────────────────────────────────────────────────────────────────────────
  function persistSidecar(name, json) {
    const h = host();
    if (h && typeof h.postMessage === 'function') h.postMessage({ sidecar: { name, json } });
    else try { globalObj?.localStorage?.setItem(`rc-${name}`, json); } catch { /* private window */ }
  }
  function persist() { persistSidecar('playlists', JSON.stringify(playlists)); }
  function setPlaylistsJSON(json) {
    playlists = parsePlaylists(json);
    renderTab();
  }
  if (!host()) {
    try { const j = globalObj?.localStorage?.getItem('rc-playlists'); if (j) playlists = parsePlaylists(j); } catch { /* none */ }
  }

  // ── Expiry: pages past 14 days go to the archive file, then leave the note ────────────────────────────────────────
  const waiting = new Map();   // token → [rawContent]
  let tokenSeq = 0;
  function runExpiry() {
    const v = getView();
    const h = host();
    if (!v || !h || typeof h.postMessage !== 'function') return 0;   // no host, no archive: never remove
    const text = v.state.doc.toString();
    const idx = expiredPageIndices(text, { now: now(), keepIndex: currentPage(v.state), edited });
    if (!idx.length) return 0;
    const pages = inspectDraftpadPages(text);
    const raw = idx.map(i => pages[i].rawContent);
    const token = `x${++tokenSeq}`;
    waiting.set(token, raw);
    h.postMessage({ archivePages: { token, pages: raw } });
    return idx.length;
  }
  /** The host wrote the pages to the archive (ok) or couldn't (they stay). */
  function pagesArchived(token, ok) {
    const raw = waiting.get(token);
    waiting.delete(token);
    if (!ok || !raw) return 0;
    const v = getView();
    const text = v.state.doc.toString();
    const pages = inspectDraftpadPages(text);
    const still = new Set(expiredPageIndices(text, { now: now(), keepIndex: currentPage(v.state), edited }));
    const want = new Set(raw);
    const drop = pages.filter(p => still.has(p.index) && want.has(p.rawContent)).map(p => p.index);
    if (!drop.length) return 0;
    const changes = drop.map(i => ({ from: pages[i - 1].to, to: pages[i].to, insert: '' }));
    ink?.removePageInk?.(drop, text);
    const cur = currentPage(v.state);
    const shift = drop.filter(i => i < cur).length;
    v.dispatch({ changes, userEvent: 'delete.expired' });
    if (shift) showPage(v, cur - shift);
    refresh();
    return drop.length;
  }

  function refresh() {
    refreshMark();
    if (!libList.hidden) renderTab();
  }

  function setSidecar(name, json) {
    if (name === 'playlists') setPlaylistsJSON(json);
    else if (name === 'pages') setPagesJSON(json);
  }

  return { refresh, openTab, addTab, toast, setPlaylistsJSON, setSidecar, noteEdit, getPlaylists: () => playlists, runExpiry, pagesArchived,
    openSheet, closeSheet, bookmark: mark };
}
