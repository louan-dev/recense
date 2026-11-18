// A video's still for a tile, without holding the file open (T-0148).
//
// A tile used to be <video preload=metadata src=original>: every video on the page kept an open-ended
// range request on the one connection the browser shares for this host. Firefox stops reading them once
// it has the metadata, the connection's flow-control window fills, and every later request to the host
// waits forever: a new tab sits on "Waiting for gallery…", an upload part never answers.
//
// Now: a tile's video loads only when it nears the screen, at most two at a time. Once its first frame
// is decoded it becomes the element's poster (a small JPEG) and the video lets go of the file
// (src removed, load()), so no stream stays open. Posters are kept per address, so a re-render never
// downloads again. A frame that can't be read in 20 s releases the file anyway and keeps the glyph.
//
//   videoStill(videoElement, url)   url without "#t=": the frame is taken at 0.1 s
(function () {
  "use strict";
  var MAX = 2;
  var WAIT_MS = 20000;
  var WIDE = 480; // poster width cap: a tile is never wider
  var made = new Map(); // url -> { p: poster data URL, d: seconds }
  var queue = [];
  var busy = 0;

  var release = function (v) {
    v.removeAttribute("src");
    try { v.load(); } catch (e) {}
  };

  var grab = function (v) {
    var w = v.videoWidth, h = v.videoHeight;
    if (!w || !h) return "";
    var s = Math.min(1, WIDE / w);
    var c = document.createElement("canvas");
    c.width = Math.max(1, Math.round(w * s));
    c.height = Math.max(1, Math.round(h * s));
    c.getContext("2d").drawImage(v, 0, 0, c.width, c.height);
    return c.toDataURL("image/jpeg", 0.8);
  };

  var use = function (v, m) {
    v.poster = m.p;
    if (m.d) v.dataset.dur = String(m.d);
  };

  var next = function () {
    while (busy < MAX && queue.length) start(queue.shift());
  };

  var start = function (v) {
    var url = v.dataset.still;
    if (made.has(url)) { use(v, made.get(url)); return; }
    if (!v.isConnected) return; // re-rendered away while waiting
    busy++;
    var over = false;
    var timer = 0;
    var finish = function (ok) {
      if (over) return;
      over = true;
      clearTimeout(timer);
      if (ok) {
        try {
          var p = grab(v);
          if (p) { made.set(url, { p: p, d: isFinite(v.duration) ? v.duration : 0 }); v.poster = p; }
        } catch (e) {}
      }
      release(v);
      busy--;
      next();
    };
    v.addEventListener("seeked", function () { finish(true); }, { once: true });
    v.addEventListener("loadeddata", function () {
      // at 0.1 s already (the fragment took): the frame is here; else ask for it and wait for seeked
      if (Math.abs(v.currentTime - 0.1) < 0.05) finish(true);
      else try { v.currentTime = 0.1; } catch (e) { finish(true); }
    }, { once: true });
    v.addEventListener("error", function () { finish(false); }, { once: true });
    timer = setTimeout(function () { finish(false); }, WAIT_MS);
    v.preload = "auto";
    v.src = url + "#t=0.1";
  };

  var io = "IntersectionObserver" in window
    ? new IntersectionObserver(function (es) {
        es.forEach(function (e) {
          if (!e.isIntersecting) return;
          io.unobserve(e.target);
          queue.push(e.target);
        });
        next();
      }, { rootMargin: "400px" })
    : null;

  window.videoStill = function (v, url) {
    v.muted = true;
    v.setAttribute("muted", "");
    v.setAttribute("playsinline", "");
    v.preload = "none";
    v.dataset.still = url;
    if (made.has(url)) { use(v, made.get(url)); return v; }
    if (io) io.observe(v);
    else { queue.push(v); setTimeout(next, 0); }
    return v;
  };
  window.videoStill.release = release;
})();
