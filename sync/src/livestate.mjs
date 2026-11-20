#!/usr/bin/env node
// Derived from Spec: FEAT-39 (P1 the watcher and the manifest, P3 the review snapshot). Zero dependencies.
// The one home of Live edits logic: the manifest, the skip list, the snapshot, the file names. live.zsh and the launchd plist are glue.
//
//   node livestate.mjs manifest [--out FILE]      write the manifest once (default ~/Recense/live/live.json)
//   node livestate.mjs watch                      write it now, then again 5 s after the last save in any worktree (FSEvents, no polling)
//   node livestate.mjs snapshot [WORKTREE]        review snapshot of a worktree (path or name; default: the one you are in)
//   node livestate.mjs built                      mark this worktree "its cheapest check just passed" (BUILT stamp)
// Events go to ~/Recense/logs/live.jsonl. Nothing here uses the network.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const DEBOUNCE_MS = 5000;               // spec P1: run only after no write for 5 s
export const ZIP_CAP = 25 * 1024 * 1024;       // spec P3: zip at most 25 MB (also the patch limit)
const HOME = os.homedir();
const REPO = process.env.LIVE_REPO || path.join(HOME, 'Developer/recense');
const LIVE_FILE = process.env.LIVE_FILE || path.join(HOME, 'Recense/live/live.json');
const LOG_FILE = process.env.LIVE_LOG || path.join(HOME, 'Recense/logs/live.jsonl');
const IGNORE_FILE = process.env.LIVE_IGNORE || path.join(HOME, '.config/recense/live-ignore');
const COORD = path.join(path.dirname(fileURLToPath(import.meta.url)), '../bin/coord.zsh');
const INBOX = process.env.LIVE_INBOX || path.join(REPO, '.handoff/coordinator/inbox');

// ---- small pieces --------------------------------------------------------------------------------------------------
/** True for paths never listed, never snapshotted: secrets (spec skip list) and noise (.handoff/coordinator, .DS_Store). */
export function isSkipped(rel) {
  const parts = rel.split('/'); const base = parts[parts.length - 1];
  if (parts.some((s) => s === 'node_modules' || s === '.build' || s === 'Secrets')) return true;
  if (base.startsWith('.env') || base.endsWith('.key') || base.endsWith('.pem') || base === '.DS_Store') return true;
  return rel === '.handoff/coordinator' || rel.startsWith('.handoff/coordinator/');
}

/** "just now" under 60 s, then "3 min ago", "2 h ago", "1 d ago". */
export function ageLabel(ms) {
  if (!(ms >= 60_000)) return 'just now';
  const m = Math.floor(ms / 60_000); if (m < 60) return `${m} min ago`;
  const h = Math.floor(ms / 3_600_000); if (h < 24) return `${h} h ago`;
  return `${Math.floor(ms / 86_400_000)} d ago`;
}

/** BUILT if the file is no newer than the last passed check; UNKNOWN when no check was ever stamped. */
export const fileState = (mtimeMs, stampMs) => (stampMs == null ? 'UNKNOWN' : mtimeMs <= stampMs ? 'BUILT' : 'UNBUILT');

function defaultLog(e) {
  try { fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true }); fs.appendFileSync(LOG_FILE, JSON.stringify({ t: new Date().toISOString(), ...e }) + '\n'); } catch { /* logging never blocks */ }
}

const GIT_ENV = { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_LITERAL_PATHSPECS: '1', LC_ALL: 'C' };
function git(cwd, args, { env, input, buffer } = {}) {
  const out = execFileSync('git', args, { cwd, env: { ...GIT_ENV, ...env }, input, maxBuffer: 1 << 29, stdio: ['pipe', 'pipe', 'pipe'] });
  return buffer ? out : out.toString('utf8');
}
const tryGit = (cwd, args, o) => { try { return git(cwd, args, o); } catch { return null; } };

// ---- worktrees -----------------------------------------------------------------------------------------------------
/** Every worktree git knows (main checkout and all lanes, wherever they live), minus prunable, missing and ignore-listed ones. */
export function listWorktrees(repo = REPO, { ignoreFile = IGNORE_FILE } = {}) {
  const ignored = new Set();
  try { for (const l of fs.readFileSync(ignoreFile, 'utf8').split('\n')) { const t = l.trim(); if (t && !t.startsWith('#')) { try { ignored.add(fs.realpathSync(t)); } catch { ignored.add(t); } } } } catch { /* optional */ }
  const out = tryGit(repo, ['worktree', 'list', '--porcelain']); if (!out) return [];
  const list = [];
  for (const block of out.split('\n\n')) {
    const f = {}; for (const line of block.split('\n')) { const i = line.indexOf(' '); f[i < 0 ? line : line.slice(0, i)] = i < 0 ? true : line.slice(i + 1); }
    if (!f.worktree || 'prunable' in f || !fs.existsSync(f.worktree)) continue;
    let p = f.worktree; try { p = fs.realpathSync(p); } catch { /* keep */ }
    if (ignored.has(p)) continue;
    list.push({ name: path.basename(p), path: p, branch: f.branch ? String(f.branch).replace(/^refs\/heads\//, '') : 'HEAD', head: f.HEAD || '' });
  }
  return list;
}

const stampPath = (wt) => { const g = tryGit(wt, ['rev-parse', '--absolute-git-dir']); return g ? path.join(g.trim(), 'recense-built') : null; };
const stampMs = (wt) => { try { return fs.statSync(stampPath(wt)).mtimeMs; } catch { return null; } };

/** `zsh live.zsh built` → this worktree's cheapest check just passed. */
export function markBuilt(wt) { const p = stampPath(wt); if (!p) throw new Error('not a git worktree'); fs.closeSync(fs.openSync(p, 'a')); const n = new Date(); fs.utimesSync(p, n, n); return p; }

function countLines(buf) { if (buf.includes(0)) return null; let n = 0; for (const b of buf) if (b === 10) n++; if (buf.length && buf[buf.length - 1] !== 10) n++; return n; }

/** Modified, added, deleted and untracked paths of one worktree against HEAD: path, status, mtime, sha256, +added −deleted, state. */
export function worktreeFiles(wt, { now = Date.now() } = {}) {
  const st = tryGit(wt, ['status', '--porcelain=v1', '-z', '--untracked-files=all', '--no-renames']); if (st == null) return [];
  const stamp = stampMs(wt);
  const num = new Map();
  const nsOut = tryGit(wt, ['diff', '--numstat', '-z', '--no-renames', 'HEAD']);
  if (nsOut) for (const rec of nsOut.split('\0')) { const m = /^(-|\d+)\t(-|\d+)\t(.+)$/s.exec(rec); if (m) num.set(m[3], m[1] === '-' ? null : { a: +m[1], d: +m[2] }); }
  const files = [];
  for (const rec of st.split('\0')) {
    if (rec.length < 4) continue;
    const xy = rec.slice(0, 2), rel = rec.slice(3); if (isSkipped(rel)) continue;
    const abs = path.join(wt, rel); let lst = null; try { lst = fs.lstatSync(abs); } catch { /* deleted */ }
    const status = xy === '??' ? '?' : !lst ? 'D' : xy[0] === 'A' ? 'A' : 'M';
    if (lst && lst.isDirectory()) continue;
    let sha = null, mtime = null, added = 0, deleted = 0, binary = false, fstate = 'UNKNOWN';
    if (lst) {
      const buf = lst.isSymbolicLink() ? Buffer.from(fs.readlinkSync(abs)) : fs.readFileSync(abs);
      sha = crypto.createHash('sha256').update(buf).digest('hex'); mtime = new Date(lst.mtimeMs).toISOString(); fstate = fileState(lst.mtimeMs, stamp);
      if (status === '?') { const n = countLines(buf); if (n == null) binary = true; else added = n; }
    }
    if (status !== '?') { if (num.has(rel)) { const v = num.get(rel); if (v) { added = v.a; deleted = v.d; } else binary = true; } }
    files.push({ path: rel, status, mtime, sha256: sha, added, deleted, binary, state: lst ? fstate : 'UNKNOWN' });
  }
  files.sort((x, y) => (y.mtime ?? '').localeCompare(x.mtime ?? '') || x.path.localeCompare(y.path));
  return files;
}

/** The whole manifest: one entry per worktree that has changes. Written for the iPad (FEAT-39 P2). */
export function buildManifest(repo = REPO, { now = Date.now(), ignoreFile = IGNORE_FILE } = {}) {
  const worktrees = [];
  for (const w of listWorktrees(repo, { ignoreFile })) {
    const files = worktreeFiles(w.path, { now }); if (!files.length) continue;
    worktrees.push({ name: w.name, path: w.path, branch: w.branch, head: w.head, files });
  }
  return { generated: new Date(now).toISOString(), worktrees };
}

/** Write the manifest atomically; leave it alone when only `generated` would change. Returns 'written' | 'skipped'. */
export function writeManifest(repo = REPO, out = LIVE_FILE, { now = Date.now(), ignoreFile = IGNORE_FILE, log = defaultLog } = {}) {
  const t0 = Date.now(); const m = buildManifest(repo, { now, ignoreFile });
  const body = (x) => JSON.stringify({ ...x, generated: null });
  try { if (body(JSON.parse(fs.readFileSync(out, 'utf8'))) === body(m)) { log({ event: 'live.manifest.skipped', reason: 'unchanged' }); return 'skipped'; } } catch { /* none yet */ }
  fs.mkdirSync(path.dirname(out), { recursive: true });
  const tmp = path.join(path.dirname(out), `.${path.basename(out)}.${process.pid}.tmp`);
  fs.writeFileSync(tmp, JSON.stringify(m, null, 1) + '\n'); fs.renameSync(tmp, out);
  log({ event: 'live.manifest.written', worktree: m.worktrees.map((w) => w.name).join(','), files: m.worktrees.reduce((n, w) => n + w.files.length, 0), ms: Date.now() - t0 });
  return 'written';
}

// ---- the watcher ---------------------------------------------------------------------------------------------------
/** Run fn once, `ms` after the last poke. Timers are injectable so a test can use a fake clock. */
export function createDebouncer(ms, fn, timers = {}) {
  const set = timers.setTimeout || ((...a) => globalThis.setTimeout(...a)), clear = timers.clearTimeout || ((h) => globalThis.clearTimeout(h));
  let h = null;
  return { poke() { if (h) clear(h); h = set(() => { h = null; fn(); }, ms); }, cancel() { if (h) clear(h); h = null; } };
}

/** fs.watch recursive (FSEvents on macOS) on every worktree: no polling, nothing runs between events. */
export function startWatcher({ repo = REPO, debounceMs = DEBOUNCE_MS, onWake, ignoreFile = IGNORE_FILE, log = defaultLog } = {}) {
  const watchers = new Map(); let closed = false;
  const deb = createDebouncer(debounceMs, () => { if (closed) return; reconcile(); onWake(); });
  const handle = (root, filename) => {
    const rel = filename == null ? null : String(filename);
    if (rel == null) return deb.poke();
    if (rel === '.git' || rel.startsWith('.git/')) { const b = path.basename(rel); if (b === 'index' || b === 'HEAD') deb.poke(); return; }   // a commit or checkout changes what is "uncommitted"
    if (rel.startsWith('.claude/worktrees/') || isSkipped(rel)) return;                                                                           // lanes have their own watcher
    try { if (fs.statSync(path.join(root, rel)).isDirectory()) return; } catch { /* removed: counts */ }
    deb.poke();
  };
  function reconcile() {
    const want = new Map(listWorktrees(repo, { ignoreFile }).map((w) => [w.path, w]));
    for (const [p, w] of watchers) if (!want.has(p)) { try { w.close(); } catch { /* gone */ } watchers.delete(p); }
    for (const p of want.keys()) if (!watchers.has(p)) {
      try { const w = fs.watch(p, { recursive: true }, (_e, f) => handle(p, f)); w.on('error', (e) => log({ event: 'live.manifest.skipped', reason: `watch error ${e.code || e.message}: ${path.basename(p)}` })); watchers.set(p, w); }
      catch (e) { log({ event: 'live.manifest.skipped', reason: `watch failed ${e.code || e.message}: ${path.basename(p)}` }); }   // never silent: a worktree nobody watches must show in the log; the next wake retries
    }
  }
  reconcile();
  return { close() { closed = true; deb.cancel(); for (const w of watchers.values()) { try { w.close(); } catch { /* ok */ } } watchers.clear(); } };
}

// ---- the review snapshot -------------------------------------------------------------------------------------------
const pad = (n) => String(n).padStart(2, '0');
const stampName = (ms) => { const d = new Date(ms); return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`; };
// header + a real key body (40+ base64 characters on the next line): a bare header in a test fixture or a doc is not refused
const PRIVATE_KEY = /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----\r?\n[A-Za-z0-9+/=]{40,}/;

function identityEnv(cwd) {
  const have = (k) => process.env[k] || tryGit(cwd, ['config', k === 'n' ? 'user.name' : 'user.email'])?.trim();
  return { GIT_AUTHOR_NAME: have('n') || 'louan-dev', GIT_COMMITTER_NAME: have('n') || 'louan-dev',
    GIT_AUTHOR_EMAIL: have('e') || '296755203+louan-dev@users.noreply.github.com', GIT_COMMITTER_EMAIL: have('e') || '296755203+louan-dev@users.noreply.github.com' };
}

function defaultPost(note) {
  const r = spawnSync('zsh', [COORD, 'post', '-', 'live'], { input: note, encoding: 'utf8' });
  return r.status === 0 ? r.stdout.trim() : `post failed: ${(r.stderr || '').trim()}`;
}

/**
 * Review snapshot of one worktree without touching its branch, index or files (invariants 1 and 6):
 * a temporary index → tree → commit-tree on HEAD → refs/wip/<name>/<stamp>; the patch (text) and a zip (binary files only) go to <inbox>/live,
 * the note is posted through coord.zsh. Refuses (and writes nothing) when nothing changed, a private key is in an included file, or the patch is too big.
 */
export function snapshot(wtPath, { inboxDir = INBOX, now = Date.now(), post = defaultPost, log = defaultLog, capBytes = ZIP_CAP, patchCap = ZIP_CAP } = {}) {
  const wt = fs.realpathSync(wtPath); const name = path.basename(wt); const stamp = stampName(now);
  const refuse = (reason, extra = {}) => { log({ event: 'live.snapshot.refused', worktree: name, reason, ...extra }); return { ok: false, reason, ...extra }; };
  const files = worktreeFiles(wt, { now }); if (!files.length) return refuse('clean');
  for (const f of files) {   // a private key must never leave the Mac in a note, a patch or a zip
    if (f.status === 'D' || f.binary) continue;
    try { const abs = path.join(wt, f.path); if (fs.statSync(abs).size <= 5 << 20 && PRIVATE_KEY.test(fs.readFileSync(abs, 'latin1'))) return refuse('secret', { path: f.path }); } catch { /* unreadable: not included either */ }
  }
  const head = git(wt, ['rev-parse', 'HEAD']).trim(); const branch = tryGit(wt, ['symbolic-ref', '--short', '-q', 'HEAD'])?.trim() || 'HEAD';
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'live-idx-')); const idx = path.join(tmpDir, 'index');
  let sha, patch;
  try {
    const env = { GIT_INDEX_FILE: idx, ...identityEnv(wt) };
    git(wt, ['read-tree', 'HEAD'], { env });
    git(wt, ['add', '-A', '--pathspec-from-file=-', '--pathspec-file-nul'], { env, input: files.map((f) => f.path).join('\0') });
    const tree = git(wt, ['write-tree'], { env }).trim();
    sha = git(wt, ['commit-tree', tree, '-p', head, '-m', `wip snapshot ${name} ${stamp}`], { env }).trim();
    const binaries = files.filter((f) => f.binary).map((f) => f.path);
    patch = git(wt, ['diff', '--no-renames', head, sha, '--', '.', ...binaries.map((b) => `:(exclude,literal)${b}`)], { buffer: true, env: { GIT_LITERAL_PATHSPECS: '0' } });
  } finally { fs.rmSync(tmpDir, { recursive: true, force: true }); }
  if (patch.length > patchCap) return refuse('size', { bytes: patch.length });

  const ref = `refs/wip/${name.replace(/[^A-Za-z0-9._-]/g, '-')}/${stamp}`;
  git(wt, ['update-ref', ref, sha]);
  const dir = path.join(inboxDir, 'live'); fs.mkdirSync(dir, { recursive: true });
  const base = path.join(dir, `${stamp}-${name}`); const patchFile = `${base}.patch`; fs.writeFileSync(patchFile, patch);

  const bins = files.filter((f) => f.binary && f.status !== 'D'); let zipFile = null, zipNote = 'none (no binary files)';
  if (bins.length) {
    const total = bins.reduce((n, f) => n + fs.statSync(path.join(wt, f.path)).size, 0);
    if (total > capBytes) zipNote = `none: no zip, binary files total ${total} bytes, over the ${capBytes}-byte cap; named below`;
    else {
      const z = `${base}.zip`; const r = spawnSync('zip', ['-q', z, '-@'], { cwd: wt, input: bins.map((f) => f.path).join('\n') + '\n' });
      if (r.status === 0 && fs.statSync(z).size <= capBytes) { zipFile = z; zipNote = z; } else { fs.rmSync(z, { force: true }); zipNote = 'none: no zip (zip failed or over the cap); named below'; }
    }
  }
  const state = files.every((f) => f.state === 'BUILT') ? 'BUILT' : 'UNBUILT';
  const line = (f) => `- ${f.status} ${f.path} · +${f.added} −${f.deleted}${f.binary ? ' · binary' : ''} · edited ${f.mtime ? ageLabel(now - Date.parse(f.mtime)) : 'deleted'} · ${f.state}`;
  const note = [
    `REVIEW SNAPSHOT: ${name} @ ${sha} (${state})`, '',
    `Branch: ${branch} · base ${head.slice(0, 10)} · ref ${ref} (local only)`, `Taken: ${new Date(now).toISOString()}`,
    `Patch: ${patchFile}`, `Zip: ${zipNote}`, '',
    `Files (${files.length}):`, ...files.map(line), '',
    `State: ${state} means every file is no newer than the last passed check (\`live.zsh built\`); UNBUILT means that was not shown. Checks run: none recorded by this snapshot. Unchecked: everything.`,
    'This is a snapshot of uncommitted work, not a READY FOR REVIEW claim.', '',
  ].join('\n');
  const posted = post(note);
  const bytes = patch.length + (zipFile ? fs.statSync(zipFile).size : 0);
  log({ event: 'live.snapshot.made', worktree: name, files: files.length, bytes, state });
  return { ok: true, sha, ref, state, patch: patchFile, zip: zipFile, files: files.map((f) => f.path), note, posted, readyLine: `READY FOR REVIEW: ${name} @ ${sha} (${state})` };
}

// ---- command line --------------------------------------------------------------------------------------------------
/** The reply the hub gives the iPad after a snapshot: small, no Mac paths, no READY line (the button files the snapshot, it never claims a review). */
export function snapshotReply(res, name) {
  if (!res.ok) return { ok: false, status: 'refused', worktree: name, reason: res.reason, ...(res.path ? { path: res.path } : {}) };
  return { ok: true, status: 'made', worktree: name, sha: res.sha, state: res.state, files: res.files.length, zip: !!res.zip };
}

/** A worktree name from `git worktree list` wins; otherwise an existing path; no argument means the one you are in. */
export function resolveWorktree(arg, { repo = REPO } = {}) {
  if (!arg) return git(process.cwd(), ['rev-parse', '--show-toplevel']).trim();
  const w = listWorktrees(repo).find((x) => x.name === arg); if (w) return w.path;
  if (path.isAbsolute(arg) && fs.existsSync(arg)) return fs.realpathSync(arg);
  throw new Error(`no worktree "${arg}"`);
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const rest = process.argv.slice(2); const json = rest.includes('--json');
  const [cmd, arg] = rest.filter((a, i) => !a.startsWith('--') && rest[i - 1] !== '--out');
  try {
    if (cmd === 'manifest') { const i = rest.indexOf('--out'); console.log(writeManifest(REPO, i >= 0 ? rest[i + 1] : LIVE_FILE)); }
    else if (cmd === 'built') console.log(`built: ${markBuilt(resolveWorktree(arg))}`);
    else if (cmd === 'snapshot') {
      const wt = resolveWorktree(arg); const r = snapshot(wt);
      if (json) { console.log(JSON.stringify(snapshotReply(r, path.basename(wt)))); process.exit(r.ok ? 0 : 2); }   // one line for the hub; exit 2 = refused
      if (!r.ok) { console.error(`snapshot refused: ${r.reason}${r.path ? ` (${r.path})` : ''}`); process.exit(2); }
      console.log(`snapshot: ${r.ref} · ${r.files.length} files · ${r.state}\n${r.posted || ''}\n${r.readyLine}`);
    } else if (cmd === 'watch') {
      const run = () => { try { writeManifest(); } catch (e) { defaultLog({ event: 'live.manifest.skipped', reason: `error: ${e.message}` }); } };
      run(); const w = startWatcher({ onWake: run });
      for (const s of ['SIGTERM', 'SIGINT']) process.on(s, () => { w.close(); process.exit(0); });
      setInterval(() => {}, 1 << 30);   // keep the process alive; the watcher is event-driven, this timer never fires work
    } else { console.error('usage: livestate.mjs manifest [--out F] | watch | snapshot [--json] [WORKTREE] | built [WORKTREE]'); process.exit(64); }
  } catch (e) { console.error(`livestate: ${e.message}`); process.exit(1); }
}
