// sync Worker: standards-based sync foundation (docs/specs/sync.md). Phase 0: CalDAV only.
//   /.well-known/caldav → /dav/      /dav/…  CalDAV (caldav.js)      /health  liveness for Sill / monitors
import { caldav } from "./caldav.js";

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const p = url.pathname;
    if (p === "/health") return new Response("ok", { headers: { "Cache-Control": "no-store" } });
    if (p === "/.well-known/caldav" || p === "/.well-known/caldav/") return new Response(null, { status: 301, headers: { Location: "/dav/" } });
    if (p === "/" || p === "/dav" || p.startsWith("/dav/")) return caldav(req, env, url);
    return new Response("Not found", { status: 404 });
  },
};
