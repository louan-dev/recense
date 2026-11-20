// Derived from Spec: FEAT-39
// Tests for sync/src/livestate.mjs. Invariants 1-4 and 6 of the spec, plus the manifest fields, the age label boundaries
// and the watcher. Invariant 5 (iPad opens the last copy) is a device check. Run: node --test test/
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import {
  DEBOUNCE_MS, ZIP_CAP, isSkipped, ageLabel, fileState, listWorktrees, buildManifest, writeManifest,
  createDebouncer, startWatcher, snapshot,
} from '../src/livestate.mjs';

const ENV = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@t', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@t' };
const git = (cwd, ...a) => execFileSync('git', a, { cwd, encoding: 'utf8', env: ENV }).trim();
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'live-'));
const put = (root, rel, text) => { const f = path.join(root, rel); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, text); return f; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function mkRepo() {
  const r = fs.realpathSync(tmp());
  git(r, 'init', '-q', '-b', 'main');
  put(r, 'a.txt', 'one\ntwo\nthree\n'); put(r, 'b.txt', 'x\ny\n'); put(r, 'src/x.js', 'let a = 1;\n');
  git(r, 'add', '.'); git(r, 'commit', '-q', '-m', 'base');
  return r;
}
// every file under root (not .git, not the inbox) → sha256, to prove "nothing else changed"
function tree(root, skip = []) {
  const out = {};
  const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const p = path.join(d, e.name), rel = path.relative(root, p);
    if (rel === '.git' || skip.some((s) => rel === s || rel.startsWith(s + '/'))) continue;
    if (e.isDirectory()) walk(p); else out[rel] = crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
  } };
  walk(root); return out;
}
const state = (r) => ({ head: git(r, 'rev-parse', 'HEAD'), index: fs.readFileSync(path.join(r, '.git/index')), status: git(r, 'status', '--porcelain') });

test('constants from the spec', () => { assert.equal(DEBOUNCE_MS, 5000); assert.equal(ZIP_CAP, 25 * 1024 * 1024); });

test('skip list: secrets and noise are never listed', () => {
  for (const p of ['.env', '.env.local', 'x/.env', 'Secrets/a.txt', 'a/Secrets/b', 'k.key', 'd/k.pem', 'node_modules/x/y.js', 'a/node_modules/y', '.build/z', 'p/.build/z', '.handoff/coordinator/inbox/a.md', '.handoff/coordinator/CURRENT'])
    assert.equal(isSkipped(p), true, p);
  for (const p of ['src/env.js', 'keyboard.js', 'notes.pem.txt', 'secrets.md', 'docs/build/x.md', '.handoff/HANDOFF.md'])
    assert.equal(isSkipped(p), false, p);
});

test('age label: "just now" under 60 s, boundaries on both sides', () => {
  assert.equal(ageLabel(0), 'just now'); assert.equal(ageLabel(59_999), 'just now');
  assert.equal(ageLabel(60_000), '1 min ago'); assert.equal(ageLabel(179_000), '2 min ago');
  assert.equal(ageLabel(3_599_999), '59 min ago'); assert.equal(ageLabel(3_600_000), '1 h ago');
  assert.equal(ageLabel(86_399_999), '23 h ago'); assert.equal(ageLabel(86_400_000), '1 d ago');
  assert.equal(ageLabel(-5000), 'just now'); // a clock a little ahead never shows a negative age
});

test('file state against the built stamp', () => {
  assert.equal(fileState(1000, 1000), 'BUILT'); assert.equal(fileState(1001, 1000), 'UNBUILT'); assert.equal(fileState(999, 1000), 'BUILT');
  assert.equal(fileState(1000, null), 'UNKNOWN');
});

test('worktrees: every one from git, minus missing and ignored', () => {
  const r = mkRepo(); const w = path.join(tmp(), 'lane'); git(r, 'worktree', 'add', '-q', '-b', 'work/lane', w);
  const gone = path.join(tmp(), 'gone'); git(r, 'worktree', 'add', '-q', '-b', 'work/gone', gone); fs.rmSync(gone, { recursive: true });
  const names = listWorktrees(r).map((x) => x.name).sort();
  assert.deepEqual(names, [path.basename(r), 'lane'].sort());
  const ign = path.join(tmp(), 'ignore'); fs.writeFileSync(ign, `# comment\n${fs.realpathSync(w)}\n`);
  assert.deepEqual(listWorktrees(r, { ignoreFile: ign }).map((x) => x.name), [path.basename(r)]);
});

test('manifest: status, counts, hash, mtime, state; no idle churn', () => {
  const r = mkRepo();
  put(r, 'a.txt', 'one\nTWO\nthree\n');          // M +1 -1
  put(r, 'new.txt', 'p\nq\nr\ns\n');             // ? +4 -0
  fs.rmSync(path.join(r, 'b.txt'));              // D +0 -2
  git(r, 'add', 'src/x.js'); put(r, 'src/x.js', 'let a = 1;\nlet b = 2;\n'); git(r, 'add', 'src/x.js'); // staged edit: M
  put(r, '.env', 'SECRET=1\n');
  const now = Date.now(); const before = state(r);
  const m = buildManifest(r, { now }); const wt = m.worktrees[0]; const by = Object.fromEntries(wt.files.map((f) => [f.path, f]));
  assert.deepEqual(Object.keys(by).sort(), ['a.txt', 'b.txt', 'new.txt', 'src/x.js']);
  assert.deepEqual([by['a.txt'].status, by['a.txt'].added, by['a.txt'].deleted], ['M', 1, 1]);
  assert.deepEqual([by['new.txt'].status, by['new.txt'].added, by['new.txt'].deleted], ['?', 4, 0]);
  assert.deepEqual([by['b.txt'].status, by['b.txt'].added, by['b.txt'].deleted, by['b.txt'].sha256, by['b.txt'].mtime], ['D', 0, 2, null, null]);
  assert.equal(by['src/x.js'].status, 'M');
  assert.equal(by['new.txt'].sha256, crypto.createHash('sha256').update('p\nq\nr\ns\n').digest('hex'));
  assert.match(by['new.txt'].mtime, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z$/);
  assert.equal(by['new.txt'].state, 'UNKNOWN');
  assert.equal(wt.branch, 'main'); assert.equal(wt.head, before.head);
  assert.deepEqual(state(r), before, 'building a manifest must not touch HEAD or the index');
});

test('manifest state follows the built stamp (BUILT if mtime <= stamp)', () => {
  const r = mkRepo(); put(r, 'a.txt', 'changed\n');
  const stamp = path.join(r, '.git', 'recense-built'); fs.writeFileSync(stamp, ''); const t = new Date(Date.now() + 5000); fs.utimesSync(stamp, t, t);
  assert.equal(buildManifest(r).worktrees[0].files[0].state, 'BUILT');
  const later = new Date(Date.now() + 60_000); fs.utimesSync(path.join(r, 'a.txt'), later, later);
  assert.equal(buildManifest(r).worktrees[0].files[0].state, 'UNBUILT');
});

test('a clean worktree writes no entry', () => {
  const r = mkRepo(); assert.deepEqual(buildManifest(r).worktrees, []);
});

test('writeManifest: atomic, skips when only the time changed, logs both', () => {
  const r = mkRepo(); put(r, 'a.txt', 'changed\n'); const out = path.join(tmp(), 'live', 'live.json'); const ev = [];
  const log = (e) => ev.push(e);
  assert.equal(writeManifest(r, out, { now: 1_000_000, log }), 'written');
  const first = fs.readFileSync(out, 'utf8');
  assert.equal(writeManifest(r, out, { now: 2_000_000, log }), 'skipped');
  assert.equal(fs.readFileSync(out, 'utf8'), first, 'unchanged content is not rewritten');
  put(r, 'a.txt', 'changed again\n'); assert.equal(writeManifest(r, out, { now: 3_000_000, log }), 'written');
  assert.deepEqual(ev.map((e) => e.event), ['live.manifest.written', 'live.manifest.skipped', 'live.manifest.written']);
  assert.equal(ev[0].files, 1); assert.equal(typeof ev[0].ms, 'number'); assert.equal(ev[1].reason, 'unchanged');
  assert.deepEqual(fs.readdirSync(path.dirname(out)), ['live.json'], 'no temp file left behind');
});

test('invariant 3: two saves 3 s apart give one write (debouncer, fake clock)', () => {
  let t = 0; const q = []; let calls = 0;
  const timers = { setTimeout: (fn, ms) => { const h = { at: t + ms, fn }; q.push(h); return h; }, clearTimeout: (h) => { q.splice(q.indexOf(h), 1); } };
  const advance = (to) => { while (q.length && q.sort((a, b) => a.at - b.at)[0].at <= to) { const h = q.shift(); t = h.at; h.fn(); } t = to; };
  const d = createDebouncer(DEBOUNCE_MS, () => { calls++; }, timers);
  d.poke();                 // save at 0
  advance(3000); d.poke();  // save at 3 s
  advance(7999); assert.equal(calls, 0, '4999 ms after the last save: not yet');
  advance(8000); assert.equal(calls, 1, '5000 ms after the last save: once');
  advance(60_000); assert.equal(calls, 1);
});

test('invariant 3 (real timers): a burst gives one wake', async () => {
  let n = 0; const d = createDebouncer(80, () => { n++; });
  d.poke(); await sleep(30); d.poke(); await sleep(30); d.poke(); await sleep(250);
  assert.equal(n, 1);
});

// The Claude Bash sandbox blocks FSEvents (checked 2026-11-19: this test fails inside it, passes outside). Probe first, skip loudly.
async function fseventsWorks() {
  const d = tmp(); let hit = false; const w = fs.watch(d, { recursive: true }, () => { hit = true; });
  await sleep(200); fs.writeFileSync(path.join(d, 'p'), 'x'); for (let i = 0; i < 15 && !hit; i++) await sleep(100); w.close(); return hit;
}
test('watcher: a real write wakes once; node_modules and the inbox do not', async (t) => {
  if (!(await fseventsWorks())) return t.skip('FSEvents blocked here (sandbox): run this file outside it');
  const r = mkRepo(); let wakes = 0;
  const w = startWatcher({ repo: r, debounceMs: 120, onWake: () => { wakes++; } });
  try {
    await sleep(300);
    put(r, 'node_modules/p/i.js', 'x'); put(r, '.handoff/coordinator/inbox/a.md', 'x'); put(r, '.git/ignored-marker', 'x');
    await sleep(600); assert.equal(wakes, 0, 'ignored paths never wake');
    put(r, 'src/x.js', 'let a = 2;\n'); put(r, 'src/y.js', 'y\n');
    for (let i = 0; i < 40 && !wakes; i++) await sleep(100);
    await sleep(500); assert.equal(wakes, 1);
  } finally { w.close(); }
});

// ---- snapshot ---------------------------------------------------------------------------------------------------
const mkWork = () => {
  const r = mkRepo();
  put(r, 'a.txt', 'one\nTWO\nthree\n'); put(r, 'new/n.txt', 'hello\n'); fs.rmSync(path.join(r, 'b.txt'));
  put(r, '.env', 'API=SECRET-VALUE-1\n'); put(r, 'Secrets/s.txt', 'SECRET-VALUE-2\n'); put(r, 'k.pem', 'SECRET-VALUE-3\n');
  fs.writeFileSync(path.join(r, 'pic.bin'), Buffer.from([0, 1, 2, 3, 0, 255, 254, 0]));
  return r;
};
const snap = (r, extra = {}) => { const inbox = path.join(tmp(), 'inbox'); const posted = []; const ev = [];
  const res = snapshot(r, { inboxDir: inbox, post: (n) => posted.push(n), log: (e) => ev.push(e), now: Date.now(), ...extra });
  return { res, inbox, posted, ev }; };

test('invariant 1 + 6: HEAD, index and every working file are untouched; only inbox/live and refs/wip change', () => {
  const r = mkWork(); state(r); /* the test's own `git status` refreshes the index once; baseline after that */ const before = state(r); const files = tree(r); const refsBefore = git(r, 'for-each-ref', '--format=%(refname)');
  const { res, inbox } = snap(r);
  assert.equal(res.ok, true);
  assert.deepEqual(state(r), before); assert.deepEqual(tree(r), files);
  assert.equal(git(r, 'for-each-ref', '--format=%(refname)', 'refs/heads', 'refs/tags'), refsBefore);
  assert.match(res.ref, new RegExp(`^refs/wip/${path.basename(r)}/\\d{8}-\\d{6}$`));
  assert.equal(git(r, 'rev-parse', res.ref), res.sha);
  assert.deepEqual(fs.readdirSync(inbox), ['live'], 'attachments live in inbox/live only');
});

test('invariant 2: nothing from the skip list reaches the patch, the zip or the note', () => {
  const r = mkWork(); const { res, posted } = snap(r);
  const patch = fs.readFileSync(res.patch, 'utf8');
  assert.doesNotMatch(patch, /SECRET-VALUE/); assert.doesNotMatch(posted[0], /SECRET-VALUE/);
  for (const p of ['.env', 'Secrets/', 'k.pem']) { assert.ok(!patch.includes(p), p); }
  assert.ok(!res.files.some((f) => /\.env|Secrets|\.pem/.test(f)), 'file list');
  if (res.zip) assert.doesNotMatch(execFileSync('unzip', ['-l', res.zip], { encoding: 'utf8' }), /\.env|Secrets|k\.pem/);
});

test('a tracked file on the skip list is excluded too', () => {
  const r = mkRepo(); put(r, '.env', 'A=1\n'); git(r, 'add', '-f', '.env'); git(r, 'commit', '-q', '-m', 'env'); put(r, '.env', 'A=SECRET-TRACKED\n'); put(r, 'a.txt', 'z\n');
  const { res } = snap(r); assert.doesNotMatch(fs.readFileSync(res.patch, 'utf8'), /SECRET-TRACKED/); assert.deepEqual(res.files, ['a.txt']);
});

test('invariant 4: the patch applies cleanly to the base commit (modify, add, delete)', () => {
  const r = mkWork(); const { res } = snap(r);
  const clone = path.join(tmp(), 'base'); git(tmp(), 'clone', '-q', r, clone);
  assert.equal(git(clone, 'rev-parse', 'HEAD'), git(r, 'rev-parse', 'HEAD'));
  execFileSync('git', ['apply', '--check', res.patch], { cwd: clone, env: ENV });
  execFileSync('git', ['apply', res.patch], { cwd: clone, env: ENV });
  assert.equal(fs.readFileSync(path.join(clone, 'a.txt'), 'utf8'), 'one\nTWO\nthree\n');
  assert.equal(fs.readFileSync(path.join(clone, 'new/n.txt'), 'utf8'), 'hello\n');
  assert.ok(!fs.existsSync(path.join(clone, 'b.txt')));
});

test('binary files go in the zip, not the patch', () => {
  const r = mkWork(); const { res } = snap(r);
  assert.ok(res.zip && fs.existsSync(res.zip));
  assert.match(execFileSync('unzip', ['-l', res.zip], { encoding: 'utf8' }), /pic\.bin/);
  assert.ok(!fs.readFileSync(res.patch, 'utf8').includes('pic.bin'));
});

test('size cap: above it the note lists the file and no zip is made', () => {
  const r = mkWork(); const { res, posted, ev } = snap(r, { capBytes: 4 });
  assert.equal(res.zip, null); assert.match(posted[0], /pic\.bin/); assert.match(posted[0], /no zip/i);
  assert.ok(ev.some((e) => e.event === 'live.snapshot.made'));
});

test('a private key in an included file refuses the snapshot and posts nothing', () => {
  const r = mkRepo(); const hdr = '-----BEGIN OPENSSH ' + 'PRIVATE KEY-----\n';   // split so this file itself never looks like a key
  put(r, 'doc.md', hdr + 'abc\n');                                          // a bare header (fixture, documentation) is not a key
  assert.equal(snap(r).res.ok, true);
  const refs = git(r, 'for-each-ref', 'refs/wip');
  put(r, 'notes.txt', hdr + 'A'.repeat(64) + '\n'); const { res, posted, ev, inbox } = snap(r);
  assert.equal(res.ok, false); assert.equal(res.reason, 'secret'); assert.equal(posted.length, 0); assert.ok(!fs.existsSync(inbox));
  assert.deepEqual(ev.map((e) => [e.event, e.reason]), [['live.snapshot.refused', 'secret']]);
  assert.equal(git(r, 'for-each-ref', 'refs/wip'), refs, 'no new ref left behind');
});

test('nothing changed: refused, not an empty snapshot', () => {
  const r = mkRepo(); const { res, ev } = snap(r); assert.equal(res.ok, false); assert.equal(res.reason, 'clean'); assert.equal(ev[0].event, 'live.snapshot.refused');
});

test('label: UNBUILT without a stamp, BUILT only when every file is at or before the stamp; the note never claims more', () => {
  const r = mkRepo(); put(r, 'a.txt', 'changed\n');
  let s = snap(r); assert.equal(s.res.state, 'UNBUILT'); assert.match(s.posted[0], /^REVIEW SNAPSHOT: .+ @ [0-9a-f]{40} \(UNBUILT\)/);
  assert.equal(s.res.readyLine, `READY FOR REVIEW: ${path.basename(r)} @ ${s.res.sha} (UNBUILT)`);
  const stamp = path.join(r, '.git', 'recense-built'); fs.writeFileSync(stamp, ''); const t = new Date(Date.now() + 5000); fs.utimesSync(stamp, t, t);
  s = snap(r); assert.equal(s.res.state, 'BUILT'); assert.match(s.posted[0], /\(BUILT\)/);
  assert.doesNotMatch(s.posted[0], /^READY FOR REVIEW/m, 'a snapshot note is never a READY claim');
});

test('snapshot event carries worktree, files, bytes, state', () => {
  const r = mkWork(); const { ev, res } = snap(r); const e = ev.find((x) => x.event === 'live.snapshot.made');
  assert.equal(e.worktree, path.basename(r)); assert.equal(e.files, res.files.length); assert.equal(typeof e.bytes, 'number'); assert.equal(e.state, 'UNBUILT');
});
