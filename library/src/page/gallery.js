import css from "../client/gallery.css";
import homebarCss from "../client/homebar.css";
import homebar from "../client/homebar.js";
import js from "../client/gallery.js";
import keylabel from "../client/keylabel.js";
import prosody from "../client/prosody.js";
import prosogram from "../client/prosogram.js";
import prosogramMain from "../client/prosogram-main.js";
import prosogramMount from "../client/prosogram-mount.js";
import room from "../client/room.js";
import { OWNER, VERSION, esc, page } from "../common.js";

// The gallery page for any list of items: a public link, or a folder of Main.
// live.title, live.heading and live.zip reframe it; nav goes above the grid.
export function galleryPage(live, nav = "", crumbs = "") {
  const data = JSON.stringify({ ...live, version: VERSION }).replace(/</g, "\\u003c");

  const svg = (d, w = 2) =>
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="' +
    w +
    '" stroke-linecap="round" stroke-linejoin="round">' +
    d +
    "</svg>";

  const INFO = svg(
    '<circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/>',
    1.8
  );
  const SHARE = svg('<path d="M12 3v13M7 8l5-5 5 5"/><path d="M5 12v7a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-7"/>', 1.8);
  const TRASH = svg('<path d="M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14M10 10v6M14 10v6"/>', 1.8);
  return page(`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta name="darkreader-lock">
<meta name="theme-color" content="#1c1c1e">
<meta name="color-scheme" content="dark">
<meta name="robots" content="noindex">
<title>${esc(live.title || "Shared by " + OWNER)}</title>
<style>${homebarCss}
${css}</style>
</head>

<body>

<main>

  ${crumbs}

<div class="bar">
  <button id="selall" class="lnk" hidden>Select All</button>
  <div class="barr"> <!-- Changed from span to div -->
    <button class="mbtn" id="mbtn" type="button" aria-label="More" aria-haspopup="menu" aria-expanded="false">
      <svg viewBox="0 0 24 24" fill="currentColor"><circle cx="5" cy="12" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="19" cy="12" r="2"/></svg>
    </button>
    
    <button id="sel" class="lnk">Select</button>

    <div class="mnu" id="mnu" role="menu" hidden>
      <div class="mhd"><b>Shared Gallery</b><span id="mcount">1 Participant</span></div>
      <div class="msep"></div>

      <a class="mi" role="menuitem" href="/main/share" id="m-share">
        <svg viewBox="0 0 24 24"><path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/></svg>
        Create Share Link
      </a>
      <button class="mi" role="menuitem" id="m-air" type="button">
        <svg viewBox="0 0 24 24"><circle cx="12" cy="13" r="2"/><path d="M7.8 17.2a6 6 0 1 1 8.4 0"/><path d="M4.9 20.1a10 10 0 1 1 14.2 0"/></svg>
        AirDrop
      </button>
      <button class="mi" role="menuitem" id="m-inv" type="button">
        <svg viewBox="0 0 24 24"><circle cx="10" cy="8" r="3.5"/><path d="M3.5 20a6.5 6.5 0 0 1 13 0M19 8v6M16 11h6"/></svg>
        Invite <span class="n" id="ncount">1</span>
      </button>

      <div class="msep"></div>
      <button class="mi" role="menuitem" id="m-add" type="button">
        <svg viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg>
        Add Media
      </button>
      <button class="mi" role="menuitem" id="m-dir" type="button" hidden>
        <svg viewBox="0 0 24 24"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2zM12 10v6M9 13h6"/></svg>
        New Folder
      </button>

      <div class="msep"></div>
      <button class="mi danger" role="menuitem" id="m-del" type="button">
        <svg viewBox="0 0 24 24"><path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13M10 11v6M14 11v6"/></svg>
        Delete Shared Gallery
      </button>
    </div>
  </div> <!-- Changed from span to div -->
</div>
<div class="hero" id="hero" hidden>
  <span id="hdate"></span>
</div>

  <div class="info">
    <div>
      <b id="owner"></b>
      <div id="count" class="mut"></div>
      <div id="exp" class="mut"></div>
    </div>

    <div class="acts">
      <button id="up" class="pill" hidden>Upload</button>
      <button id="dl" class="pill">Download</button>
    </div>
    <input id="upin" type="file" multiple hidden>
  </div>

  <p id="note" class="note" role="status" hidden></p>

  ${nav}

  <div class="grid" id="grid">
    <button class="tile add" id="addtile" type="button" aria-label="Upload media"></button>
  </div>

  <div class="foot" id="foot">
    <span id="ftxt"></span>
    <button id="mv" class="lnk" type="button" hidden>Move</button>
    <button id="del" aria-label="Delete" hidden>${TRASH}</button>
  </div>
</main>

<div id="lb" hidden role="dialog" aria-modal="true" aria-label="Viewer">

  <div class="top">


    <div class="ttl">
      <b id="t1"></b>
      <span id="t2"></span>
    </div>

    <div class="topr" id="topr"></div>

  </div>

  <div class="stage-container">

    <div id="stage"></div>


  </div>

  <div id="meta" hidden></div>

  <div class="bot">

    <button id="info" class="ic" aria-label="Info">${INFO}</button>

    <div id="strip"></div>

    <button id="vshare" class="ic" aria-label="Share" hidden>${SHARE}</button>

    <div id="cm" hidden></div>

  </div>

</div>

<script>
const G=${data};
</script>

<div class="inv" id="inv" hidden role="dialog" aria-modal="true" aria-labelledby="invt">
  <div class="invc">
    <div class="invh"><b id="invt">Invite</b><button class="lnk" id="invdone" type="button">Done</button></div>
    <p class="invn" id="invscope"></p>
    <form class="invf" id="invform">
      <input id="invname" placeholder="Name or label" autocomplete="off" required>
      <select id="invttl" aria-label="Link expires">
        <option value="3600">1 hour</option>
        <option value="86400" selected>1 day</option>
        <option value="604800">7 days</option>
        <option value="2592000">30 days</option>
        <option value="7776000">90 days</option>
        <option value="31536000">1 year</option>
        <option value="0">Never</option>
      </select>
      <button class="pill">Create link</button>
    </form>
    <p class="inve" id="inve">No invites yet</p>
    <ul class="invl" id="invl"></ul>
    <p class="invn" id="invn"></p>
  </div>
</div>
<div class="inv" id="shr" hidden role="dialog" aria-modal="true" aria-labelledby="shrt">
  <div class="invc">
    <div class="invh"><b id="shrt">Create Share Link</b><button class="lnk" id="shrx" type="button">Cancel</button></div>
    <p class="invn" id="shrn"></p>
    <div class="seg" role="radiogroup" aria-label="Link lasts">
      <label><input type="radio" name="shrd" value="1"><span>1 day</span></label>
      <label><input type="radio" name="shrd" value="7" checked><span>7 days</span></label>
      <label><input type="radio" name="shrd" value="30"><span>30 days</span></label>
    </div>
    <div class="invf"><button class="pill" id="shrgo" type="button" style="grid-column:1 / -1">Create Link</button></div>
  </div>
</div>
<div class="inv" id="mvs" hidden role="dialog" aria-modal="true" aria-labelledby="mvt">
  <div class="invc">
    <div class="invh"><b id="mvt">Move</b><button class="lnk" id="mvx" type="button">Cancel</button></div>
    <p class="invn mvcr" id="mvcr"></p>
    <ul class="invl" id="mvl"></ul>
    <p class="inve" id="mve" hidden>No folders here</p>
    <div class="invf"><button class="pill" id="mvgo" type="button" style="grid-column:1 / -1">Move Here</button></div>
  </div>
</div>
<div class="mtoast" id="mtoast" role="status"></div>

<script>
${keylabel}
</script>
<script>
${room}
</script>
<script>
${homebar}
</script>
<script>
${js}
</script>
<!-- The live prosogram. prosody.js, prosogram.js and prosogram-mount.js know no app-specific routes and load on every
     page, so share links get it too. Only prosogram-main.js names an owner route, so it alone is gated: a participant's
     page must not contain that string (routes.test.mjs "invites" asserts it). Loaded after the player so the stage
     exists; prosogram-mount.js is the one file to change when gallery.js grows a real hook. -->
<script>
${prosody}
</script>
<script>
${prosogram}
</script>
<script>
${prosogramMount}
</script>
${live.main ? `<script>
${prosogramMain}
</script>` : ""}

<script>
// The "…" menu and the Invite sheet. Only the owner sees the menu; the server refuses
// everything here for anyone else anyway.
(() => {
const qs = s => document.querySelector(s);
const mbtn = qs('#mbtn'), mnu = qs('#mnu'), inv = qs('#inv');
const H = { 'x-gallery': '1' };
let invites = [];

window.galleryToast = t => toast(t);
function toast(t){
  const el = qs('#mtoast'); el.textContent = t; el.classList.add('on');
  clearTimeout(toast.t); toast.t = setTimeout(() => el.classList.remove('on'), 2400);
}

// Add Media: the owner on Main, or an invited person allowed to upload
const canAdd = G.main || (G.invite && G.invite.perms && G.invite.perms.upload);
qs('#addtile').hidden = !canAdd;
qs('#addtile').addEventListener('click', () => qs('#up').click());

const setMenu = o => { mnu.hidden = !o; mbtn.setAttribute('aria-expanded', o); };
mbtn.hidden = true;

const ownerMenu = () => {
  mbtn.hidden = false;
  qs('#m-inv').hidden = !G.main;        // invites are to a Main folder
  qs('#m-del').hidden = !!G.main;       // Main folders are deleted on the Mac, not here
  qs('#m-add').hidden = !G.main;
  qs('#m-dir').hidden = !G.main;
  if (G.main) loadInvites();
};

if (G.main) ownerMenu();
else if (!G.invite)
  fetch('/main/api/whoami', { redirect: 'manual', cache: 'no-store' }).then(r => r.ok && ownerMenu()).catch(() => {});

mbtn.addEventListener('click', e => { e.stopPropagation(); setMenu(mnu.hidden); });
document.addEventListener('click', e => { if (!mnu.hidden && !mnu.contains(e.target)) setMenu(false); });
document.addEventListener('keydown', e => { if (e.key === 'Escape') { setMenu(false); inv.hidden = true; qs('#mvs').hidden = true; } });

qs('#m-add').addEventListener('click', () => { setMenu(false); qs('#up').click(); });

/* New Folder (Main): made in R2 inside this folder; it shows as a chip after the reload */
qs('#m-dir').addEventListener('click', async () => {
  setMenu(false);
  const name = (prompt('New Folder', '') || '').trim();
  if (!name) return;
  try {
    const r = await fetch('/main/api/folder', {
      method: 'POST', headers: { ...H, 'Content-Type': 'application/json' },
      body: JSON.stringify({ dir: G.dir || '', name })
    });
    if (!r.ok) throw new Error(await r.text());
    location.reload();
  } catch (err) {
    toast('Couldn’t make the folder' + (err && err.message ? ': ' + err.message : ''));
  }
});

/* Move (Main, Select mode): pick a folder, then Move Here. The server only moves into a folder
   that exists and never replaces a file already there. */
const mvs = qs('#mvs');
let mvAt = '', mvList = [];
const mvGo = p => p ? p.split('/') : [];
async function mvOpen(p){
  const r = await fetch('/main/api/folders?' + new URLSearchParams({ p }), { headers: H, cache: 'no-store' });
  if (!r.ok) { toast('Couldn’t list folders'); return; }
  const j = await r.json();
  mvAt = j.path;
  const cr = qs('#mvcr'); cr.textContent = '';
  const parts = mvGo(mvAt);
  [['Main Gallery', '']].concat(parts.map((x, i) => [x, parts.slice(0, i + 1).join('/')])).forEach(([t, at], i) => {
    if (i) cr.append(' / ');
    cr.append(i === parts.length ? document.createTextNode(t) : mk(t, 'invb', () => mvOpen(at)));
  });
  const ul = qs('#mvl'); ul.textContent = '';
  j.folders.forEach(n => {
    const li = document.createElement('li'); li.className = 'invr';
    const b = mk(n, 'invb mvf', () => mvOpen((mvAt ? mvAt + '/' : '') + n));
    li.append(b); ul.append(li);
  });
  qs('#mve').hidden = j.folders.length > 0;
  const same = mvList.every(f => String(f.path).split('/').slice(0, -1).join('/') === mvAt);
  qs('#mvgo').disabled = same;
  qs('#mvgo').textContent = same ? 'Already Here' : 'Move Here';
}
qs('#mv').addEventListener('click', () => {
  mvList = window.gallerySelection ? window.gallerySelection() : [];
  if (!mvList.length) return;
  qs('#mvt').textContent = 'Move ' + (mvList.length === 1 ? '“' + mvList[0].name + '”' : mvList.length + ' Items');
  mvs.hidden = false;
  mvOpen(G.dir || '');
});
qs('#mvx').addEventListener('click', () => { mvs.hidden = true; });
mvs.addEventListener('click', e => { if (e.target === mvs) mvs.hidden = true; });
qs('#mvgo').addEventListener('click', async () => {
  const btn = qs('#mvgo'); btn.disabled = true;
  try {
    const r = await fetch('/main/api/move', {
      method: 'POST', headers: { ...H, 'Content-Type': 'application/json' },
      body: JSON.stringify({ paths: mvList.map(f => f.path), to: mvAt })
    });
    const j = r.headers.get('content-type') && r.headers.get('content-type').includes('json') ? await r.json() : null;
    if (!j) throw new Error(await r.text());
    if (j.failed.length) {
      toast('Moved ' + j.moved.length + ' of ' + mvList.length + '. ' + j.failed[0].path.split('/').pop() + ': ' + j.failed[0].why);
      if (j.moved.length) setTimeout(() => location.reload(), 2400);
      else btn.disabled = false;
      return;
    }
    location.reload();
  } catch (err) {
    toast('Couldn’t move' + (err && err.message ? ': ' + err.message : ''));
    btn.disabled = false;
  }
});

/* AirDrop: pages can't call it directly, but the native share sheet includes it */
qs('#m-air').addEventListener('click', async () => {
  setMenu(false);
  const data = { title: document.title, url: location.href };
  if (navigator.share) {
    try { await navigator.share(data); }
    catch (e) { if (e && e.name !== 'AbortError') toast('Couldn’t open the share sheet'); }
    return;
  }
  try { await navigator.clipboard.writeText(data.url); toast('Link copied'); }
  catch (_) { toast('Open this page in Safari to use AirDrop'); }
});

// a share link carries the trailing language set here, so the receiver sees the same (en, vi, fr)
/* the language and Key notation in use right now, written into a link as it is made */
function viewNow(){
  try { if (window.galleryView) return window.galleryView(); } catch (_) {}
  return {};
}

/* Create Share Link: with media selected on Main, the server copies just those into a new
   public link, and the link goes to the clipboard at once. With nothing selected it opens the
   upload page as before. */
qs('#m-share').addEventListener('click', e => {
  const picked = G.main && window.gallerySelection ? window.gallerySelection() : [];
  if (!picked.length) return;
  e.preventDefault();
  setMenu(false);
  qs('#shrn').textContent = picked.length + (picked.length === 1 ? ' item selected' : ' items selected');
  qs('#shr').hidden = false;
});
qs('#shrx').addEventListener('click', () => { qs('#shr').hidden = true; });
qs('#shr').addEventListener('click', e => { if (e.target === qs('#shr')) qs('#shr').hidden = true; });

// the tap on Create Link is the gesture Safari needs for the clipboard
qs('#shrgo').addEventListener('click', async () => {
  const picked = window.gallerySelection ? window.gallerySelection() : [];
  if (!picked.length) return;
  const days = (document.querySelector('input[name="shrd"]:checked') || {}).value || '7';
  qs('#shr').hidden = true;

  const made = fetch('/main/api/link?' + new URLSearchParams({ action: 'fromMain', days }), {
    method: 'POST', headers: { ...H, 'content-type': 'application/json' },
    body: JSON.stringify({ paths: picked.map(f => f.path), ...viewNow() })
  }).then(async r => { if (!r.ok) throw new Error(await r.text()); return r.json(); });
  const link = made.then(j => location.origin + j.url);

  // Safari only lets a page write the clipboard during the tap itself: hand it the promise now
  let copied = false;
  try {
    if (window.ClipboardItem && navigator.clipboard && navigator.clipboard.write) {
      const write = navigator.clipboard.write([new ClipboardItem({ 'text/plain': link.then(u => new Blob([u], { type: 'text/plain' })) })]);
      toast('Making the link…');
      await write;
      copied = true;
    }
  } catch (_) {}

  let j;
  try { j = await made; }
  catch (err) { toast('Couldn’t make the link' + (err && err.message ? ': ' + err.message : '')); return; }
  const url = location.origin + j.url;

  if (!copied) { try { await navigator.clipboard.writeText(url); copied = true; } catch (_) {} }
  if (!copied) prompt('Copy this link', url);

  // copy the files in one at a time; the link already works and shows them as they arrive
  for (let i = 0; i < j.count; i++) {
    toast((copied ? 'Link copied. ' : '') + 'Sharing ' + (i + 1) + ' of ' + j.count + '…');
    const r = await fetch('/main/api/link?' + new URLSearchParams({ action: 'copy', id: j.id, i: String(i) }), { method: 'POST', headers: H });
    if (!r.ok) { toast('Stopped at ' + (i + 1) + ' of ' + j.count + '. The link has the rest missing'); return; }
  }
  const d = +days;
  toast((copied ? 'Link copied. ' : '') + j.count + (j.count === 1 ? ' item' : ' items') + ' shared for ' + d + (d === 1 ? ' day' : ' days'));
});

/* delete this public link (Main folders are never deleted from here) */
qs('#m-del').addEventListener('click', async () => {
  setMenu(false);
  if (G.main || !confirm('Delete this shared gallery? This can’t be undone.')) return;
  const r = await fetch('/main/api/link?' + new URLSearchParams({ id: G.id }), { method: 'DELETE', headers: H });
  if (r.ok) location.href = '/main/';
  else toast('Couldn’t delete it');
});

/* invite sheet: the whole folder, or a room of just some items (picked in Select mode, or the one
   in the viewer). The person's link opens only what it was made for; a room of one opens straight
   onto that item. */
let scope = null;   // null = the whole folder, else [{ name, path }]
const nameOf = f => String(f.path || f.name).split('/').pop();
function openInvite(list){
  scope = list && list.length ? list : null;
  const folder = G.dir ? G.dir.split('/').pop() : 'Main';
  qs('#invt').textContent = scope ? 'Share' : 'Invite';
  qs('#invscope').textContent = !scope ? 'To everything in ' + folder
    : scope.length === 1 ? 'To “' + scope[0].name + '” only'
    : 'To these ' + scope.length + ' items only';
  inv.hidden = false;
  renderInvites();
  qs('#invname').focus();
}
window.galleryInvite = openInvite;
qs('#m-inv').addEventListener('click', () => {
  setMenu(false);
  openInvite(window.gallerySelection ? window.gallerySelection() : []);
});
qs('#invdone').addEventListener('click', () => { inv.hidden = true; });
inv.addEventListener('click', e => { if (e.target === inv) inv.hidden = true; });

const isLive = i => !i.expires || i.expires > Date.now();
const mk = (t, cls, fn) => { const b = document.createElement('button'); b.type = 'button'; b.className = cls; b.textContent = t; b.onclick = fn; return b; };

async function copyLink(i){
  const u = i.url;
  try { await navigator.clipboard.writeText(u); toast('Link copied'); }
  catch (_) { prompt('Copy this link', u); }
}

async function revoke(id){
  if (!confirm('Revoke this link? They lose access immediately.')) return;
  const r = await fetch('/main/api/invites/' + id, { method: 'DELETE', headers: H });
  if (r.ok) { invites = invites.filter(i => i.id !== id); renderInvites(); toast('Link revoked'); }
  else toast('Couldn’t revoke it');
}

function renderInvites(){
  const list = qs('#invl'); list.textContent = '';
  const live = invites.filter(isLive);
  // in a room's sheet, the links to that room; in the folder's, every link in the folder
  const key = s => s ? s.slice().sort().join('|') : '';
  const here = scope ? live.filter(i => i.items && key(i.items) === key(scope.map(nameOf))) : live;
  here.forEach(i => {
    const li = document.createElement('li'); li.className = 'invr';
    const w = document.createElement('div'); w.className = 'invw';
    const b = document.createElement('b'); b.textContent = i.name;
    const s = document.createElement('small');
    s.textContent = i.expires
      ? 'Expires ' + new Date(i.expires).toLocaleString([], { month:'short', day:'numeric', hour:'numeric', minute:'2-digit' })
      : 'Never expires';
    if (!scope && i.items) s.textContent += ' · ' + (i.items.length === 1 ? i.items[0] : i.items.length + ' items');
    w.append(b, s);
    li.append(w);
    // the link itself is only known right after it is made (the server keeps a hash, not the link)
    if (i.url) li.append(mk('Copy', 'invb', () => copyLink(i)));
    li.append(mk('Revoke', 'invb rev', () => revoke(i.id)));
    list.append(li);
  });
  const n = 1 + live.length;                       // you + everyone whose link is still live
  const label = n + (n === 1 ? ' Participant' : ' Participants');
  qs('#mcount').textContent = label; qs('#invn').textContent = label; qs('#ncount').textContent = n;
  qs('#inve').hidden = here.length > 0;
}

function loadInvites(){
  fetch('/main/api/invites?' + new URLSearchParams({ dir: G.dir || '' }), { headers: H, cache: 'no-store' })
    .then(r => r.ok ? r.json() : [])
    .then(d => { invites = Array.isArray(d) ? d : []; renderInvites(); })
    .catch(renderInvites);
}

qs('#invform').addEventListener('submit', async e => {
  e.preventDefault();
  const name = qs('#invname').value.trim(); if (!name) return;
  const btn = e.target.querySelector('button'); btn.disabled = true;
  try {
    const r = await fetch('/main/api/invites', {
      method: 'POST', headers: { ...H, 'Content-Type': 'application/json' },
      body: JSON.stringify({ name, ttl: +qs('#invttl').value, dir: G.dir || '', items: scope ? scope.map(nameOf) : undefined, ...viewNow() })   // ttl in seconds, 0 = never
    });
    if (!r.ok) throw new Error(await r.text());
    const i = await r.json();
    invites.push(i);
    renderInvites(); e.target.reset();
    toast('Link created. Tap Copy to copy it');
  } catch (err) {
    toast('Couldn’t create link' + (err && err.message ? ': ' + err.message : ''));
  }
  btn.disabled = false;
});
})();
</script>

</body>
</html>`);
}

// ---------- gallery CSS ----------