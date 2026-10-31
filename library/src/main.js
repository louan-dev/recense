// Main: the owner's permanent library, backed by the MAIN bucket.
//
// Files live under files/<path>, exactly as they are in Gallery/Main on the Mac. rclone puts
// most of them there straight into R2; the page can add and delete files too. Artwork found in
// a file is cached under art/<path>, outside files/, so an rclone sync never sees it or deletes
// it. Deleting moves a file to trash/<date>/<path>, which the bucket empties after 30 days.
//
// The router lets a request in here only when it comes from the owner (see access.js).

import { OWNER, FOLDER_MAX, JUNK, MIME_BY_EXT, IMG_BY_EXT, isAudioish, cleanPath, urlPath, esc, notice, jsonResponse, serveObject } from "./common.js";
import { extractArt } from "./art.js";
import { mainComments, dropMainComment, renameComment, commentFields, syncLinkCovers } from "./public.js";
import { newHead, picType } from "./tagwrite.js";
import { renameInInvites } from "./invite.js";
import { galleryPage } from "./page/gallery.js";

const FILES = "files/";
const ART = "art/";
const TRASH = "trash/";
const ORDER = "order/";
const MARK = ".folder-"; // empty marker file files/<folder>/.folder-<16 hex>: made on the Mac, so rclone carries it through renames and moves
const ID_RE = /^[0-9a-f]{16}$/;
const PAGE_UPLOAD_MAX = 90 * 1024 * 1024;
const KEY_RE = /^@[0-9a-f]{16}$/;
const NAMES_MAX = 2000;
const NAME_MAX = 300;
const ORDER_BYTES = 128 * 1024;
const DAY = 86400000;
const TOUCH_MS = 7 * DAY;
const SEEN_GRACE = 30 * DAY;
const GONE_GRACE = 3 * DAY;
const SWEEP_MAX = 100;
const KEYS = "keys/";
const KEY_VAL_RE = /^[A-G][♯♭♮]?m?$/; // canonical original key: root, accidental, "m" for minor

const legacyKey = (rel) => ORDER + encodeURIComponent(rel) + ".json";
const pubOrder = (c) => ({ names: c.names, at: c.at, k: c.k });


// folder names in a saved order: "@<id>" keys or plain names (no slashes, no control characters, no . or ..)
// strict (saving): any bad entry or duplicate rejects the list; lenient (reading old files): bad entries are dropped
function cleanNames(list, strict) {
  if (!Array.isArray(list) || (strict && list.length > NAMES_MAX)) return null;
  const seen = new Set();
  const out = [];
  for (const x of list.slice(0, NAMES_MAX)) {
    const ok =
      typeof x === "string" &&
      (KEY_RE.test(x) || (x.length > 0 && x.length <= NAME_MAX && x !== "." && x !== ".." && !/[\u0000-\u001f\u007f\/\\]/.test(x)));
    if (ok && !seen.has(x)) {
      seen.add(x);
      out.push(x);
    } else if (strict) {
      return null;
    }
  }
  return out;
}

// order file = {"v":2,"names":[...],"at":<ms of the reorder>,"path":<folder when last seen>} + customMetadata.seen; old files (bare array) count as at:0
async function readOrder(env, rel) {
  const ref = await orderRef(env, rel);
  const cur = { ...ref, names: [], at: 0, etag: "", path: "", seen: 0 };
  try {
    let o = await env.MAIN.get(ref.key);
    if (o) cur.etag = o.etag;
    else if (ref.id) o = await env.MAIN.get(legacyKey(rel)); // saved before this folder had an id
    if (!o) return cur;
    const j = await o.json();
    const bare = Array.isArray(j);
    cur.names = cleanNames(bare ? j : j && j.names, false) || [];
    cur.at = bare ? 0 : Math.min(Math.max(Number(j && j.at) || 0, 0), Date.now() + 60000);
    cur.path = (!bare && j && typeof j.path === "string" && j.path) || "";
    cur.seen = Number((o.customMetadata || {}).seen) || o.uploaded.getTime();
  } catch (e) {}
  return cur;
}

async function folderId(env, rel) {
  if (!rel) return "";
  const pre = FILES + rel + "/" + MARK;
  try {
    const r = await env.MAIN.list({ prefix: pre, limit: 1 });
    const id = r.objects.length ? r.objects[0].key.slice(pre.length) : "";
    return ID_RE.test(id) ? id : "";
  } catch (e) {
    return "";
  }
}

// where a folder's order lives: under its id when it has one (survives renames), else under its path (the old layout)
async function orderRef(env, rel) {
  const id = await folderId(env, rel);
  return { id, k: id ? "id:" + id : "path:" + rel, key: id ? ORDER + "id/" + id + ".json" : legacyKey(rel) };
}

// compare-and-swap write: succeeds only if the record is still the version that was read (or still absent)
const putRec = (env, key, etag, text, meta) =>
  env.MAIN.put(key, text, {
    httpMetadata: { contentType: "application/json" },
    customMetadata: meta,
    onlyIf: etag ? { etagMatches: etag } : { etagDoesNotMatch: "*" },
  });

// once a folder has an id record, its pre-id path record is dead weight
const dropLegacy = (env, cur, rel) =>
  cur.id && !cur.etag ? env.MAIN.delete(legacyKey(rel)).catch(() => {}) : null;

// A folder that is being viewed is alive: re-stamp its record (and path hint) now and then, and upgrade name entries to id keys,
// so cleanup can never mistake a renamed-but-in-use folder for an orphan. CAS put, so it can't overwrite a reorder.
async function touchOrder(env, cur, rel, names) {
  const same = names.every((n, i) => n === cur.names[i]);
  if (cur.etag && same && cur.path === rel && Date.now() - cur.seen < TOUCH_MS) return;
  if (!cur.etag && !names.length) return;
  const text = JSON.stringify({ v: 2, names, at: cur.at, path: rel });
  if (await putRec(env, cur.key, cur.etag, text, { seen: String(Date.now()) }).catch(() => null)) await dropLegacy(env, cur, rel);
}

// Orphaned order records. Run daily from a cron trigger: scheduled(e, env, ctx) { ctx.waitUntil(orderSweep(env)); }
// Lists only order/. Records saved or viewed within 30 days are skipped without any further call. For the rest it checks that the
// folder still exists (path record: any object under files/<path>/; id record: the .folder-<id> marker at the recorded path).
// A missing folder is only marked (customMetadata.gone) the first time; it is deleted if it is still missing 3+ days later.
// A save or a view rewrites the record without the mark. The root's order (order/.json) is never touched.
export async function orderSweep(env) {
  const now = Date.now();
  let cursor;
  let work = 0;

  do {
    const r = await env.MAIN.list({ prefix: ORDER, cursor, include: ["customMetadata"] });
    cursor = r.truncated ? r.cursor : undefined;

    for (const o of r.objects) {
      const name = o.key.slice(ORDER.length, -5);
      const cm = o.customMetadata || {};
      const seen = Number(cm.seen) || o.uploaded.getTime();
      const gone = Number(cm.gone) || 0;

      if (!o.key.endsWith(".json") || !name) continue;
      if (!gone && now - seen < SEEN_GRACE) continue;
      if (work++ >= SWEEP_MAX) return; // the rest waits for the next run

      try {
        const body = await env.MAIN.get(o.key);
        if (!body) continue;
        const text = await body.text();
        let alive;

        if (name.startsWith("id/")) {
          let path = "";
          try {
            path = String(JSON.parse(text).path || "");
          } catch (e) {}
          alive = !!path && (await folderId(env, path)) === name.slice(3);
        } else {
          alive = (await env.MAIN.list({ prefix: FILES + decodeURIComponent(name) + "/", limit: 1 })).objects.length > 0;
        }

        if (alive) {
          await putRec(env, o.key, o.etag, text, { seen: String(now) });
        } else if (!gone) {
          await putRec(env, o.key, o.etag, text, { seen: String(seen), gone: String(now) });
        } else if (now - gone >= GONE_GRACE && now - seen >= SEEN_GRACE) {
          const h = await env.MAIN.head(o.key);
          if (h && h.etag === o.etag) await env.MAIN.delete(o.key);
        }
      } catch (e) {}
    }
  } while (cursor);
}
// Covers whose file is gone: deleted or renamed outside Gallery (on the mount, in the dashboard), so
// art/ still holds them under the old name, and a later file of that name would wear the old cover.
// Run daily from the cron. Each goes to the trash (trash/<day>/art/<path>, kept 30 days), then away.
export async function artSweep(env) {
  const day = new Date().toISOString().slice(0, 10);
  let cursor;
  let work = 0;

  do {
    const r = await env.MAIN.list({ prefix: ART, cursor });
    cursor = r.truncated ? r.cursor : undefined;

    for (const o of r.objects) {
      const rel = o.key.slice(ART.length);
      if (!rel || (await env.MAIN.head(FILES + rel))) continue;
      if (work++ >= SWEEP_MAX) return; // the rest waits for the next run

      try {
        await copyObject(env, o.key, TRASH + day + "/" + o.key);
        await env.MAIN.delete(o.key);
      } catch (e) {}
    }
  } while (cursor);
}

// a single request body is capped at 100 MB by Cloudflare; bigger files go through the mount

// The files (and subfolder prefixes) directly in one Main folder, with their comment threads.
export async function listFolder(env, rel) {
  const prefix = FILES + (rel ? rel + "/" : "");
  const folders = [];
  const objs = [];
  let cursor;

  do {
    const r = await env.MAIN.list({
      prefix,
      delimiter: "/",
      include: ["httpMetadata", "customMetadata"],
      cursor,
    });

    folders.push(...(r.delimitedPrefixes || []));
    objs.push(...r.objects);
    cursor = r.truncated && objs.length < FOLDER_MAX ? r.cursor : undefined;
  } while (cursor);

  const said = await mainComments(env, rel);
  const keys = await mainKeys(env, rel);
  const arts = await artIndex(env, prefix);
  const byName = (a, b) => a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" });
  const niceName = (s) => s.replace(/\.[^/.]+$/, (x) => x.toUpperCase());
  /** @type {any[]} */
  const items = [];

  for (const o of objs.slice(0, FOLDER_MAX)) {
    const name = o.key.slice(prefix.length);
    if (!name || JUNK.test(name) || name.startsWith(MARK)) continue;

    const ext = (name.split(".").pop() || "").toLowerCase();
    let type = (o.httpMetadata && o.httpMetadata.contentType) || "";

    if (/^(|application\/octet-stream|binary\/octet-stream)$/.test(type)) {
      type = MIME_BY_EXT[ext] || IMG_BY_EXT[ext] || "application/octet-stream";
    }

    // rclone keeps the file's own modification time here (seconds)
    const mtime = Number((o.customMetadata || {}).mtime);
    const path = o.key.slice(FILES.length);
    const at = "/main/f/" + urlPath(path);

    items.push({
      name: niceName(name),
      sortName: name,
      path,
      type,
      size: o.size,
      taken: mtime > 0 ? Math.round(mtime * 1000) : o.uploaded.getTime(),
      src: at,
      ...artFields(isAudioish(type, name), path, o, arts.get(name)),
      ...commentFields(said[name]),
      ...keyFields(keys[name]),
    });
  }

  items.sort((a, b) => byName(a.sortName, b.sortName));
  items.forEach((f, i) => {
    f.n = String(i).padStart(5, "0");
    delete f.sortName;
  });

  return { prefix, folders, items, byName };
}

// What is under art/ for one folder's files, by file name (one listing, not one read per file).
async function artIndex(env, prefix) {
  const out = new Map();
  const at = ART + prefix.slice(FILES.length);
  let cursor;

  do {
    const r = await env.MAIN.list({ prefix: at, delimiter: "/", include: ["customMetadata"], cursor });
    for (const o of r.objects) out.set(o.key.slice(at.length), o);
    cursor = r.truncated && out.size < FOLDER_MAX ? r.cursor : undefined;
  } while (cursor);

  return out;
}

// a deleted cover: no art address, and nocover so the page shows the file tile (not a same-named
// picture); otherwise the address carries a version, the art/ object's (else the file's, before
// its art has been looked at)
function artFields(audio, rel, file, art) {
  const m = (art && art.customMetadata) || {};
  if (m.deleted === "1") return { art: null, nocover: true };
  return { art: audio ? artUrl(rel, art ? art.etag : file.etag) : null };
}

// GET /main?p=<folder>
export async function mainFolder(env, url) {
  const rel = cleanPath(url.searchParams.get("p"));
  if (rel === null) return notice("Link not found", 404);

  // GET /main?p=<folder>&order=1  → the saved chip order as JSON
  if (url.searchParams.get("order") === "1") {
        return new Response(JSON.stringify(pubOrder(await readOrder(env, rel))), {
      headers: { "content-type": "application/json", "cache-control": "no-store" },
    });
  }

  const { prefix, folders, items, byName } = await listFolder(env, rel);

  const subs = folders
    .map((p) => p.slice(prefix.length).replace(/\/$/, ""))
    .filter((x) => x && !JUNK.test(x))
    .sort(byName);

   // saved chip order, matched by folder id (survives renames); a folder with no saved spot stays alphabetical, after the saved ones
  const cur = await readOrder(env, rel);
  const ids = new Map();
  await Promise.all(subs.slice(0, 150).map(async (s) => ids.set(s, await folderId(env, (rel ? rel + "/" : "") + s))));
  const uses = new Map();
  for (const id of ids.values()) if (id) uses.set(id, (uses.get(id) || 0) + 1);
  const keyOf = (s) => (ids.get(s) && uses.get(ids.get(s)) === 1 ? "@" + ids.get(s) : s); // a copied folder (same id twice) falls back to its name
  const pos = (x) => {
    let i = cur.names.indexOf(keyOf(x));
    if (i < 0) i = cur.names.indexOf(x); // saved before the folder had an id
    return i < 0 ? cur.names.length : i;
  };
  subs.sort((a, b) => pos(a) - pos(b));
  if (items.length || subs.length) await touchOrder(env, cur, rel, cur.names.map((n) => (ids.get(n) ? keyOf(n) : n)));

  const here = rel ? rel.split("/") : [];
  const title = here.length ? here[here.length - 1] : "Main Gallery";
  const go = (p) => (p ? "/main?p=" + encodeURIComponent(p) : "/main");

  const crumbs = [`<a href="/main/">Main Gallery</a>`]
    .concat(here.map((x, i) => `<a href="${go(here.slice(0, i + 1).join("/"))}">${esc(x)}</a>`))
    .join("<i>/</i>");

  const links = subs
    .map((x) => `<a class="fd" href="${go((rel ? rel + "/" : "") + x)}" data-p="${esc((rel ? rel + "/" : "") + x)}" data-k="${encodeURIComponent(keyOf(x))}">${esc(x)}</a>`)
    .join("");

  const empty =
    !items.length && !subs.length
      ? `<p class="none">${rel ? "This folder is empty." : "Nothing in Main yet."}</p>`
      : "";

  const nav = `<style>
.mainnav{padding:0 16px 14px;font:500 15px -apple-system,BlinkMacSystemFont,sans-serif}
.mainnav .cr{color:rgba(255,255,255,.55);margin-bottom:10px;overflow-wrap:anywhere}
.mainnav .cr a{color:inherit;text-decoration:none}
.mainnav .cr a:last-child{color:#fff}
.mainnav .cr i{font-style:normal;margin:0 6px;opacity:.5}
.mainnav h2{margin:0 0 10px;font:700 22px -apple-system,BlinkMacSystemFont,sans-serif;color:#fff}
.mainnav .fs{display:grid;grid-template-rows:repeat(3,auto);grid-auto-flow:column;grid-auto-columns:minmax(150px,calc((100% - 16px)/2.3));gap:8px;overflow-x:auto;scrollbar-width:none;cursor:grab;user-select:none;-webkit-user-select:none}
.mainnav .fs::-webkit-scrollbar{display:none}
.mainnav .sh{display:block;color:#0a84ff;font:600 16px -apple-system,BlinkMacSystemFont,sans-serif;text-decoration:none;padding:12px 14px;border-radius:12px;background:#1c1c1e;margin-bottom:8px}
body.selecting .mainnav .fd{position:relative;padding-right:40px}
body.selecting .mainnav .fd::after{content:"";position:absolute;right:12px;top:50%;width:18px;height:18px;margin-top:-10px;border:1.5px solid #0a84ff;border-radius:50%}
body.selecting .mainnav .fd.on::after{background:#0a84ff;box-shadow:inset 0 0 0 3px #1c1c1e}
.mainnav .fs.dragging{cursor:grabbing}
.mainnav .fd{color:#fff;font:500 16px -apple-system,BlinkMacSystemFont,sans-serif;text-decoration:none;padding:14px 14px;border-radius:12px;background:#1c1c1e;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
</style>
<nav class="mainnav">${links || !rel ? `<h2>Collections</h2>${rel ? "" : `<a class="sh" href="/main/shared">Shared</a>`}<div class="fs">${links}</div>` : ""}${empty}</nav>
<style>
.mainnav .fs{touch-action:pan-x}
.mainnav .fd{-webkit-touch-callout:none}
.mainnav .fd.lift{position:relative;z-index:5;background:rgba(255,255,255,.22);transition:none}
</style>
<script>
(function(){
  var bar=document.querySelector(".mainnav .fs");
  if(!bar)return;
  var dir=${JSON.stringify(rel).replace(/</g, "\\u003c")};
  var HOLD=250,MOVE=6,timer=null,chip=null,lifted=false,scrolling=false,suppress=false;
  var id=null,type="",sx=0,sl=0,px=0,py=0,gy=0,grab=0,loop=null,before="";

 var oid=${JSON.stringify(cur.k).replace(/</g, "\\u003c")},lk="fo2:"+oid,syncing=0;

  function key(a){var v=a.getAttribute("data-k");try{return v===null?a.textContent:decodeURIComponent(v)}catch(e){return a.textContent}}
  function names(){return [].map.call(bar.children,key)}
  function readLocal(){try{var o=JSON.parse(localStorage.getItem(lk)||"null");return o&&o.v===2?o:null}catch(e){return null}}
  function writeLocal(list,dirty,at){
    try{localStorage.setItem(lk,JSON.stringify({v:2,names:list,dirty:!!dirty,at:at||0,t:Date.now()}))}catch(e){}
  }

  // cache housekeeping: an unsent change under the old path-keyed entry moves to this folder's id-keyed entry; other stale entries are dropped
  (function(){
    try{
      var old="folderOrder:"+dir,o=JSON.parse(localStorage.getItem(old)||"null");
      if(o){localStorage.removeItem(old);if(o.dirty&&!readLocal())writeLocal(o.names,true,o.at)}
      for(var i=localStorage.length-1;i>=0;i--){
        var k=localStorage.key(i),v=null;
        if(!k||(k.indexOf("folderOrder:")!==0&&k.indexOf("fo2:")!==0))continue;
        try{v=JSON.parse(localStorage.getItem(k)||"null")}catch(x){}
        if(!v||(!v.dirty&&(k.indexOf("fo2:")!==0||v.v!==2||Date.now()-v.t>2592e6)))localStorage.removeItem(k);
      }
    }catch(e){}
  })();

  // cache housekeeping: an unsent change under the old path-keyed entry moves to this folder's id-keyed entry; other stale entries are dropped
  (function(){
    try{
      var old="folderOrder:"+dir,o=JSON.parse(localStorage.getItem(old)||"null");
      if(o){localStorage.removeItem(old);if(o.dirty&&!readLocal())writeLocal(o.names,true,o.at)}
      for(var i=localStorage.length-1;i>=0;i--){
        var k=localStorage.key(i),v=null;
        if(!k||(k.indexOf("folderOrder:")!==0&&k.indexOf("fo2:")!==0))continue;
        try{v=JSON.parse(localStorage.getItem(k)||"null")}catch(x){}
        if(!v||(!v.dirty&&(k.indexOf("fo2:")!==0||v.v!==2||Date.now()-v.t>2592e6)))localStorage.removeItem(k);
      }
    }catch(e){}
  })();

// reorder the chips to match a list of keys (old lists hold plain names; unlisted chips keep their order, after the listed ones)
  function apply(list){
    if(!Array.isArray(list))return;
    var orig=[].slice.call(bar.children),cur=orig.slice(),next=[];
    list.forEach(function(n){
      for(var i=0;i<cur.length;i++){
        if(cur[i]&&(key(cur[i])===n||cur[i].textContent===n)){next.push(cur[i]);cur[i]=null;break}
      }
    });
    cur.forEach(function(a){if(a)next.push(a)});
    if(next.every(function(a,i){return a===orig[i]}))return;
    next.forEach(function(a){bar.appendChild(a)});
  }

    // browser -> R2 (keeps the time of the reorder; a 409 means R2 holds a newer order, so take it)
  function push(list,at){
    syncing++;
    fetch("/main/api/file?order=1&dir="+encodeURIComponent(dir),{
      method:"PUT",
      keepalive:JSON.stringify({names:list,at:at}).length<60000,
      headers:{"content-type":"application/json"},
      body:JSON.stringify({names:list,at:at})
    }).then(function(r){
      var c=readLocal();
      if(r.ok){if(c&&c.at===at)writeLocal(list,false,at);return}
      if(r.status===400||r.status===413){try{localStorage.removeItem(lk)}catch(e){}return} // the server will never accept this payload: drop it, pull() shows R2's order
      if(r.status===400||r.status===413){try{localStorage.removeItem(lk)}catch(e){}return} // the server will never accept this payload: drop it, pull() shows R2's order
      if(r.status===409)return r.json().then(function(s){
        c=readLocal();
        if(c&&c.dirty&&c.at>s.at)return;
        if(Array.isArray(s.names)&&!lifted&&!timer){apply(s.names);writeLocal(names(),false,s.at)}
      });
    }).catch(function(){})
      .then(function(){syncing--});
  }

  function save(){
    var list=names(),at=Date.now();
    writeLocal(list,true,at);
    push(list,at);
  }

  // R2 -> browser (an unsent local change is retried with its original time, so it can't beat a newer one)
  function pull(){
    if(lifted||timer||syncing||document.hidden)return;
    var loc=readLocal();
    if(loc&&loc.dirty){push(loc.names,loc.at);return}
    fetch("/main"+(dir?"?p="+encodeURIComponent(dir)+"&order=1":"?order=1"),{cache:"no-store"})
      .then(function(r){return r.ok?r.json():null})
      .then(function(s){
        if(!s||!Array.isArray(s.names)||lifted||timer||syncing)return;
        if(s.k&&s.k!==oid){try{localStorage.removeItem(lk)}catch(e){}oid=s.k;lk="fo2:"+oid} // the folder's identity changed since this page loaded: its cache entry is stale
        var c=readLocal();
        if(c&&c.dirty)return;
        apply(s.names);
        writeLocal(names(),false,s.at);
      }).catch(function(){});
  }

  var first=readLocal();
  if(first&&first.dirty)apply(first.names);
  pull();
  setInterval(pull,20000);
  document.addEventListener("visibilitychange",pull);
  window.addEventListener("focus",pull);

  function place(){
    if(!chip)return;
    // grid of 3 per column: drop onto whichever tile the lifted tile's centre is over
    var cx=px-grab+chip.offsetWidth/2,cy=py-gy+chip.offsetHeight/2;
    var all=[].slice.call(bar.children),from=all.indexOf(chip);
    for(var i=0;i<all.length;i++){
      if(all[i]===chip)continue;
      var r=all[i].getBoundingClientRect();
      if(cx>=r.left&&cx<=r.right&&cy>=r.top&&cy<=r.bottom){bar.insertBefore(chip,i>from?all[i].nextSibling:all[i]);break}
    }
    chip.style.transform="";
    var nb=chip.getBoundingClientRect();
    chip.style.transform="translate("+(px-grab-nb.left)+"px,"+(py-gy-nb.top)+"px)";
  }

  function tick(){
    var b=bar.getBoundingClientRect();
    if(px<b.left+40)bar.scrollLeft-=12;
    else if(px>b.right-40)bar.scrollLeft+=12;
    place();
  }

  function lift(){
    timer=null;lifted=true;suppress=true;before=JSON.stringify(names());
    chip.classList.add("lift");
    try{bar.setPointerCapture(id)}catch(e){}
    grab=px-chip.getBoundingClientRect().left;gy=py-chip.getBoundingClientRect().top;
    if(navigator.vibrate)navigator.vibrate(10);
    loop=setInterval(tick,16);
    place();
  }

  function end(e){
    if(e&&e.pointerId!==id)return;
    clearTimeout(timer);timer=null;
    if(loop){clearInterval(loop);loop=null}
    if(lifted&&chip){chip.classList.remove("lift");chip.style.transform="";if(JSON.stringify(names())!==before)save()}
    bar.classList.remove("dragging");
    lifted=false;scrolling=false;chip=null;id=null;
  }

  bar.addEventListener("pointerdown",function(e){
    if(e.button>0||lifted)return;
    suppress=false;scrolling=false;
    id=e.pointerId;type=e.pointerType;sx=px=e.clientX;py=e.clientY;sl=bar.scrollLeft;
    chip=e.target.closest?e.target.closest(".fd"):null;
    clearTimeout(timer);timer=null;
    if(chip)timer=setTimeout(lift,HOLD);
  });

  bar.addEventListener("pointermove",function(e){
    if(e.pointerId!==id)return;
    px=e.clientX;py=e.clientY;
    if(lifted){place();return}
    if(Math.abs(px-sx)>MOVE){
      if(timer){clearTimeout(timer);timer=null}
      if(type==="mouse"){
        if(!scrolling){
          scrolling=true;suppress=true;bar.classList.add("dragging");
          try{bar.setPointerCapture(id)}catch(err){}
        }
        bar.scrollLeft=sl-(px-sx);
      }
    }
  });

  bar.addEventListener("pointerup",end);
  bar.addEventListener("pointercancel",end);
  bar.addEventListener("touchmove",function(e){if(lifted&&e.cancelable)e.preventDefault()},{passive:false});
  bar.addEventListener("contextmenu",function(e){if(chip||lifted)e.preventDefault()});
  bar.addEventListener("dragstart",function(e){e.preventDefault()});
  bar.addEventListener("click",function(e){
    if(suppress){e.preventDefault();e.stopPropagation();suppress=false}
  },true);
})();
</script>`;

  return galleryPage(
    {
      id: "main",
      main: true,
      dir: rel,
      uploadMax: PAGE_UPLOAD_MAX,
      owner: OWNER,
      title,
      heading: "Presented by " + OWNER,
      zip: title + ".zip",
      exp: 0,
      expected: items.length,
      ready: items.length,
      complete: true,
      items,
    },
    nav,
    `<div class="crbar">${crumbs}</div>`
  );
}

// GET /main/f/<path>   (?art=1 for embedded artwork, ?dl=1 to download)
export async function mainFile(req, env, ctx, url, encoded) {
  const rel = cleanPath(encoded, true);
  if (!rel) return notice("Link not found", 404);

  if (url.searchParams.get("art") === "1") return mainArt(env, ctx, rel);

  let obj;

  try {
    obj = await env.MAIN.get(FILES + rel, { range: req.headers });
  } catch (e) {
    return new Response("Bad range", { status: 416 });
  }

  if (!obj) return notice("Link not found", 404);

  const name = rel.split("/").pop();
  const ext = (name.split(".").pop() || "").toLowerCase();

  return serveObject(req, url, obj, name, MIME_BY_EXT[ext] || IMG_BY_EXT[ext]);
}

// Artwork inside a file, read once and kept under art/.
async function mainArt(env, ctx, rel) {
  const none = () =>
    new Response("No artwork", {
      status: 404,
      headers: { "cache-control": "private, max-age=3600" },
    });

  const pic = (body, type) =>
    new Response(body, {
      headers: {
        "content-type": type,
        "cache-control": "private, max-age=3600",
        "x-content-type-options": "nosniff",
      },
    });

  const keep = (p) => {
    if (ctx && ctx.waitUntil) ctx.waitUntil(Promise.resolve(p).catch(() => {}));
  };

  const cached = await env.MAIN.get(ART + rel);

  if (cached) {
    if ((cached.customMetadata || {}).none === "1") return none();
    return pic(cached.body, (cached.httpMetadata && cached.httpMetadata.contentType) || "image/jpeg");
  }

  const head = await env.MAIN.head(FILES + rel);
  const name = rel.split("/").pop();

  if (!head || !isAudioish(head.httpMetadata && head.httpMetadata.contentType, name)) {
    return none();
  }

  let art = null;

  try {
    art = await extractArt(env.MAIN, FILES + rel, head.size);
  } catch (e) {}

  if (!art) {
    keep(env.MAIN.put(ART + rel, new Uint8Array(0), { customMetadata: { none: "1" } }));
    return none();
  }

  const bytes = art.data.slice();

  keep(env.MAIN.put(ART + rel, bytes, { httpMetadata: { contentType: art.mime } }));

  return pic(bytes, art.mime);
}

// PUT /main/api/file?key=<path>&mtime=<ms>   body: the file; a file with the same path is replaced
// PUT /main/api/file?order=1&dir=<folder>   body: JSON array of folder names, in order
async function mainOrderSave(req, env, url) {
  const rel = cleanPath(url.searchParams.get("dir") || "");
  if (rel === null) return new Response("Bad folder", { status: 400 });

   const lh = req.headers.get("content-length");
  const len = lh === null ? NaN : Number(lh);
  if (!Number.isSafeInteger(len) || len > ORDER_BYTES) return new Response("Order too big", { status: 413 });

  let body;
  try {
    body = await req.json();
  } catch (e) {
    return new Response("Bad order", { status: 400 });
  }

  // {names, at} or the legacy bare array; an unknown shape, a bad name or a duplicate rejects the whole save
  const obj = Array.isArray(body) ? { names: body } : body;
  const names = obj && typeof obj === "object" ? cleanNames(obj.names, true) : null;
  if (!names) return new Response("Bad order", { status: 400 });

  // the reorder's own time: up to a day ahead is accepted but clamped to 60 s ahead, so a wrong clock can't freeze the order
  const now = Date.now();
  if (obj.at !== undefined && (typeof obj.at !== "number" || !Number.isFinite(obj.at) || obj.at <= 0 || obj.at > now + DAY)) {
    return new Response("Bad time", { status: 400 });
  }
  const at = Math.min(Math.floor(obj.at === undefined ? now : obj.at), now + 60000);
  const stale = (c) =>
    new Response(JSON.stringify(pubOrder(c)), {
      status: 409,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
    });

  // compare-and-swap on the record's etag: two saves racing can't both see "nothing newer" and then overwrite each other
  for (let i = 0; i < 6; i++) {
    const cur = await readOrder(env, rel);
    if (at < cur.at) return stale(cur); // a newer order is already saved: refuse and hand it back
    const text = JSON.stringify({ v: 2, names, at, path: rel });
    if (await putRec(env, cur.key, cur.etag, text, { seen: String(now) })) {
      await dropLegacy(env, cur, rel);
      return jsonResponse({ ok: true, at, k: cur.k });
    }
  }
  return stale(await readOrder(env, rel)); // still racing: let the client reconcile
}

export async function mainUpload(req, env, url) {
  if (url.searchParams.get("order") === "1") return mainOrderSave(req, env, url);

  const rel = cleanPath(url.searchParams.get("key"));
  if (!rel) return new Response("Bad file path", { status: 400 });

  const length = req.headers.get("content-length");
  const size = length === null ? NaN : Number(length);
  if (!Number.isSafeInteger(size) || size > PAGE_UPLOAD_MAX) {
    return new Response("Too big for the browser", { status: 413 });
  }
  if (!req.body) return new Response("Missing file", { status: 400 });

  const contentType = (req.headers.get("content-type") || "application/octet-stream").slice(0, 200);
  const modified = Number(url.searchParams.get("mtime"));
  const mtime = Number.isFinite(modified) && modified > 0 ? Math.floor(modified / 1000) : Math.floor(Date.now() / 1000);

  await env.MAIN.put(FILES + rel, req.body, {
    httpMetadata: { contentType },
    customMetadata: { mtime: String(mtime) },
  });
  await env.MAIN.delete(ART + rel);

  return jsonResponse({ ok: true, key: rel });
}

// DELETE /main/api/file?key=<path>   moves the file to trash/<date>/<path>
export async function mainDelete(env, url) {
  const rel = cleanPath(url.searchParams.get("key"));
  if (!rel) return new Response("Bad file path", { status: 400 });
  if (!(await trashFile(env, rel))) return new Response("Not found", { status: 404 });
  return jsonResponse({ ok: true, key: rel });
}

// files/<rel> to trash/<date>/<rel>, with its artwork, comment and key gone; false if there is no such file
export async function trashFile(env, rel) {
  const obj = await env.MAIN.get(FILES + rel);
  if (!obj) return false;

  const day = new Date().toISOString().slice(0, 10);
  const { readable, writable } = new FixedLengthStream(obj.size);
  const copied = obj.body.pipeTo(writable);

  await env.MAIN.put(TRASH + day + "/" + rel, readable, {
    httpMetadata: obj.httpMetadata,
    customMetadata: obj.customMetadata,
  });
  await copied;
  await env.MAIN.delete([FILES + rel, ART + rel]);
  await dropMainComment(env, rel).catch(() => {});
  await moveMainKey(env, rel, null).catch(() => {});
  return true;
}

// the file as it was, kept in the trash before something replaces it (WebDAV overwrites)
export const keepInTrash = (env, rel) =>
  copyObject(env, FILES + rel, TRASH + new Date().toISOString().slice(0, 10) + "/" + rel + "@" + new Date().toISOString().replace(/[:.]/g, "-"));
// Copies one object to another key, streamed, with its metadata (and any changes to it).
async function copyObject(env, from, to, meta = {}, onlyIf) {
  const obj = await env.MAIN.get(from);
  if (!obj) return null;

  const { readable, writable } = new FixedLengthStream(obj.size);
  const copied = obj.body.pipeTo(writable);
  const put = await env.MAIN.put(to, readable, {
    httpMetadata: obj.httpMetadata,
    customMetadata: { ...(obj.customMetadata || {}), ...meta },
    onlyIf,
  });
  // a refused conditional put may leave the stream unread
  if (put) await copied;
  else copied.catch(() => {});
  return put;
}

// POST /main/api/rename   { path, name }   renames a file in its folder, in R2 (so the mount sees it
// within a minute), and carries its artwork, comments and invites along. The file remembers its
// first path ("was"), so Recense's transcript of it is still found.
export async function mainRename(req, env) {
  let b;
  try {
    b = await req.json();
  } catch (e) {
    return new Response("Bad request", { status: 400 });
  }

  const rel = cleanPath(String((b && b.path) || ""));
  let name = String((b && b.name) || "").trim();
  if (!rel) return new Response("Bad file path", { status: 400 });

  const ext = (rel.match(/\.[^/.]+$/) || [""])[0];
  if (ext && !/\.[^/.]+$/.test(name)) name += ext; // keep the extension when it is left off
  if (!name || name.length > NAME_MAX || name.includes("/") || name.startsWith(".") || /[\u0000-\u001f\u007f\\]/.test(name)) {
    return new Response("That name can’t be used", { status: 400 });
  }

  const dir = rel.split("/").slice(0, -1).join("/");
  const to = (dir ? dir + "/" : "") + name;
  if (to === rel) return jsonResponse({ ok: true, path: rel });
  if (await env.MAIN.head(FILES + to)) return new Response("A file with that name is already here", { status: 409 });

  const head = await env.MAIN.head(FILES + rel);
  if (!head) return new Response("Not found", { status: 404 });

  const was = (head.customMetadata || {}).was || rel;
  if (!(await copyObject(env, FILES + rel, FILES + to, { was }))) return new Response("Not found", { status: 404 });
  await env.MAIN.delete(FILES + rel);

  await copyObject(env, ART + rel, ART + to).catch(() => {});
  await env.MAIN.delete(ART + rel).catch(() => {});
  await renameComment(env, rel, to).catch(() => {});
  await moveMainKey(env, rel, to).catch(() => {});
  await renameInInvites(env, dir, rel.split("/").pop(), name).catch(() => {});

  return jsonResponse({ ok: true, path: to, name, src: "/main/f/" + urlPath(to) });
}

// ---------- folders and moves (the file dashboard) ----------
//
// Every key is FILES + a path that passed cleanPath (no empty, "." or ".." segments, no control
// characters), so nothing can reach art/, trash/, order/, invites/ or outside the bucket. Names
// of new folders are one segment and never hidden. A move only goes into a folder that already
// exists, and never over a file that is already there.

const MOVE_MAX = 200;

// one new path segment (a folder or file name; null when it can't be used): one segment, not hidden, not junk
export function segmentName(s) {
  if (typeof s !== "string") return null;
  const name = s.normalize("NFC").trim();
  if (!name || name.length > NAME_MAX || name.startsWith(".") || JUNK.test(name)) return null;
  if (/[\u0000-\u001f\u007f\/\\]/.test(name)) return null;
  return name;
}

// a folder exists when something is stored under it (its .folder- marker at least); the root always does
export async function folderExists(env, rel, prefix = FILES) {
  if (!rel) return true;
  const r = await env.MAIN.list({ prefix: prefix + rel + "/", limit: 1 });
  return r.objects.length > 0 || (r.delimitedPrefixes || []).length > 0;
}

// GET /main/api/folders?p=<folder>   -> { path, folders: [names] }   for the Move picker
export async function mainFolders(env, url) {
  const rel = cleanPath(url.searchParams.get("p") || "");
  if (rel === null) return new Response("Bad folder path", { status: 400 });
  if (!(await folderExists(env, rel))) return new Response("Not found", { status: 404 });

  const prefix = FILES + (rel ? rel + "/" : "");
  const out = [];
  let cursor;
  do {
    const r = await env.MAIN.list({ prefix, delimiter: "/", cursor });
    for (const p of r.delimitedPrefixes || []) {
      const name = p.slice(prefix.length).replace(/\/$/, "");
      if (name && !JUNK.test(name)) out.push(name);
    }
    cursor = r.truncated && out.length < FOLDER_MAX ? r.cursor : undefined;
  } while (cursor);

  out.sort((a, b) => a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" }));
  return jsonResponse({ path: rel, folders: out });
}

// POST /main/api/folder   { dir, name }   makes files/<dir>/<name>/ with its .folder-<id> marker,
// the same empty file the Mac makes, so the folder keeps its place in the chip order across renames
export async function mainNewFolder(req, env) {
  let b;
  try {
    b = await req.json();
  } catch (e) {
    return new Response("Bad request", { status: 400 });
  }

  const dir = cleanPath(typeof (b && b.dir) === "string" ? b.dir : b && b.dir == null ? "" : "\u0000");
  const name = segmentName(b && b.name);
  if (dir === null) return new Response("Bad folder path", { status: 400 });
  if (!name) return new Response("That name can’t be used", { status: 400 });
  if (!(await folderExists(env, dir))) return new Response("Not found", { status: 404 });

  const rel = (dir ? dir + "/" : "") + name;
  if ((await folderExists(env, rel)) || (await env.MAIN.head(FILES + rel))) {
    return new Response("Something with that name is already here", { status: 409 });
  }

  await makeFolder(env, FILES, rel);
  return jsonResponse({ ok: true, path: rel, href: "/main?p=" + encodeURIComponent(rel) });
}

// the empty .folder-<id> marker that makes <prefix><rel>/ a folder
export async function makeFolder(env, prefix, rel, bucket = env.MAIN) {
  const id = [...crypto.getRandomValues(new Uint8Array(8))].map((x) => x.toString(16).padStart(2, "0")).join("");
  await bucket.put(prefix + rel + "/" + MARK + id, "", {
    customMetadata: { mtime: String(Math.floor(Date.now() / 1000)) },
    onlyIf: { etagDoesNotMatch: "*" },
  });
}

// One file to a new path (another folder, another name, or both), with its artwork, comments and
// key; never over a file that is already there. Rooms follow a rename and lose a file that leaves
// their folder. -> null when done, else why not
export async function moveFile(env, rel, to) {
  const head = await env.MAIN.head(FILES + rel);
  if (!head) return "not found";

  const was = (head.customMetadata || {}).was || rel;
  if (!(await copyObject(env, FILES + rel, FILES + to, { was }, { etagDoesNotMatch: "*" }))) return "a file with that name is already there";
  await env.MAIN.delete(FILES + rel);

  const dir = rel.split("/").slice(0, -1).join("/");
  const toDir = to.split("/").slice(0, -1).join("/");
  const name = rel.split("/").pop();
  if (await copyObject(env, ART + rel, ART + to).catch(() => null)) await env.MAIN.delete(ART + rel).catch(() => {});
  await renameComment(env, rel, to).catch(() => {});
  await moveMainKey(env, rel, to).catch(() => {});
  await renameInInvites(env, dir, name, toDir === dir ? to.split("/").pop() : null).catch(() => {});
  return null;
}

// POST /main/api/move   { paths: [file paths], to: <folder> }   moves files into another folder,
// with their artwork, comments and key. Rooms (invites to some items) in the old folder lose them.
//   -> { ok, moved: [{ from, to }], failed: [{ path, why }] }
export async function mainMove(req, env) {
  let b;
  try {
    b = await req.json();
  } catch (e) {
    return new Response("Bad request", { status: 400 });
  }

  const dest = cleanPath(typeof (b && b.to) === "string" ? b.to : "\u0000");
  const list = b && Array.isArray(b.paths) ? b.paths : null;
  if (dest === null) return new Response("Bad folder path", { status: 400 });
  if (!list || !list.length || list.length > MOVE_MAX) return new Response("Bad file list", { status: 400 });

  const paths = [];
  for (const x of list) {
    const rel = typeof x === "string" ? cleanPath(x) : null;
    const name = rel && rel.split("/").pop();
    // a file, never the root or a folder's marker
    if (!rel || name.startsWith(MARK) || JUNK.test(name)) return new Response("Bad file path", { status: 400 });
    if (!paths.includes(rel)) paths.push(rel);
  }
  if (!(await folderExists(env, dest))) return new Response("Not found", { status: 404 });

  const moved = [];
  const failed = [];
  for (const rel of paths) {
    const dir = rel.split("/").slice(0, -1).join("/");
    const name = rel.split("/").pop();
    const to = (dest ? dest + "/" : "") + name;
    if (dir === dest) {
      moved.push({ from: rel, to: rel });
      continue;
    }

    const why = await moveFile(env, rel, to);
    if (why) failed.push({ path: rel, why });
    else moved.push({ from: rel, to });
  }

  return jsonResponse({ ok: !failed.length, moved, failed }, failed.length && !moved.length ? 409 : 200);
}

const COVER_MAX = 10 * 1024 * 1024;

// art/<path> says what the grid shows for a file: a picture (custom: "1" when the owner chose it),
// none: "1" when the file has none, and deleted: "1" too when the owner deleted it (Delete cover).
// The grid's art address carries the art/ object's etag, so a changed cover is never hidden by a
// cached copy.
const artVer = (etag) => String(etag || "").replace(/[^A-Za-z0-9]/g, "").slice(0, 12);
const artUrl = (rel, etag) => "/main/f/" + urlPath(rel) + "?art=1&v=" + artVer(etag);

// The file's tag rebuilt with this picture (or with none, pic null): MP3 and FLAC only. The file as
// it was is kept in the trash first, and the new one is only written if nobody changed it meanwhile.
async function retag(env, rel, head, pic, why) {
  const plan = await newHead(env.MAIN, FILES + rel, head.size, pic).catch(() => null);
  if (!plan) return false;

  const backup = TRASH + new Date().toISOString().slice(0, 10) + "/" + rel + why;
  await copyObject(env, FILES + rel, backup);

  const rest = await env.MAIN.get(backup, { range: { offset: plan.rest } });
  const restLen = head.size - plan.rest;
  const { readable, writable } = new FixedLengthStream(plan.head.length + restLen);
  const pump = (async () => {
    const w = writable.getWriter();
    await w.write(plan.head);
    w.releaseLock();
    if (rest && restLen > 0) await rest.body.pipeTo(writable);
    else await writable.close();
  })();

  const put = await env.MAIN.put(FILES + rel, readable, {
    httpMetadata: head.httpMetadata,
    customMetadata: { ...(head.customMetadata || {}), mtime: String(Math.floor(Date.now() / 1000)) },
    onlyIf: { etagMatches: head.etag },
  });
  await pump.catch(() => {});
  // the file as it was stays in the trash for 30 days; nothing to keep when nothing was written
  if (!put) await env.MAIN.delete(backup).catch(() => {});
  return !!put;
}

// PUT /main/api/cover?path=<file>   body: a JPEG or PNG. The page shows it at once (art/), and an
// MP3 or FLAC gets it written into its own tags, so the file on the mount carries it too. Share
// links already made from the file get the new cover as well.
export async function mainCover(req, env, url) {
  const rel = cleanPath(url.searchParams.get("path") || "");
  if (!rel) return new Response("Bad file path", { status: 400 });

  const len = Number(req.headers.get("content-length"));
  if (!(len > 0) || len > COVER_MAX) return new Response("Pick a picture under 10 MB", { status: 413 });

  const data = new Uint8Array(await req.arrayBuffer());
  const mime = picType(data);
  if (!mime) return new Response("The cover must be a JPEG or PNG", { status: 415 });

  const head = await env.MAIN.head(FILES + rel);
  if (!head) return new Response("Not found", { status: 404 });

  const art = await env.MAIN.put(ART + rel, data, { httpMetadata: { contentType: mime }, customMetadata: { custom: "1" } });
  const embedded = await retag(env, rel, head, { mime, data }, ".before-cover");
  await syncLinkCovers(env, rel, { data, mime }).catch(() => {});

  return jsonResponse({ ok: true, embedded, art: artUrl(rel, art.etag) });
}

// DELETE /main/api/cover?path=<file>   the file shows no cover any more: the grid gets the file
// tile, an MP3 or FLAC has its pictures taken out of its tags (the file as it was goes to the trash),
// and share links already made from it lose the cover too.
export async function mainCoverDelete(env, url) {
  const rel = cleanPath(url.searchParams.get("path") || "");
  if (!rel) return new Response("Bad file path", { status: 400 });

  const head = await env.MAIN.head(FILES + rel);
  if (!head) return new Response("Not found", { status: 404 });

  await env.MAIN.put(ART + rel, new Uint8Array(0), { customMetadata: { none: "1", deleted: "1" } });
  const stripped = await retag(env, rel, head, null, ".before-delete-cover");
  await syncLinkCovers(env, rel, null).catch(() => {});

  return jsonResponse({ ok: true, stripped, art: null, nocover: true });
}

// ---------- original keys (the Key slider's labels) ----------
//
// keys/<folder>/.keys.json   { "<file name>": { auto, manual, at } }   (outside files/ and art/, like notes/)
//   auto     found by the page when the file was uploaded through it (or by Detect in Info)
//   manual   set by the owner in Info; it wins over auto
// A value is canonical: "E♭m", "D♭", "E♮m" (the page parses what was typed).

const keysKey = (dir) => KEYS + (dir ? dir + "/" : "") + ".keys.json";

export async function mainKeys(env, dir) {
  try {
    const o = await env.MAIN.get(keysKey(dir));
    const j = o ? await o.json() : null;
    return j && typeof j === "object" && !Array.isArray(j) ? j : {};
  } catch (e) {
    return {};
  }
}

// what an item list carries: the key in force and where it came from (nothing when there is none)
export function keyFields(v) {
  const k = v && (v.manual || v.auto);
  return k ? { key: k, keySrc: v.manual ? "manual" : "auto" } : {};
}

const saveKeys = (env, dir, map) =>
  Object.keys(map).length
    ? env.MAIN.put(keysKey(dir), JSON.stringify(map), { httpMetadata: { contentType: "application/json" } })
    : env.MAIN.delete(keysKey(dir));

// a file was renamed or moved (to) or went to the trash (null): its key follows it, or goes
async function moveMainKey(env, rel, to) {
  const dir = rel.split("/").slice(0, -1).join("/");
  const toDir = to ? to.split("/").slice(0, -1).join("/") : dir;
  const map = await mainKeys(env, dir);
  const a = rel.split("/").pop();
  if (!map[a]) return;
  const there = toDir === dir ? map : await mainKeys(env, toDir);
  if (to) there[to.split("/").pop()] = map[a];
  delete map[a];
  if (there !== map) await saveKeys(env, toDir, there);
  await saveKeys(env, dir, map);
}

// PUT /main/api/key   { path, key, src: "auto" | "manual" }   key "" clears that source
//   -> { ok, key, keySrc }   (the key in force afterwards)
export async function mainKey(req, env) {
  let b;
  try {
    b = await req.json();
  } catch (e) {
    return new Response("Bad request", { status: 400 });
  }

  const rel = cleanPath(String((b && b.path) || ""));
  const src = b && b.src;
  const key = String((b && b.key) || "");
  if (!rel) return new Response("Bad file path", { status: 400 });
  if (src !== "auto" && src !== "manual") return new Response("Bad source", { status: 400 });
  if (key && !KEY_VAL_RE.test(key)) return new Response("That isn’t a key", { status: 400 });
  if (!(await env.MAIN.head(FILES + rel))) return new Response("Not found", { status: 404 });

  const dir = rel.split("/").slice(0, -1).join("/");
  const name = rel.split("/").pop();
  const map = await mainKeys(env, dir);
  const v = { ...(map[name] || {}) };

  if (key) v[src] = key;
  else delete v[src];
  v.at = Date.now();

  if (v.auto || v.manual) map[name] = v;
  else delete map[name];

  await saveKeys(env, dir, map);
  return jsonResponse({ ok: true, key: "", keySrc: "", ...keyFields(map[name]) });
}
