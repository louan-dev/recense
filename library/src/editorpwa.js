// Derived from Spec: UI-12 (S1). The Draftpad editor as an installable offline page, owner-only under /main/editor/.
// Files are copied from editor/dist/pwa/ (`cd editor && npm run build`, then copy; see library/README.md).
import indexHtml from "./client/editorpwa/index.html";
import swJs from "./client/editorpwa/sw.js";
import manifest from "./client/editorpwa/manifest.webmanifest";
import icon from "./client/editorpwa/icon.svg";

const FILES = {
  "": [indexHtml, "text/html; charset=utf-8"],
  "sw.js": [swJs, "text/javascript; charset=utf-8"],
  "manifest.webmanifest": [manifest, "application/manifest+json"],
  "icon.svg": [icon, "image/svg+xml"],
};

export function editorPwa(req, path) {
  if (req.method !== "GET" && req.method !== "HEAD") return new Response("Method not allowed", { status: 405 });
  const name = path.slice("/main/editor/".length);
  const hit = FILES[name];
  if (!hit) return new Response("Not found", { status: 404 });
  // no-store: the service worker, not the HTTP cache, decides what is kept; an Access sign-in page is never mistaken for the editor
  return new Response(req.method === "HEAD" ? null : hit[0], { headers: { "content-type": hit[1], "cache-control": "no-store", "service-worker-allowed": "/main/editor/" } });
}
