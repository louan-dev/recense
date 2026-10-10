import css from "../client/gallery.css";
import js from "../client/gallery.js";
import { OWNER, VERSION, esc, page } from "../common.js";

// The gallery page for any list of items: a public link, or a folder of Main.
// live.title, live.heading and live.zip reframe it; nav goes above the grid.
export function galleryPage(live, nav = "") {
  const data = JSON.stringify({ ...live, version: VERSION }).replace(/</g, "\\u003c");

  const svg = (d, w = 2) =>
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="' +
    w +
    '" stroke-linecap="round" stroke-linejoin="round">' +
    d +
    "</svg>";

  const BACK = svg('<path d="M15 18l-6-6 6-6"/>', 2.8);
  const PREV = svg('<path d="M15 18l-6-6 6-6"/>');
  const NEXT = svg('<path d="M9 18l6-6-6-6"/>');
  const INFO = svg(
    '<circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/>',
    1.8
  );
  const SAVE = svg(
    '<path d="M8 17l4 4 4-4M12 12v9"/><path d="M20.88 18.09A5 5 0 0 0 18 9h-1.26A8 8 0 1 0 3 16.29"/>',
    1.8
  );

  return page(`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#1c1c1e">
<meta name="color-scheme" content="dark">
<meta name="robots" content="noindex">
<title>${esc(live.title || "Shared by " + OWNER)}</title>
<style>${css}</style>
</head>

<body>

<main>

  <div class="bar">
    <button id="sel" class="lnk">Select</button>
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
      <button id="del" class="pill" hidden>Delete</button>
      <button id="dl" class="pill">Download</button>
    </div>
    <input id="upin" type="file" multiple hidden>
  </div>

  <p id="note" class="note" role="status" hidden></p>

  ${nav}

  <div class="grid" id="grid"></div>

  <p class="foot" id="foot"></p>
</main>

<div id="lb" hidden role="dialog" aria-modal="true" aria-label="Viewer">

  <div class="top">

    <button id="back" class="back" aria-label="Back">${BACK}<span>Back</span></button>

    <div class="ttl">
      <b id="t1"></b>
      <span id="t2"></span>
    </div>

    <div class="topr" id="topr"></div>

  </div>

  <div class="stage-container">

    <div id="stage"></div>

    <button id="prev" class="nv pv" aria-label="Previous">${PREV}</button>
    <button id="next" class="nv nx" aria-label="Next">${NEXT}</button>

  </div>

  <div id="meta" hidden></div>

  <div class="bot">

    <button id="info" class="ic" aria-label="Info">${INFO}</button>

    <div id="strip"></div>

    <button id="save" class="ic" aria-label="Download">${SAVE}</button>

  </div>

</div>

<script>
const G=${data};
</script>

<script>
${js}
</script>

</body>
</html>`);
}

// ---------- gallery CSS ----------
