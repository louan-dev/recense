// Derived from Spec: FEAT-19 (P4) · the Lock Screen and Control Center for any page that plays a file.
//
// RecenseNowPlaying.bind(el, { title, artwork, onPrev, onNext }) → unbind()
//   el       a real <audio> or <video> element (iOS keeps a media element playing when locked; Web Audio alone stops)
//   title    the file's name (its extension is dropped); artwork: an image URL, relative to the page
//   onPrev / onNext   ⏮ / ⏭ when there is a queue; left out, iOS shows none
//
// On play it claims the Lock Screen: a playback audio session (sound with the ringer on silent and after leaving),
// the title and cover, Play, Pause and the scrubber (seekto), its length, place and speed kept current so iOS draws
// it. No ±skip: with those set, iOS trades ⏮ / ⏭ for ±10 s, and the scrubber does that job (SPEC 69).
// A video the system pauses as the page goes hidden (iOS Safari, locked or left) is asked back once per hide; a pause
// from the Lock Screen or headphones, or one while the page is seen, holds (FEAT-19 P3).
// A classic script: Gallery loads it as is, the editor's esbuild bundles the same file (one source, parity law).
globalThis.RecenseNowPlaying = (() => {
  let owner = null; // the element that has the Lock Screen now

  const bind = (el, opts = {}) => {
    const ms = navigator.mediaSession;
    const isVideo = String(el.tagName || "").toLowerCase() === "video";
    let heldByPerson = false;
    let pausedAt = 0;
    let retried = false;
    const offs = [];
    const on = (t, ev, f) => {
      t.addEventListener(ev, f);
      offs.push(() => t.removeEventListener(ev, f));
    };
    const act = (a, h) => {
      try {
        ms.setActionHandler(a, h);
      } catch (x) {}
    };

    const pos = () => {
      if (!ms || owner !== el) return;
      try {
        ms.playbackState = el.paused ? "paused" : "playing";
        const d = el.duration;
        if (!isFinite(d) || d <= 0) return;
        ms.setPositionState({ duration: d, playbackRate: el.playbackRate || 1, position: Math.min(d, Math.max(0, el.currentTime || 0)) });
      } catch (x) {}
    };

    const meta = () => {
      const title = String(opts.title || "").replace(/\.[^/.]+$/, "") || "Recense";
      const m = { title, artist: opts.artist || "", album: opts.album || "" };
      try {
        if (opts.artwork) m.artwork = [{ src: new URL(opts.artwork, location.href).href }];
      } catch (x) {}
      try {
        ms.metadata = new MediaMetadata(m);
      } catch (x) {}
    };

    const claim = () => {
      heldByPerson = false;
      try {
        if (navigator.audioSession && navigator.audioSession.type !== "playback") navigator.audioSession.type = "playback";
      } catch (x) {}
      if (!ms) return;
      owner = el;
      meta();
      act("play", () => el.play().catch(() => {}));
      act("pause", () => {
        heldByPerson = true;
        el.pause();
      });
      act("seekto", (e) => {
        if (typeof e.seekTime !== "number") return;
        if (e.fastSeek && el.fastSeek) el.fastSeek(e.seekTime);
        else el.currentTime = e.seekTime;
        pos();
      });
      act("seekbackward", null);
      act("seekforward", null);
      act("previoustrack", opts.onPrev ? () => opts.onPrev() : null);
      act("nexttrack", opts.onNext ? () => opts.onNext() : null);
      pos();
    };

    const again = () => {
      if (retried || heldByPerson || el.ended) return;
      retried = true;
      el.play().catch(() => {});
    };

    on(el, "play", claim);
    ["pause", "ratechange", "durationchange", "seeked", "timeupdate"].forEach((ev) => on(el, ev, pos));
    if (isVideo) {
      on(el, "pause", () => {
        pausedAt = Date.now();
        if (document.hidden) again();
      });
      on(document, "visibilitychange", () => {
        if (!document.hidden) return void (retried = false);
        if (el.paused && Date.now() - pausedAt < 500) again();
      });
    }

    return () => {
      offs.forEach((f) => f());
      if (!ms || owner !== el) return;
      owner = null;
      try {
        ms.metadata = null;
        ms.playbackState = "none";
        ms.setPositionState();
      } catch (x) {}
      ["play", "pause", "seekto", "previoustrack", "nexttrack"].forEach((a) => act(a, null));
    };
  };

  return { bind };
})();
