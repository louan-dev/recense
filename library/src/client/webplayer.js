// Gallery's player rules, for any page that plays one sound with no native host (FEAT-19 S-web, SPEC 69; UI-12 P6).
// One home: this file. The editor bundles it into editor.html (editor/src/player.js); Gallery's gallery.js keeps its
// own copy of these lines until it adopts this file (owed: UI-12 P6 I4). Plain script: it sets
// globalThis.RecenseWebPlayer, so it can be inlined by the Worker like the other client files or bundled by esbuild.
//
//   const p = RecenseWebPlayer.create({ doc, nav })   // doc/nav default to document/navigator
//   p.load(src, { title, artwork })   p.play()   p.pause()   p.toggle()   p.seek(t)   p.setRate(r)
//   p.setLoop(a, b)   (b <= a clears A–B)   p.setTrackLoop(on)   p.close()   p.el   p.on('time'|'state'|'error', fn)
//
// The rules (each is Gallery's, gallery.js buildMedia):
// - speed changes tempo, never pitch; play at the end starts the track over (notes 42);
// - a playback session, not ambient sound: goes on with the browser left or the phone locked (notes 27);
// - the Lock Screen / Control Center shows the file's own title and cover, Play, Pause and a scrubber that seeks;
//   position, length and speed kept current (rate never 0, length only when known); no ±10 s;
//   the second line says which loop is on; dropped when the sound is closed.
(function () {
  "use strict";
  var clamp = function (v, a, b) { return Math.min(b, Math.max(a, v)); };
  var dur = function (s) {
    s = Math.max(0, Math.floor(Number(s) || 0));
    var m = Math.floor(s / 60), r = s % 60;
    return m + ":" + (r < 10 ? "0" : "") + r;
  };

  function create(opts) {
    opts = opts || {};
    var doc = opts.doc || (typeof document !== "undefined" ? document : null);
    var nav = opts.nav || (typeof navigator !== "undefined" ? navigator : null);
    var Meta = opts.MediaMetadata || (typeof MediaMetadata !== "undefined" ? MediaMetadata : null);
    var ms = nav && nav.mediaSession;
    var el = doc.createElement("audio");
    var info = { title: "", artwork: "" };
    var loop = { track: false, a: null, b: null };
    var subs = { time: [], state: [], error: [] };
    var emit = function (k, v) { subs[k].forEach(function (f) { try { f(v); } catch (x) {} }); };
    var owns = false;

    el.preload = "metadata";
    el.preservesPitch = true;

    var abOn = function () { return loop.a != null && loop.b != null && loop.b > loop.a; };

    var nowPos = function () {
      if (!ms || !owns) return;
      try {
        ms.playbackState = el.paused ? "paused" : "playing";
        var d = el.duration;
        if (!isFinite(d) || d <= 0) return;
        ms.setPositionState({ duration: d, playbackRate: el.playbackRate || 1, position: clamp(el.currentTime || 0, 0, d) });
      } catch (x) {}
    };
    var nowAct = function (a, h) { try { ms.setActionHandler(a, h); } catch (x) {} };
    var nowLoop = function () { return abOn() ? "A–B loop · " + dur(loop.a) + " – " + dur(loop.b) : loop.track ? "Loop" : ""; };
    var nowMeta = function () {
      if (!ms || !owns || !Meta) return;
      var m = { title: info.title || "Recense", artist: nowLoop(), album: "" };
      try { if (info.artwork) m.artwork = [{ src: new URL(info.artwork, doc.baseURI || undefined).href }]; } catch (x) {}
      try { ms.metadata = new Meta(m); } catch (x) {}
    };
    var nowClaim = function () {
      try { if (nav.audioSession && nav.audioSession.type !== "playback") nav.audioSession.type = "playback"; } catch (x) {}
      if (!ms) return;
      owns = true;
      nowMeta();
      nowAct("play", function () { play(); });
      nowAct("pause", function () { el.pause(); });
      nowAct("seekto", function (e) {
        if (!e || typeof e.seekTime !== "number") return;
        if (e.fastSeek && el.fastSeek) el.fastSeek(e.seekTime); else el.currentTime = e.seekTime;
        nowPos();
      });
      nowAct("seekbackward", null);
      nowAct("seekforward", null);
      nowAct("previoustrack", function () { el.currentTime = abOn() ? loop.a : 0; nowPos(); });
      nowAct("nexttrack", null);
      nowPos();
    };
    var nowDrop = function () {
      if (!ms || !owns) return;
      owns = false;
      try { ms.metadata = null; ms.playbackState = "none"; ms.setPositionState(); } catch (x) {}
      ["play", "pause", "seekto", "previoustrack", "nexttrack"].forEach(function (a) { nowAct(a, null); });
    };

    el.addEventListener("play", function () { nowClaim(); emit("state", "playing"); });
    el.addEventListener("pause", function () { nowPos(); emit("state", "paused"); });
    ["ratechange", "durationchange", "seeked"].forEach(function (ev) { el.addEventListener(ev, nowPos); });
    el.addEventListener("timeupdate", function () {
      if (abOn() && el.currentTime >= loop.b) el.currentTime = loop.a;
      nowPos();
      emit("time", el.currentTime);
    });
    el.addEventListener("ended", function () {
      if (abOn()) { el.currentTime = loop.a; el.play().catch(function () {}); }
    });
    el.addEventListener("error", function () { emit("error", "load"); });

    function play() {
      if (el.ended || (el.duration && el.currentTime >= el.duration - 0.05)) el.currentTime = abOn() ? loop.a : 0;
      return el.play().catch(function (e) { emit("error", (e && e.name) || "play"); });
    }

    return {
      el: el,
      on: function (k, f) { if (subs[k]) subs[k].push(f); },
      load: function (src, o) {
        o = o || {};
        info = { title: String(o.title || ""), artwork: String(o.artwork || "") };
        loop = { track: false, a: null, b: null };
        el.loop = false;
        el.src = src;
        if (owns) nowMeta();
      },
      play: play,
      pause: function () { el.pause(); },
      toggle: function () { return el.paused ? play() : el.pause(); },
      seek: function (t) {
        var d = el.duration;
        el.currentTime = isFinite(d) && d > 0 ? clamp(Number(t) || 0, 0, d) : Math.max(0, Number(t) || 0);
        nowPos();
        emit("time", el.currentTime);
      },
      setRate: function (r) { el.playbackRate = clamp(Number(r) || 1, 0.25, 4); el.preservesPitch = true; nowPos(); },
      setLoop: function (a, b) {
        a = Number(a); b = Number(b);
        loop.a = isFinite(a) && isFinite(b) && b > a ? Math.max(0, a) : null;
        loop.b = loop.a == null ? null : b;
        nowMeta();
      },
      setTrackLoop: function (on) { loop.track = !!on; el.loop = loop.track; nowMeta(); },
      state: function () {
        return { src: el.currentSrc || el.src || "", playing: !el.paused, currentTime: el.currentTime || 0,
          duration: isFinite(el.duration) ? el.duration : 0, rate: el.playbackRate, loopA: loop.a, loopB: loop.b, trackLoop: loop.track };
      },
      close: function () { el.pause(); nowDrop(); el.removeAttribute("src"); try { el.load(); } catch (x) {} }
    };
  }

  globalThis.RecenseWebPlayer = { create: create };
})();
