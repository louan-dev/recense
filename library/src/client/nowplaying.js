// Derived from Spec: FEAT-19 P4 · the Lock Screen half of Recense's player, for a page that plays a plain
// <audio>/<video>: the editor's embedded recordings (editor/src/embeds.js bundles this file). The same rules as
// Gallery's player (SPEC 69, gallery.js "lock screen / Control Center Now Playing"):
//   - a playback session (navigator.audioSession "playback"): it goes on with the browser left or the phone locked;
//   - the file's title and cover; play, pause, seekto; setPositionState with a known length, the place clamped to it,
//     and a speed that is never 0, so the Lock Screen draws a scrubber that works;
//   - no ±10 s (the scrubber does that); ⏮ / ⏭ only where there is a queue;
//   - one element at a time: the last one to start has the Lock Screen, and an earlier one is paused.
// Gallery's own player keeps its copy (it is served as one script); this module is the one for everything else.

let current = null; // the element that has the Lock Screen

/**
 * Gives `el` the Lock Screen while it plays.
 * @param {HTMLMediaElement} el
 * @param {{title?: string, artwork?: string, previous?: () => void, next?: () => void, nav?: Navigator, base?: string}} opts
 * @returns {{drop: () => void, owns: () => boolean}}
 */
export function nowPlaying(el, opts = {}) {
  const nav = opts.nav ?? (typeof navigator !== "undefined" ? navigator : null);
  const ms = nav && nav.mediaSession;

  const act = (a, h) => {
    try {
      ms.setActionHandler(a, h);
    } catch (x) {}
  };

  const pos = () => {
    if (!ms || current !== el) return;
    try {
      ms.playbackState = el.paused ? "paused" : "playing";
      const d = el.duration;
      if (!isFinite(d) || d <= 0) return;
      ms.setPositionState({ duration: d, playbackRate: el.playbackRate || 1, position: Math.min(Math.max(el.currentTime || 0, 0), d) });
    } catch (x) {}
  };

  const claim = () => {
    try {
      if (nav && nav.audioSession && nav.audioSession.type !== "playback") nav.audioSession.type = "playback";
    } catch (x) {}
    if (current && current !== el && !current.paused) current.pause();
    current = el;
    if (!ms) return;
    const meta = { title: String(opts.title || "").trim() || "Recense", artist: "", album: "" };
    try {
      if (opts.artwork) meta.artwork = [{ src: new URL(opts.artwork, opts.base ?? (typeof location !== "undefined" ? location.href : undefined)).href }];
    } catch (x) {}
    try {
      ms.metadata = new MediaMetadata(meta);
    } catch (x) {}
    act("play", () => el.play().catch(() => {}));
    act("pause", () => el.pause());
    act("seekto", (e) => {
      if (!e || typeof e.seekTime !== "number") return;
      if (e.fastSeek && el.fastSeek) el.fastSeek(e.seekTime);
      else el.currentTime = e.seekTime;
      pos();
    });
    act("seekbackward", null);
    act("seekforward", null);
    act("previoustrack", typeof opts.previous === "function" ? opts.previous : null);
    act("nexttrack", typeof opts.next === "function" ? opts.next : null);
    pos();
  };

  const drop = () => {
    el.removeEventListener("play", claim);
    POS_EVENTS.forEach((ev) => el.removeEventListener(ev, pos));
    if (current !== el) return;
    current = null;
    if (!ms) return;
    try {
      ms.metadata = null;
      ms.playbackState = "none";
      ms.setPositionState();
    } catch (x) {}
    ["play", "pause", "seekto", "previoustrack", "nexttrack"].forEach((a) => act(a, null));
  };

  el.addEventListener("play", claim);
  POS_EVENTS.forEach((ev) => el.addEventListener(ev, pos));
  return { drop, owns: () => current === el };
}

const POS_EVENTS = ["pause", "ratechange", "durationchange", "seeked", "timeupdate"];
