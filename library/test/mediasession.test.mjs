// Derived from Spec: FEAT-19 (P4) · the shared Lock Screen wiring (src/client/mediasession.js), run in node with
// a fake element, Media Session and document. Run with `npm test`.

import { readFileSync } from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const code = readFileSync(new URL("../src/client/mediasession.js", import.meta.url), "utf8");

let passed = 0;
const test = async (name, fn) => {
  await fn();
  passed++;
  console.log("ok   " + name);
};

class FakeEl extends EventTarget {
  constructor(tag = "audio") {
    super();
    this.tagName = tag.toUpperCase();
    this.paused = true;
    this.ended = false;
    this.currentTime = 0;
    this.duration = NaN;
    this.playbackRate = 1;
    this.isConnected = true;
  }
  fire(t) { this.dispatchEvent(new Event(t)); }
  play() { this.paused = false; this.fire("play"); return Promise.resolve(); }
  pause() { if (this.paused) return; this.paused = true; this.fire("pause"); }
}

const world = () => {
  const h = {};
  const pos = [];
  const ms = {
    metadata: null,
    playbackState: "none",
    setActionHandler: (a, f) => { if (f) h[a] = f; else delete h[a]; },
    setPositionState: (s) => pos.push(s || null),
  };
  const doc = new EventTarget();
  doc.hidden = false;
  const nav = { mediaSession: ms, audioSession: { type: "auto" } };
  class MediaMetadata { constructor(m) { Object.assign(this, m); } }
  const ctx = vm.createContext({ navigator: nav, document: doc, MediaMetadata, Date, Math, URL, location: { href: "https://recense.local/" } });
  vm.runInContext(code, ctx);
  const hide = (on) => { doc.hidden = on; doc.dispatchEvent(new Event("visibilitychange")); };
  return { NP: ctx.RecenseNowPlaying, ms, h, pos, nav, hide };
};

await test("play claims the Lock Screen: title, artwork, playback session, play/pause/seekto, no ±skip", async () => {
  const w = world();
  const el = new FakeEl();
  w.NP.bind(el, { title: "Lecture 3.m4a", artwork: "cover.jpg" });
  assert.equal(w.ms.metadata, null, "nothing shown before play");
  await el.play();
  assert.equal(w.ms.metadata.title, "Lecture 3");
  assert.equal(w.ms.metadata.artwork[0].src, "https://recense.local/cover.jpg");
  assert.equal(w.nav.audioSession.type, "playback");
  assert.equal(w.ms.playbackState, "playing");
  assert.deepEqual(Object.keys(w.h).sort(), ["pause", "play", "seekto"]);
});

await test("previous / next only when given", async () => {
  const w = world();
  const el = new FakeEl();
  let n = 0;
  w.NP.bind(el, { title: "a", onNext: () => n++, onPrev: () => n-- });
  await el.play();
  assert.deepEqual(Object.keys(w.h).sort(), ["nexttrack", "pause", "play", "previoustrack", "seekto"]);
  w.h.nexttrack({});
  assert.equal(n, 1);
});

await test("the scrubber: setPositionState carries length, place and speed; seekto moves the element", async () => {
  const w = world();
  const el = new FakeEl();
  w.NP.bind(el, { title: "a" });
  await el.play();
  el.duration = 120;
  el.currentTime = 30;
  el.fire("timeupdate");
  assert.deepEqual({ ...w.pos.at(-1) }, { duration: 120, playbackRate: 1, position: 30 });
  w.h.seekto({ seekTime: 90 });
  assert.equal(el.currentTime, 90);
  assert.equal(w.pos.at(-1).position, 90);
  el.currentTime = 500; // past the end (a stale event) is clamped
  el.fire("seeked");
  assert.equal(w.pos.at(-1).position, 120);
  el.pause();
  assert.equal(w.ms.playbackState, "paused");
});

await test("unknown length: no position state (no empty 0:00 bar)", async () => {
  const w = world();
  const el = new FakeEl();
  w.NP.bind(el, { title: "a" });
  await el.play();
  el.fire("timeupdate");
  assert.equal(w.pos.filter(Boolean).length, 0);
});

await test("unbind drops what it showed", async () => {
  const w = world();
  const el = new FakeEl();
  const off = w.NP.bind(el, { title: "a" });
  await el.play();
  off();
  assert.equal(w.ms.metadata, null);
  assert.equal(w.ms.playbackState, "none");
  assert.deepEqual(Object.keys(w.h), []);
});

await test("a video the system pauses on hide plays on, once per hide; the Lock Screen's pause holds", async () => {
  const w = world();
  const el = new FakeEl("video");
  w.NP.bind(el, { title: "v" });
  await el.play();
  w.hide(true);
  el.pause(); // the system's
  assert.equal(el.paused, false, "asked back");
  el.pause(); // a second system pause in the same hide is left alone
  assert.equal(el.paused, true);
  w.hide(false);
  await el.play();
  el.pause(); // just before the hide (≤500 ms)
  w.hide(true);
  assert.equal(el.paused, false, "a pause just before hide is the system's too");
  w.h.pause({}); // the person's, from the Lock Screen
  assert.equal(el.paused, true);
  w.hide(false);
  w.hide(true);
  assert.equal(el.paused, true, "the person's pause holds through later hides");
});

await test("an audio element is never asked back (only video is paused by the system)", async () => {
  const w = world();
  const el = new FakeEl("audio");
  w.NP.bind(el, { title: "a" });
  await el.play();
  w.hide(true);
  el.pause();
  assert.equal(el.paused, true);
});

console.log(passed + " passed");
