// Gallery: public links and the private Main library, on one Cloudflare Worker.
//
//   /, /s/<id>, /f/…, /d/…, /api/gallery   the public side, from the PUBLIC bucket
//   /main, /main/f/…                        the owner's library, from the MAIN bucket
//   /main/api/…                             every write: uploads, links, deletes, invites
//   /m/<token>/…                            an invited person's view of one Main folder (invite.js)
//   /main/dav/…, /main/dav-tmp/…, /main/dav-archive/…, /main/nc/…, /main/nc-tmp/…, /main/nc-archive/…, /dav/notability/…
//                                          WebDAV: Main, tmp and the archive (Access; nc = chunked uploads), Notability's backup (Basic) (dav.js)
//   /main/archive, /main/archive/f/…        the archive shelf: Main's page over gallery-archive, read-only (archive.js)
//   /main/api/fp/<root>/…                   the File Provider's feed: items, changes, content (fp.js)
//   /t/<id>/<name>                          a temporary download from the self-deleting TMP bucket (tmp.js)
//   /i/attachments/<ext>/<h2>/<sha256>.<ext> an Obsidian note's image, public, from NOTES_IMAGES (images.js)
//
// Everything under /main sits behind Cloudflare Access, and the Worker checks the owner itself
// (access.js). Anyone else gets the same 404 as a link that doesn't exist.

import { page, notice, jsonResponse, esc, OWNER, cleanPath } from "./common.js";
import { isOwner, sameSite, signedInAs } from "./access.js";
import { dav, notabilityAuth, ownerMount, NOTABILITY_DAV } from "./dav.js";
import { keyWorklet } from "./player-key.js";
import { uploadPage } from "./page/upload.js";
import { cleanup, sweepFolders, linkTranscript, linkTranscriptChanges, linkTranscriptWrite, linkApi, deleteFromLink, commentApi, upload, gallery, galleryApi, file, folderFile } from "./public.js";
import { mainFolder, mainFile, mainUpload, mainDelete, mainRename, mainFolders, mainNewFolder, mainMove, mainCover, mainCoverDelete, mainKey, orderSweep, artSweep } from "./main.js";
import { inviteApi, participantRoute } from "./invite.js";
import { sharesApi, sharedPage, activitySweep } from "./shared.js";
import { transcriptChanges, transcriptResponse, transcriptSave, transcriptRun, rateSweep } from "./transcript.js";
import { tmpPut, tmpGet, tmpSweep } from "./tmp.js";
import { fp } from "./fp.js";
import { archive } from "./archive.js";
import { noteImage, noteImageUpload } from "./images.js";
import { aiRoute, indexRun } from "./ai.js";
import { inviteIcs, warmCalendar } from "./calendar.js";

export default {
  async fetch(req, env, ctx) {
    const url = new URL(req.url);
    const path = url.pathname;
    const method = req.method;
    let m;

    if (path === "/main" || path === "/main/" || path.startsWith("/main/")) {
      if (!(await isOwner(req, env))) {
        // Access guards /main/…; a bare /main (no token yet) goes there, so it gets the sign-in too
        if (path === "/main" && method === "GET") return Response.redirect(url.origin + "/main/" + url.search, 302);
        const who = method === "GET" && !path.startsWith("/main/api/") ? await signedInAs(req, env) : null;
        return who ? wrongAccount(who) : notice("Link not found", 404);
      }
      return mainRoute(req, env, ctx, url, path, method);
    }

    if (path.startsWith("/m/")) return participantRoute(req, env, ctx, url, path);

    if (path === "/dav/notability" || path.startsWith("/dav/notability/")) {
      return (await notabilityAuth(req, env)) || dav(req, env, url, NOTABILITY_DAV);
    }

    if (path === "/api/transcript" && method === "PUT") return linkTranscriptWrite(req, env, url, false);
    if (path === "/api/transcript/run" && method === "POST") return linkTranscriptWrite(req, env, url, true);
    if (method !== "GET" && method !== "HEAD") return new Response("Method not allowed", { status: 405 });

    if (path.startsWith("/i/")) return noteImage(req, env, path.slice(3));
    if (path === "/") return page(landingPage());
    if (path === "/api/gallery") return galleryApi(env, url);
    if (path === "/api/transcript/changes") return linkTranscriptChanges(env, url);
    if (path === "/api/transcript") return linkTranscript(env, url);
    if (path === "/player/key.js") return keyWorklet();
    if ((m = path.match(/^\/s\/([A-Za-z0-9]+)$/))) return gallery(env, m[1]);
    if ((m = path.match(/^\/f\/([A-Za-z0-9]+)\/(\d{3})$/))) return file(req, env, ctx, url, m[1], m[2]);
    if ((m = path.match(/^\/d\/([A-Za-z0-9]+)\/[A-Za-z0-9]+\/(.+)$/))) return folderFile(req, env, url, m[1], m[2]);
    if ((m = path.match(/^\/t\/([0-9a-f]{32})\/([^/]+)$/))) return tmpGet(req, env, ctx, url, m[1], m[2]);
    if ((m = path.match(/^\/c\/([0-9a-f]{32})\.ics$/))) return inviteIcs(env, m[1]);   // a calendar invite the assistant made (calendar.js)

    return notice("Link not found", 404);
  },

    async scheduled(event, env, ctx) {
    // every minute: up to ~45 s of the assistant's indexing steps (ai.js), nothing else
    if (event.cron === "* * * * *") { if (env.AI && env.VECTORS) ctx.waitUntil(indexRun(env).catch(() => {})); return; }
    ctx.waitUntil(Promise.all([cleanup(env), sweepFolders(env), orderSweep(env), artSweep(env), rateSweep(env), tmpSweep(env), activitySweep(env),
      warmCalendar(env).catch(() => {})]));   // reads what changed in the iCloud calendar backup
  },
};

// Only the owner gets here.
async function mainRoute(req, env, ctx, url, path, method) {
  const read = method === "GET" || method === "HEAD";

  // WebDAV clients send no Origin; their writes (PUT, MKCOL, MOVE…) can't be sent cross-site without a CORS preflight, which gets no CORS answer
  const davMount = ownerMount(path);
  if (davMount) return dav(req, env, url, davMount);

  // the archive shelf: Main's page and player over gallery-archive, read-only (archive.js)
  if (path === "/main/archive" || path.startsWith("/main/archive/")) return archive(req, env, ctx, url, path);

  // the File Provider's read-only feed: a native client sends no Origin (fp.js)
  if (path.startsWith("/main/api/fp/")) return fp(req, env, url, path);

  if (path.startsWith("/main/api/")) {
    if (path === "/main/api/whoami" && read) return jsonResponse({ ok: true });
    if (!sameSite(req, url)) return new Response("Forbidden", { status: 403 });
    if (path.startsWith("/main/api/ai/")) return aiRoute(req, env, ctx, url, path, method);

    if (path === "/main/api/file" && method === "PUT") return mainUpload(req, env, url);
    if (path === "/main/api/img" && method === "PUT") return noteImageUpload(req, env, url);
    if (path === "/main/api/file" && method === "DELETE") return mainDelete(env, url);
    if (path === "/main/api/rename" && method === "POST") return mainRename(req, env);
    if (path === "/main/api/folders" && read) return mainFolders(env, url);
    if (path === "/main/api/folder" && method === "POST") return mainNewFolder(req, env);
    if (path === "/main/api/move" && method === "POST") return mainMove(req, env);
    if (path === "/main/api/cover" && method === "PUT") return mainCover(req, env, url);
    if (path === "/main/api/cover" && method === "DELETE") return mainCoverDelete(env, url);
    if (path === "/main/api/key" && method === "PUT") return mainKey(req, env);
    if (path === "/main/api/tmp" && method === "PUT") return tmpPut(req, env, url);
    if (path === "/main/api/transcript/changes" && read) {
      const rel = cleanPath(url.searchParams.get("path") || "");
      return rel ? transcriptChanges(env, rel) : new Response("Bad file path", { status: 400 });
    }
    if (path === "/main/api/transcript" && read) {
      const rel = cleanPath(url.searchParams.get("path") || "");
      return rel ? transcriptResponse(env, rel, url.searchParams.get("f")) : new Response("Bad file path", { status: 400 });
    }
    if ((path === "/main/api/transcript" && method === "PUT") || (path === "/main/api/transcript/run" && method === "POST")) {
      const rel = cleanPath(url.searchParams.get("path") || "");
      if (!rel) return new Response("Bad file path", { status: 400 });
      return method === "PUT" ? transcriptSave(req, env, rel, "main") : transcriptRun(req, env, rel, "main");
    }
    if (path === "/main/api/caption" && method === "PUT") return commentApi(req, env);
    if (path === "/main/api/invites" || path.startsWith("/main/api/invites/")) return inviteApi(req, env, url, path);
    if (path === "/main/api/activity" || path === "/main/api/shares" || path.startsWith("/main/api/shares/")) return sharesApi(req, env, url, path);
    if (path === "/main/api/link" && method === "POST") return linkApi(req, env, url);
    if (path === "/main/api/link" && method === "DELETE") return deleteFromLink(env, url);
    if (path === "/main/api/upload" && (method === "PUT" || method === "POST")) return upload(req, env, url);

    return new Response("Not found", { status: 404 });
  }

  if (!read) return new Response("Method not allowed", { status: 405 });
  if (path === "/main/share" && read) return page(uploadPage());
  if (path === "/main/shared" && read) return sharedPage(url);
  if (path === "/main" || path === "/main/") return mainFolder(env, url);
  if (path.startsWith("/main/f/")) return mainFile(req, env, ctx, url, path.slice("/main/f/".length));

  return notice("Link not found", 404);
}

// Signed in to Access, but not as the owner: say who, and offer a clean sign-out to try again.
function wrongAccount(email) {
  return page(`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta name="darkreader-lock">
<meta name="color-scheme" content="dark">
<meta name="robots" content="noindex">
<title>Chau's Gallery</title>
<style>
html{background:#1c1c1e}
body{margin:0;color:#fff;font:17px/1.35 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;display:grid;place-items:center;min-height:100vh;text-align:center;padding:24px;box-sizing:border-box}
p{color:#98989d}
a{color:#0a84ff;text-decoration:none}
</style>
</head>
<body>
<main>
<h1 style="font-size:24px">This account can’t open Main</h1>
<p>You’re signed in as <b style="color:#fff">${esc(email)}</b>.</p>
<p><a href="/cdn-cgi/access/logout" target="_blank" rel="noopener">1. Sign out</a></p>
<p><a href="/main/">2. Sign in again as the owner</a></p>
<p style="font-size:13px">After signing out, come back here and tap 2 (going to the Cloudflare page on its own shows “App Launcher is not configured”).</p>
</main>
</body>
</html>`, 403);
}

function landingPage() {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta name="darkreader-lock">
<meta name="theme-color" content="#1c1c1e">
<meta name="color-scheme" content="dark">
<meta name="robots" content="noindex">
<title>Chau's Gallery</title>
<style>
:root{--bg:#1c1c1e;--panel:#2c2c2e;--mut:#98989d;--blue:#0a84ff;--r:10px}
html{background:var(--bg)}
body{margin:0;color:#fff;font:15px/1.25 -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",sans-serif;-webkit-font-smoothing:antialiased}
.pill{background:linear-gradient(180deg,rgba(255,255,255,.28),rgba(255,255,255,.02)),rgba(10,132,255,.78);color:#fff;font-size:17px;font-weight:600;padding:6px 16px;border-radius:99px;text-decoration:none;display:inline-block}
</style>
</head>
<body>
<main class="landing" style="display:grid; place-items:center; min-height:100vh; text-align:center; padding:24px;">
  <div>
    <h1 style="font-size:28px; font-weight:600; margin-bottom:8px;">Chau's Gallery</h1>
    <p style="color:var(--mut); margin-bottom:24px;">Explore the main collection.</p>
    <a href="/main/" class="pill">Sign In</a>
  </div>
</main>
</body>
</html>`;
}