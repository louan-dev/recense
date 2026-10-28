// The owner's route strategy for the prosogram, inlined by page/gallery.js ONLY when the page is the owner's
// (`live.main`). It is a separate file for one reason: it names an owner-only route, and a participant's page must not
// contain that string — routes.test.mjs "invites" asserts the rendered HTML has no such path, which is a real leak
// guard, not a nuisance. Keeping the literal here means the shared core (prosogram-mount.js) stays safe on every page
// and the prosogram works on share links too.
//
// The player sets a file's src to "/main/f/" + urlPath(path) (main.js:240), where urlPath is per-segment
// encodeURIComponent joined by "/" (common.js:199). Inverting that gives the path the transcript API wants, without
// reaching into gallery.js's closure — `items[cur]` is not reachable from out here.
(() => {
  "use strict";
  const host = globalThis.ProsogramHost;
  if (!host || typeof host.use !== "function") return;

  const PREFIX = "/main/f/";

  host.use((pathname, decodeSegments) => {
    if (!pathname.startsWith(PREFIX)) return null;
    const path = decodeSegments(pathname.slice(PREFIX.length));
    if (!path) return null;
    return {
      key: "main:" + path,
      url: "/main/api/transcript?path=" + encodeURIComponent(path),
    };
  });
})();
