// Derived from Spec: FEAT-18 (H1c). The browser side of the hub: it only syncs on a hub host with a token, never loses
// typed text, and a failed request leaves the writer alone.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { createHubSync, isHubHost, tokenFromHash, installHubSync } from '../src/hubsync.js';

const memStore = (init = {}) => {
  const m = new Map(Object.entries(init));
  return { m, get: async k => m.get(k), put: async (k, v) => { m.set(k, v); } };
};
const reply = (status, body) => ({ status, json: async () => body });
function rig({ store, responses }) {
  const calls = [], shown = [];
  const sync = createHubSync({
    store,
    fetchFn: async (url, init) => {
      calls.push({ url, init, body: JSON.parse(init.body) });
      const r = responses.shift();
      if (r instanceof Error) throw r;
      return r;
    },
    getApi: () => ({ setText: t => shown.push(t) }),
    setTimer: fn => { fn.__t = true; return fn; },
    clearTimer: () => {}
  });
  return { sync, calls, shown };
}

test('only hub hosts sync; the pairing token comes from #pair= and nothing else', () => {
  assert.ok(isHubHost('recense.local') && isHubHost('mac.recense.local') && isHubHost('mini.recense.local'));
  assert.ok(!isHubHost('gallery.improvdiplomat.workers.dev') && !isHubHost('evilrecense.local') && !isHubHost(''));
  assert.equal(tokenFromHash('#pair=' + 'a'.repeat(64)), 'a'.repeat(64));
  assert.equal(tokenFromHash('#pair=short'), null);
  assert.equal(tokenFromHash(''), null);
});

test('off a hub host, installHubSync does nothing', () => {
  const win = { location: { hostname: 'localhost', hash: '#pair=' + 'a'.repeat(64) }, addEventListener() { throw new Error('touched'); } };
  assert.equal(installHubSync(win, memStore()), null);
  assert.equal(installHubSync({ location: { hostname: 'file' } }, memStore()), null);
});

test('a page with no text yet still asks the hub, as a first contact, and shows the note', async () => {
  const store = memStore({ hubToken: 't'.repeat(32) });
  const { sync, calls, shown } = rig({ store, responses: [reply(200, { status: 'recovered', text: 'the Mac note', base: 'the Mac note' })] });
  await sync.run();
  assert.equal(calls[0].body.base, null);
  assert.equal(calls[0].body.mine, '');
  assert.deepEqual(shown, ['the Mac note']);
});

test('an empty editor is never sent against a known base (it would wipe the note): first contact instead', async () => {
  const store = memStore({ hubToken: 't'.repeat(32), text: '', hubBase: 'my whole note' });
  const { sync, calls } = rig({ store, responses: [reply(200, { status: 'recovered', text: 'my whole note', base: 'my whole note' })] });
  await sync.run();
  assert.equal(calls[0].body.base, null);
  assert.equal(calls[0].body.mine, '');
});

test('lost local text with a remembered base is a first contact too, not a delete', async () => {
  const store = memStore({ hubToken: 't'.repeat(32), hubBase: 'my whole note' });
  const { sync, calls } = rig({ store, responses: [reply(200, { status: 'recovered', text: 'my whole note', base: 'my whole note' })] });
  await sync.run();
  assert.equal(calls[0].body.base, null);
});

test('no token: no request at all (writing stays local)', async () => {
  const { sync, calls } = rig({ store: memStore({ text: 'typed' }), responses: [] });
  await sync.run();
  assert.equal(calls.length, 0);
});

test('first contact sends base:null; what comes back is shown and becomes the base', async () => {
  const store = memStore({ hubToken: 't'.repeat(32), text: 'a scrap' });
  const { sync, calls, shown } = rig({ store, responses: [reply(200, { status: 'recovered', text: 'the note\na scrap', base: 'the note\na scrap' })] });
  await sync.run();
  assert.equal(calls[0].body.base, null);
  assert.equal(calls[0].body.mine, 'a scrap');
  assert.equal(calls[0].init.headers.Authorization, 'Bearer ' + 't'.repeat(32));
  assert.deepEqual(shown, ['the note\na scrap']);
  assert.equal(store.m.get('hubBase'), 'the note\na scrap');
  assert.equal(store.m.get('text'), 'the note\na scrap');
});

test('a clean save shows nothing new and moves the base', async () => {
  const store = memStore({ hubToken: 't'.repeat(32), text: 'one\ntwo', hubBase: 'one' });
  const { sync, calls, shown } = rig({ store, responses: [reply(200, { status: 'saved', text: 'one\ntwo', base: 'one\ntwo' })] });
  await sync.run();
  assert.equal(calls[0].body.base, 'one');
  assert.deepEqual(shown, []);
  assert.equal(store.m.get('hubBase'), 'one\ntwo');
  assert.equal(sync.isDirty(), false);
});

test('an edit from another device is adopted and shown', async () => {
  const store = memStore({ hubToken: 't'.repeat(32), text: 'one', hubBase: 'one' });
  const { sync, shown } = rig({ store, responses: [reply(200, { status: 'adopt', text: 'one\nfrom the Mac', base: 'one\nfrom the Mac' })] });
  await sync.run();
  assert.deepEqual(shown, ['one\nfrom the Mac']);
  assert.equal(store.m.get('text'), 'one\nfrom the Mac');
});

test('text typed while the request was out is never replaced by the reply', async () => {
  const store = memStore({ hubToken: 't'.repeat(32), text: 'one', hubBase: 'one' });
  const rigged = rig({ store, responses: [] });
  const sync = createHubSync({
    store, getApi: () => ({ setText: () => assert.fail('must not overwrite newer typing') }),
    fetchFn: async () => { await store.put('text', 'one\nI kept typing'); return reply(200, { status: 'adopt', text: 'one\nMac', base: 'one\nMac' }); },
    setTimer: fn => fn, clearTimer() {}
  });
  await sync.run();
  assert.equal(store.m.get('text'), 'one\nI kept typing');
  assert.equal(sync.isDirty(), true, 'the typed text still has to be sent');
  void rigged;
});

test('offline or a hub error: nothing is lost, it stays dirty for the next try', async () => {
  for (const r of [new Error('offline'), reply(503, { status: 'wait' }), reply(500, {})]) {
    const store = memStore({ hubToken: 't'.repeat(32), text: 'typed', hubBase: 'old' });
    const { sync, shown } = rig({ store, responses: [r] });
    await sync.run();
    assert.equal(store.m.get('text'), 'typed');
    assert.equal(store.m.get('hubBase'), 'old');
    assert.deepEqual(shown, []);
    assert.equal(sync.isDirty(), true);
  }
});

test('a rejected token is dropped so it is not sent again', async () => {
  const store = memStore({ hubToken: 't'.repeat(32), text: 'typed' });
  const { sync } = rig({ store, responses: [reply(401, { error: 'no token' })] });
  await sync.run();
  assert.equal(store.m.get('hubToken'), '');
});

test('no localStorage use in the editor source can throw: each sits inside a try (Safari file://)', () => {
  const bad = [];
  for (const f of readdirSync(new URL('../src/', import.meta.url)).filter(n => n.endsWith('.js'))) {
    const lines = readFileSync(new URL('../src/' + f, import.meta.url), 'utf8').split('\n');
    lines.forEach((l, i) => {
      if (!/\blocalStorage\b/.test(l) || /^\s*(\/\/|\*)/.test(l)) return;
      const before = lines.slice(Math.max(0, i - 8), i + 1).join('\n');
      if (!/\btry\b/.test(before) && !/catch/.test(lines.slice(i, i + 6).join('\n'))) bad.push(f + ':' + (i + 1));
    });
  }
  assert.deepEqual(bad, []);
});

// Regression guard: FEAT-18 review #1 (2026-11-17). When the reply is not adopted because the writer typed meanwhile, the
// base must stay what this browser sent, never the hub's text; else the next send reads as "nothing changed on the hub"
// and the other device's edit is overwritten.
test('typing during the request keeps the sent text as base, so the Mac edit survives the next send', async () => {
  const store = memStore({ hubToken: 't'.repeat(32), text: 'one', hubBase: 'one' });
  const sync = createHubSync({
    store, getApi: () => ({ setText: () => assert.fail('must not overwrite newer typing') }),
    fetchFn: async () => { await store.put('text', 'one\nI kept typing'); return reply(200, { status: 'adopt', text: 'one\nMac', base: 'one\nMac' }); },
    setTimer: fn => fn, clearTimer() {}
  });
  await sync.run();
  assert.equal(store.m.get('hubBase'), 'one', 'base = what was sent, not the reply');
});

// Regression guard: FEAT-18 review #2. Keys typed in the editor but not yet flushed to the store (300 ms debounce) count
// as typed: the reply is not shown over them, and the base stays what was sent.
test('unflushed editor text blocks adopting the reply', async () => {
  const store = memStore({ hubToken: 't'.repeat(32), text: 'one', hubBase: 'one' });
  const sync = createHubSync({
    store,
    getApi: () => ({ getText: () => 'one\nunsaved keys', setText: () => assert.fail('must not replace unsaved keys') }),
    fetchFn: async () => reply(200, { status: 'adopt', text: 'one\nMac', base: 'one\nMac' }),
    setTimer: fn => fn, clearTimer() {}
  });
  await sync.run();
  assert.equal(store.m.get('text'), 'one');
  assert.equal(store.m.get('hubBase'), 'one');
  assert.equal(sync.isDirty(), true);
});
