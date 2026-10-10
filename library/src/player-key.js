// GET /player/key.js   the player's Key processor, an AudioWorklet module.
//
// Static code with no access to any file: the player loads it the first time Key leaves 0.
// It is served from here (not a blob: URL) because same-origin is the one way every target
// browser, Safari included, reliably accepts an AudioWorklet module.

import source from "./client/player-key.js";
import { VERSION } from "./common.js";

export function keyWorklet() {
  return new Response(source, {
    headers: {
      "content-type": "text/javascript; charset=utf-8",
      "cache-control": "public, max-age=86400",
      "x-content-type-options": "nosniff",
      "x-version": VERSION,
    },
  });
}
