// Derived from Spec: UI-12 P6 (FEAT-19 S-editor P4): one player interface, two backends; host wins; offline plays what the device holds.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createPlayer, mediaAvailability, hasNativeAudioHost, OFFLINE_LINE, isLocalHost } from '../src/player.js';
import { createAudioSidecar } from '../src/audio.js';

function hostGlobal() {
  const posts = [];
  return { posts, webkit: { messageHandlers: { audio: { postMessage: m => posts.push(m) } } }, navigator: { onLine: true } };
}

function fakeWeb() {
  const calls = [];
  const subs = {};
  const el = { paused: true };
  return {
    calls, el, subs,
    make: () => ({
      el,
      on: (k, f) => { (subs[k] ||= []).push(f); },
      load: (src, o) => calls.push(['load', src, o.title]),
      play: async () => { calls.push(['play']); el.paused = false; },
      pause: () => { calls.push(['pause']); el.paused = true; },
      seek: t => calls.push(['seek', t]),
      setRate: r => calls.push(['rate', r]),
      setLoop: (a, b) => calls.push(['loop', a, b]),
      state: () => ({ playing: !el.paused }),
      close: () => calls.push(['close'])
    })
  };
}

// Regression guard: UI-12
test('UI-12 P6: with a native host every call is a post to it, and no page player is made (host wins)', async () => {
  const g = hostGlobal();
  let made = 0;
  const p = createPlayer({ globalObj: g, makeWebPlayer: () => { made++; return null; } });
  assert.equal(p.backend, 'host');
  assert.equal(hasNativeAudioHost(g), true);
  await p.load('https://example.com/a.m4a', 'A');
  await p.play();
  p.seek(12.5);
  p.setRate(1.5);
  p.setLoop(2, 4);
  p.pause();
  assert.equal(made, 0);
  assert.deepEqual(g.posts, [
    { action: 'load', src: 'https://example.com/a.m4a', title: 'A' },
    { action: 'play' },
    { action: 'seek', time: 12.5 },
    { action: 'rate', rate: 1.5 },
    { action: 'loop', start: 2, end: 4 },
    { action: 'pause' }
  ]);
});

// Regression guard: UI-12
test('UI-12 P6: the sidecar seek with a host posts exactly what it posted before', () => {
  const g = hostGlobal();
  const sc = createAudioSidecar({ globalObj: g, cues: [{ start: 0, end: 5, text: 'a' }, { start: 5, end: 9, text: 'b' }] });
  assert.equal(sc.player.backend, 'host');
  sc.seek(6);
  assert.deepEqual(g.posts, [{ action: 'seek', time: 6 }]);
  assert.equal(sc.getActiveCueIndex(), 1);
});

// Regression guard: UI-12
test('UI-12 P6: with no host the same calls drive the page player', async () => {
  const w = fakeWeb();
  const g = { navigator: { onLine: true }, location: { href: 'http://127.0.0.1:8080/', origin: 'http://127.0.0.1:8080' } };
  const p = createPlayer({ globalObj: g, makeWebPlayer: w.make });
  assert.equal(p.backend, 'web');
  assert.equal(await p.load('blob:http://127.0.0.1:8080/x', 'Tone'), 'device');
  assert.equal(await p.play(), true);
  p.seek(1.25); p.setRate(2); p.setLoop(1, 2); p.pause();
  assert.deepEqual(w.calls, [['load', 'blob:http://127.0.0.1:8080/x', 'Tone'], ['rate', 1], ['play'], ['seek', 1.25], ['rate', 2], ['loop', 1, 2], ['pause']]);
});

// Regression guard: UI-12
test('UI-12 P6: the page player time drives the transcript highlight', async () => {
  const w = fakeWeb();
  const g = { navigator: { onLine: true }, location: { href: 'http://127.0.0.1/', origin: 'http://127.0.0.1' } };
  const p = createPlayer({ globalObj: g, makeWebPlayer: w.make });
  const sc = createAudioSidecar({ globalObj: g, player: p, cues: [{ start: 0, end: 2, text: 'a' }, { start: 2, end: 4, text: 'b' }] });
  assert.equal(sc.player, p);
  const times = [];
  const p2 = createPlayer({ globalObj: g, makeWebPlayer: w.make, onTime: t => times.push(sc.updateTime(t)) });
  await p2.load('data:audio/wav;base64,AA==');
  w.subs.time.at(-1)(3);
  assert.deepEqual(times, [1]);
});

// Regression guard: UI-12
test('UI-12 P6: offline, a recording the device does not hold is refused with one plain line, and nothing plays', async () => {
  const w = fakeWeb();
  const lines = [];
  const g = { navigator: { onLine: false }, location: { href: 'http://127.0.0.1/', origin: 'http://127.0.0.1' } };
  const p = createPlayer({ globalObj: g, makeWebPlayer: w.make, onStatus: l => lines.push(l) });
  assert.equal(await p.load('https://gallery.example/f/x.m4a', 'X'), 'unavailable');
  assert.equal(await p.play(), false);
  assert.equal(w.calls.length, 0);
  assert.equal(lines.at(-1), OFFLINE_LINE);
});

// Regression guard: UI-12
test('UI-12 P6: availability: device, cached, network, unavailable', async () => {
  const hub = { href: 'https://recense.local/editor/', origin: 'https://recense.local' };
  const on = { navigator: { onLine: true }, location: hub };
  const off = { navigator: { onLine: false }, location: hub };
  assert.equal(await mediaAvailability('blob:https://recense.local/1', { globalObj: off }), 'device');
  assert.equal(await mediaAvailability('data:audio/wav;base64,AA==', { globalObj: off }), 'device');
  assert.equal(await mediaAvailability('/media/a.m4a', { globalObj: off }), 'device');
  assert.equal(await mediaAvailability('https://x.example/a.m4a', { globalObj: on }), 'network');
  assert.equal(await mediaAvailability('https://x.example/a.m4a', { globalObj: off }), 'unavailable');
  const cached = { ...off, caches: { match: async u => (u === 'https://x.example/a.m4a' ? {} : undefined) } };
  assert.equal(await mediaAvailability('https://x.example/a.m4a', { globalObj: cached }), 'cached');
  const remote = { navigator: { onLine: false }, location: { href: 'https://gallery.example/main/editor/', origin: 'https://gallery.example' } };
  assert.equal(await mediaAvailability('/f/a.m4a', { globalObj: remote }), 'unavailable');
  assert.equal(await mediaAvailability('', { globalObj: on }), 'unavailable');
  assert.ok(isLocalHost('127.0.0.1') && isLocalHost('recense.local') && isLocalHost('localhost') && !isLocalHost('example.com'));
});

// Regression guard: UI-12
test('UI-12 P6: Gallery player rules bundled from library/src/client, not copied into editor/', async () => {
  const fs = await import('node:fs');
  const src = fs.readFileSync(new URL('../src/player.js', import.meta.url), 'utf8');
  assert.match(src, /from '\.\.\/\.\.\/library\/src\/client\/webplayer\.js'|import '\.\.\/\.\.\/library\/src\/client\/webplayer\.js'/);
  assert.doesNotMatch(src, /setPositionState|setActionHandler/);
  assert.equal(typeof globalThis.RecenseWebPlayer?.create, 'function');
});
