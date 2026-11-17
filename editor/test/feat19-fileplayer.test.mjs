// Derived from Spec: FEAT-19 (P4) · "Play a file…" in a browser: a real media element, an object URL that is let go,
// the shared Now Playing module bound and unbound, and no item in the app (its native bridge owns the Lock Screen).
import test from 'node:test';
import assert from 'node:assert/strict';
import { canPlayFiles, kindOf, createFilePlayer, PLAYABLE } from '../src/fileplayer.js';

class Node_ extends EventTarget {
  constructor(tag) { super(); this.tagName = tag.toUpperCase(); this.children = []; this.attrs = {}; this.hidden = false; this.parent = null; }
  append(...c) { for (const n of c) { n.parent = this; this.children.push(n); } }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter(n => n !== this); this.parent = null; }
  setAttribute(k, v) { this.attrs[k] = v; }
  removeAttribute(k) { delete this.attrs[k]; if (k === 'src') this.src = ''; }
  click() { this.dispatchEvent(new Event('click')); }
  play() { this.paused = false; this.played = (this.played || 0) + 1; return Promise.resolve(); }
  pause() { this.paused = true; }
}
const fakeDoc = () => { const made = []; return { made, createElement: t => { const n = new Node_(t); made.push(n); return n; } }; };
const fakeUrls = () => { const live = new Set(); let i = 0; return { live, createObjectURL: () => { const u = `blob:${++i}`; live.add(u); return u; }, revokeObjectURL: u => live.delete(u) }; };
const fakeNP = () => { const np = { bound: [], unbound: 0, bind(el, opts) { np.bound.push({ el, opts }); return () => np.unbound++; } }; return np; };

test('P4: the item shows in a browser and hides in the app (native audio bridge)', () => {
  assert.equal(canPlayFiles({}), true);
  assert.equal(canPlayFiles({ webkit: { messageHandlers: { audio: {} } } }), false);
  assert.match(PLAYABLE, /audio\/\*/);
  assert.match(PLAYABLE, /video\/\*/);
});

test('P4: a video file gets <video>, a sound file or unknown type gets <audio>', () => {
  assert.equal(kindOf({ type: 'video/mp4', name: 'a.mp4' }), 'video');
  assert.equal(kindOf({ type: 'audio/mpeg', name: 'a.mp3' }), 'audio');
  assert.equal(kindOf({ type: '', name: 'lecture.MOV' }), 'video');
  assert.equal(kindOf({ type: '', name: 'lecture.m4a' }), 'audio');
});

test('P4: play binds Now Playing to a real element with an object URL; close lets both go', () => {
  const doc = fakeDoc(); const urls = fakeUrls(); const np = fakeNP();
  const p = createFilePlayer({ doc, urls, nowPlaying: np });
  assert.equal(p.panel.hidden, true);
  const el = p.play({ type: 'audio/mpeg', name: 'Contracts week 3.mp3' });
  assert.equal(el.tagName, 'AUDIO');
  assert.equal(el.controls, true);
  assert.equal(el.attrs.playsinline, '');
  assert.ok(urls.live.has(el.src));
  assert.equal(el.played, 1);
  assert.equal(np.bound.length, 1);
  assert.equal(np.bound[0].el, el);
  assert.equal(np.bound[0].opts.title, 'Contracts week 3.mp3');
  assert.equal(p.panel.hidden, false);
  assert.ok(p.panel.children.includes(el));
  p.stop();
  assert.equal(np.unbound, 1);
  assert.equal(urls.live.size, 0, 'the object URL is revoked');
  assert.equal(el.paused, true);
  assert.equal(p.panel.children.includes(el), false);
  assert.equal(p.panel.hidden, true);
});

test('P4: a second file replaces the first (one player, one Lock Screen owner)', () => {
  const doc = fakeDoc(); const urls = fakeUrls(); const np = fakeNP();
  const p = createFilePlayer({ doc, urls, nowPlaying: np });
  const a = p.play({ type: 'audio/mpeg', name: 'a.mp3' });
  const b = p.play({ type: 'video/mp4', name: 'b.mp4' });
  assert.equal(np.unbound, 1);
  assert.equal(urls.live.size, 1);
  assert.equal(a.paused, true);
  assert.equal(b.tagName, 'VIDEO');
  assert.equal(p.element, b);
});

test('P4: pick opens a file input for sound and video; the chosen file plays', () => {
  const doc = fakeDoc(); const np = fakeNP();
  const p = createFilePlayer({ doc, urls: fakeUrls(), nowPlaying: np });
  let clicked = null;
  const orig = Node_.prototype.click;
  Node_.prototype.click = function () { clicked = this; };
  try { p.pick(); } finally { Node_.prototype.click = orig; }
  assert.equal(clicked.tagName, 'INPUT');
  assert.equal(clicked.type, 'file');
  assert.equal(clicked.accept, PLAYABLE);
  clicked.files = [{ type: 'audio/mp4', name: 'x.m4a' }];
  clicked.dispatchEvent(new Event('change'));
  assert.equal(np.bound.length, 1);
});

test('P4: the shared module is bundled (one source with Gallery)', async () => {
  assert.equal(typeof globalThis.RecenseNowPlaying?.bind, 'function');
});
