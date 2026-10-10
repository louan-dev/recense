// Gallery: public links and the private Main library, on one Cloudflare Worker.
//
//   /, /s/<id>, /f/…, /d/…, /api/gallery   the public side, from the PUBLIC bucket
//   /main, /main/f/…                        the owner's library, from the MAIN bucket
//   /main/api/…                             every write: uploads, links, deletes
//
// Everything under /main sits behind Cloudflare Access, and the Worker checks the owner itself
// (access.js). Anyone else gets the same 404 as a link that doesn't exist.

import { page, notice, jsonResponse } from "./common.js";
import { isOwner, sameSite } from "./access.js";
import { keyWorklet } from "./player-key.js";
import { uploadPage } from "./page/upload.js";
import { cleanup, sweepFolders, linkApi, deleteFromLink, upload, gallery, galleryApi, file, folderFile } from "./public.js";
import { mainFolder, mainFile, mainUpload, mainDelete } from "./main.js";

export default {
  async fetch(req, env, ctx) {
    const url = new URL(req.url);
    const path = url.pathname;
    const method = req.method;
    let m;

    if (path === "/main" || path === "/main/" || path.startsWith("/main/")) {
      if (!(await isOwner(req, env))) return notice("Link not found", 404);
      return mainRoute(req, env, ctx, url, path, method);
    }

    if (method !== "GET" && method !== "HEAD") return new Response("Method not allowed", { status: 405 });

    if (path === "/") return page(uploadPage());
    if (path === "/api/gallery") return galleryApi(env, url);
    if (path === "/player/key.js") return keyWorklet();
    if ((m = path.match(/^\/s\/([A-Za-z0-9]+)$/))) return gallery(env, m[1]);
    if ((m = path.match(/^\/f\/([A-Za-z0-9]+)\/(\d{3})$/))) return file(req, env, ctx, url, m[1], m[2]);
    if ((m = path.match(/^\/d\/([A-Za-z0-9]+)\/[A-Za-z0-9]+\/(.+)$/))) return folderFile(req, env, url, m[1], m[2]);

    return notice("Link not found", 404);
  },

  async scheduled(event, env, ctx) {
    ctx.waitUntil(Promise.all([cleanup(env), sweepFolders(env)]));
  },
};

// Only the owner gets here.
async function mainRoute(req, env, ctx, url, path, method) {
  const read = method === "GET" || method === "HEAD";

  if (path.startsWith("/main/api/")) {
    if (path === "/main/api/whoami" && read) return jsonResponse({ ok: true });
    if (!sameSite(req, url)) return new Response("Forbidden", { status: 403 });

    if (path === "/main/api/file" && method === "PUT") return mainUpload(req, env, url);
    if (path === "/main/api/file" && method === "DELETE") return mainDelete(env, url);
    if (path === "/main/api/link" && method === "POST") return linkApi(req, env, url);
    if (path === "/main/api/link" && method === "DELETE") return deleteFromLink(env, url);
    if (path === "/main/api/upload" && (method === "PUT" || method === "POST")) return upload(req, env, url);

    return new Response("Not found", { status: 404 });
  }

  if (!read) return new Response("Method not allowed", { status: 405 });
  if (path === "/main" || path === "/main/") return mainFolder(env, url);
  if (path.startsWith("/main/f/")) return mainFile(req, env, ctx, url, path.slice("/main/f/".length));

  return notice("Link not found", 404);
}
