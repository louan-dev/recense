#!/usr/bin/env node
// ledger.mjs: a read-only observer of Apple's own iCloud client that turns a local folder into a
// content-addressed, append-only, hash-chained journal in any sink (R2 through rclone, or a plain
// directory such as the SanDisk).  Zero dependencies.  Node 18+.
//
// THE IDEA
//   Do not speak Apple's protocol.  The Mac's iCloud client (FileProvider / bird) already authenticates,
//   decrypts (Advanced Data Protection included) and syncs.  Treat the folder it maintains as the
//   *oracle*, observe it without ever writing to it, and publish what you see as an event log.  Every
//   other service then subscribes to the log instead of to Apple.  No Apple credentials, no 30-day
//   trust token, no private endpoint to break.  Apple's wire protocol can change; a folder cannot.
//
// WHAT A SYNC ENGINE SHOULD PRIORITIZE (ranked; the code is tagged P1..P10 where each is enforced)
//   P1  Truth over completeness.   A placeholder is not a backup. Evicted (dataless) files are reported,
//                                   never silently counted. A source that comes back empty is refused.
//   P2  Never write to the source. All source access is lstat / readdir / read-only streams.
//   P3  Immutable data, append-only history.  Objects are named by SHA-256. Deletes are events (tombstones).
//   P4  Hash what you copied.      Copy to staging while hashing, re-stat afterwards: no torn reads.
//   P5  Idempotent and resumable.  Objects, then journal segment, then local state. Re-run is always safe.
//   P6  Tamper evidence.           Every event carries a chain hash; `verify` finds edits and gaps.
//   P7  Conflicts are data.        iCloud's "name 2.ext" copies become `conflict` events, not errors.
//   P8  Ports and adapters.        Source = a folder. Sink = a directory or rclone remote. Views are derived.
//   P9  Observable.                `views/health.json` says when it last succeeded and what it skipped.
//   P10 Bounded blast radius.      Hard denylist for live app stores (Notability, Photos library, Messages).
//
// USAGE
//   node ledger.mjs run     --source DIR --sink SINK [--apply] [--quiet-secs 60] [--materialize]
//                           [--stage-dir DIR] [--origin NAME] [--allow-mass-delete]
//   node ledger.mjs watch   (same flags) [--every 300]
//   node ledger.mjs fold    --sink SINK [--at ISO] [--write]       current tree (or as of a time)
//   node ledger.mjs verify  --sink SINK [--deep]                    chains, objects, optional re-hash
//   node ledger.mjs restore --sink SINK --dest DIR [--at ISO]       rebuild a tree somewhere else
//   node ledger.mjs health  --sink SINK [--max-age-hours 24]          exit 1 when views/health.json is missing or stale
//   node ledger.mjs audit   [--root DIR] [--out AUDIT.md] [--baseline-dir DIR] [--top 50] [--dup-min BYTES]
//                           read-only: per-container bytes, dataless, largest, duplicates, dev junk
//   node ledger.mjs backup-status [--dest ARQ_DEST] [--source DIR --restored DIR] [--max-age-hours 26]
//                           read-only: last write, snapshot count, sha256 check of a sample restored with Arq
//   node ledger.mjs quota   [--total 5GB] [--target 60] [--alert 80] [--write]   iCloud usage from `brctl quota`
//   node ledger.mjs overflow --source DIR [--sink SINK] [--max-mb 25] [--total 5GB] [--alert 80] [--target 60] [--json]
//                           read-only plan: large files that should live in R2, and whether the sink already has them
//   node ledger.mjs selftest
//   SINK is a directory path, or  rclone:REMOTE:PATH  (e.g. rclone:gallery-main:ledger/icloud).
//   Without --apply, `run` reads and reports but writes nothing.

import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { pipeline } from 'node:stream/promises';
import { spawnSync } from 'node:child_process';

// ------------------------------------------------------------------ constants

const V = 1;
const SF_DATALESS = 0x40000000; // st_flags bit for FileProvider placeholders (macOS sys/stat.h; verify on your OS)

// P10: live stores of other apps. Never read, whichever folder you point us at.
const DENY = [
  /gingerlabs~Notability/i,                 // Notability's iCloud container is a live mirror of its sync state
  /\.photoslibrary(\/|$)/i,                 // export originals instead; never walk the bundle
  /\/Library\/Messages(\/|$)/,              // copy chat.db first, then point at the copy
  /\/Library\/Mail(\/|$)/,
  /\/Library\/Group Containers\/group\.com\.apple\.notes/i,
];
// Noise that would churn the journal without meaning.
const IGNORE = [
  /(^|\/)\.DS_Store$/, /(^|\/)\._/, /(^|\/)\.Trash/, /(^|\/)\.localized$/, /(^|\/)Thumbs\.db$/i,
  /(^|\/)desktop\.ini$/i, /(^|\/)~\$/, /(^|\/)\.obsidian\/workspace(-mobile)?\.json$/, /(^|\/)\.obsidian\/cache$/,
];
const PROTECTED = []; // roots we have promised never to write inside

// ------------------------------------------------------------------ small helpers

const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');
const objKey = (h) => `objects/${h.slice(0, 2)}/${h}`;
const nfc = (s) => s.normalize('NFC');
const iso = (ms) => new Date(ms).toISOString();

function assertWritable(p) { // P2: the one gate every local write passes through
  const r = path.resolve(p);
  if (/Mobile Documents/.test(r) || DENY.some((rx) => rx.test(r))) throw new Error(`refusing to write inside an iCloud/app store: ${r}`);
  for (const root of PROTECTED) if (r === root || r.startsWith(root + path.sep)) throw new Error(`refusing to write inside the source: ${r}`);
  return r;
}

function parseArgs(argv) {
  const a = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const x = argv[i];
    if (x.startsWith('--')) {
      const n = argv[i + 1];
      if (n === undefined || n.startsWith('--')) a[x.slice(2)] = true; else { a[x.slice(2)] = n; i++; }
    } else a._.push(x);
  }
  return a;
}

// ------------------------------------------------------------------ sinks (P8)

class LocalDirSink {
  constructor(dir) { this.root = path.resolve(dir); this.name = `dir:${this.root}`; }
  p(key) { return path.join(this.root, ...key.split('/')); }
  async list(prefix) {
    const out = new Map();
    const base = this.p(prefix);
    const walk = async (d, rel) => {
      let ents; try { ents = await fsp.readdir(d, { withFileTypes: true }); } catch { return; }
      for (const e of ents) {
        const r = rel ? `${rel}/${e.name}` : e.name;
        if (e.isDirectory()) await walk(path.join(d, e.name), r);
        else if (e.isFile() && !e.name.endsWith('.part') && !e.name.startsWith('._')) out.set(`${prefix}/${r}`, (await fsp.stat(path.join(d, e.name))).size);
      }
    };
    await walk(base, '');
    return out;
  }
  async putFile(local, key) { // atomic: write beside, then rename
    const dst = this.p(key); await fsp.mkdir(path.dirname(dst), { recursive: true });
    const tmp = `${dst}.${crypto.randomBytes(4).toString('hex')}.part`;
    await pipeline(fs.createReadStream(local), fs.createWriteStream(tmp, { flags: 'wx' })); await fsp.rename(tmp, dst); // bytes only: copyfile(3) also copies xattrs, which hangs exFAT under FSKit
  }
  async putText(key, text) {
    const dst = this.p(key); await fsp.mkdir(path.dirname(dst), { recursive: true });
    const tmp = `${dst}.${crypto.randomBytes(4).toString('hex')}.part`;
    await fsp.writeFile(tmp, text); await fsp.rename(tmp, dst);
  }
  async getText(key) { return fsp.readFile(this.p(key), 'utf8'); }
  async getFile(key, dest) { await fsp.mkdir(path.dirname(dest), { recursive: true }); await pipeline(fs.createReadStream(this.p(key)), fs.createWriteStream(dest)); }
}

class RcloneSink {
  constructor(base) { this.base = base; this.name = `rclone:${base}`; }
  r(key) { return this.base.endsWith(':') || this.base.endsWith('/') ? this.base + key : `${this.base}/${key}`; }
  sh(args, input) {
    const res = spawnSync('rclone', args, { input, encoding: 'utf8', maxBuffer: 1 << 28 });
    if (res.error) throw new Error(`rclone not runnable: ${res.error.message}`);
    return res;
  }
  async list(prefix) {
    const res = this.sh(['lsf', '-R', '--files-only', '--format', 'sp', '--separator', '|', this.r(prefix)]);
    const out = new Map();
    if (res.status === 3) return out; // directory not found = empty
    if (res.status !== 0) throw new Error(`rclone lsf failed: ${res.stderr}`);
    for (const line of res.stdout.split('\n')) { if (!line) continue; const i = line.indexOf('|'); out.set(`${prefix}/${line.slice(i + 1)}`, Number(line.slice(0, i))); }
    return out;
  }
  async putFile(local, key) { const r = this.sh(['copyto', '--immutable', local, this.r(key)]); if (r.status !== 0) throw new Error(`rclone copyto failed: ${r.stderr}`); }
  async putText(key, text) { const r = this.sh(['rcat', this.r(key)], text); if (r.status !== 0) throw new Error(`rclone rcat failed: ${r.stderr}`); }
  async getText(key) { const r = this.sh(['cat', this.r(key)]); if (r.status !== 0) throw new Error(`rclone cat failed: ${r.stderr}`); return r.stdout; }
  async getFile(key, dest) { await fsp.mkdir(path.dirname(dest), { recursive: true }); const r = this.sh(['copyto', this.r(key), dest]); if (r.status !== 0) throw new Error(`rclone copyto failed: ${r.stderr}`); }
}

function volumeOf(p) { const m = /^\/Volumes\/([^/]+)/.exec(path.resolve(p)); return m ? `/Volumes/${m[1]}` : null; }
function openSink(spec) {
  if (!spec || spec === true) throw new Error('--sink is required');
  const vol = spec.startsWith('rclone:') ? null : volumeOf(spec); // an unplugged drive must fail loudly, never fall back to the internal disk
  if (vol && !fs.existsSync(vol)) throw new Error(`sink volume not mounted: ${vol}`);
  return spec.startsWith('rclone:') ? new RcloneSink(spec.slice(7)) : new LocalDirSink(spec);
}

// ------------------------------------------------------------------ source observation (P1, P2, P10)

function checkSource(dir) {
  if (!dir || dir === true) throw new Error('--source is required');
  const real = fs.realpathSync(dir);
  if (!fs.statSync(real).isDirectory()) throw new Error(`not a directory: ${real}`);
  if (DENY.some((rx) => rx.test(real + '/'))) throw new Error(`denied: ${real} is a live app store (see DENY). Copy it elsewhere first, or use the app's own export.`);
  PROTECTED.push(real);
  return real;
}

function isEvicted(st, full) { // P1: a dataless placeholder has a size but no data blocks
  if (!(st.size > 0 && st.blocks === 0)) return false;
  if (process.platform === 'darwin') {
    const r = spawnSync('stat', ['-f', '%f', full], { encoding: 'utf8' });
    const flags = parseInt(r.stdout, 10);
    if (r.status === 0 && Number.isFinite(flags)) return (flags & SF_DATALESS) !== 0;
  }
  return true; // cannot confirm: treat as evicted (safe: it is reported and skipped, never trusted)
}

async function* walk(root, rel = '', counts) {
  const full = path.join(root, rel);
  let ents; ents = await fsp.readdir(full, { withFileTypes: true }); // throws if unreadable: abort the run, never guess
  ents.sort((a, b) => (a.name < b.name ? -1 : 1));
  for (const e of ents) {
    const r = rel ? `${rel}/${e.name}` : e.name;
    const f = path.join(root, r);
    if (DENY.some((rx) => rx.test(f + '/'))) { counts.denied++; continue; }
    const legacy = /^\.(.+)\.icloud$/.exec(e.name); // pre-FileProvider placeholder: ".name.icloud"
    if (legacy && e.isFile()) { yield { kind: 'placeholder', rel: rel ? `${rel}/${legacy[1]}` : legacy[1], full: f }; continue; }
    if (IGNORE.some((rx) => rx.test(r))) continue;
    if (e.isSymbolicLink()) { counts.symlinks++; continue; }
    if (e.isDirectory()) { yield* walk(root, r, counts); continue; }
    if (e.isFile()) yield { kind: 'file', rel: r, full: f };
  }
}

// P4: copy to staging while hashing; the hash is of exactly the bytes we hold.
async function stage(src, dir) {
  await fsp.mkdir(dir, { recursive: true });
  const tmp = path.join(dir, `stage-${crypto.randomBytes(8).toString('hex')}`);
  const h = crypto.createHash('sha256'); let size = 0;
  const inp = fs.createReadStream(src); // flags 'r': read-only
  inp.on('data', (c) => { h.update(c); size += c.length; });
  await pipeline(inp, fs.createWriteStream(tmp, { flags: 'wx' }));
  return { tmp, hash: h.digest('hex'), size };
}

// ------------------------------------------------------------------ state (local only, outside the source)

function defaultStatePath(source, sinkName) { return path.join(os.homedir(), '.ledger', `state-${sha256(`${source}\n${sinkName}`).slice(0, 10)}.json`); } // one per source×sink: a second sink must not inherit the first one's 'unchanged'
function loadState(file) {
  try { const s = JSON.parse(fs.readFileSync(file, 'utf8')); if (s.v === V) return s; } catch { /* first run */ }
  return { v: V, chain: sha256('genesis'), seq: 0, files: {}, conflicts: {} };
}
function saveState(file, s) { // atomic
  assertWritable(file); fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`; fs.writeFileSync(tmp, JSON.stringify(s)); fs.renameSync(tmp, file);
}

// ------------------------------------------------------------------ run

export async function run(o) {
  const log = o.log || ((...a) => console.log(...a));
  const now = o.now || Date.now;
  const quietMs = (o.quietSecs ?? 60) * 1000;
  const source = checkSource(o.source);
  const sink = o.sink;
  if (sink.root) assertWritable(sink.root);
  const stateFile = o.state || defaultStatePath(source, sink.name);
  const state = loadState(stateFile);
  const known = await sink.list('objects'); // what the sink already holds (dedup across everything it has ever seen)

  const counts = { files: 0, unchanged: 0, changed: 0, uploaded: 0, bytes: 0, deferred: 0, evicted: 0, unstable: 0, denied: 0, symlinks: 0, tombstones: 0, conflicts: 0 };
  const events = []; const next = {}; const seen = new Set(); const live = new Set();
  const stageDir = o.stageDir ? assertWritable(o.stageDir) : path.join(os.tmpdir(), 'ledger-stage');

  for await (const it of walk(source, '', counts)) {
    const key = nfc(it.rel); seen.add(key); const prev = state.files[key];
    if (it.kind === 'placeholder') { // legacy stub: report once, keep what we knew
      counts.evicted++; next[key] = prev ? { ...prev, evicted: true } : { evicted: true };
      if (!prev || !prev.evicted) events.push({ op: 'skip', path: key, reason: 'evicted' });
      continue;
    }
    const st = await fsp.lstat(it.full); counts.files++;
    if (isEvicted(st, it.full) && !o.materialize) { // P1
      counts.evicted++; next[key] = prev ? { ...prev, evicted: true } : { size: st.size, mtimeMs: st.mtimeMs, evicted: true };
      if (!prev || !prev.evicted) events.push({ op: 'skip', path: key, reason: 'evicted', size: st.size });
      continue;
    }
    if (now() - st.mtimeMs < quietMs) { counts.deferred++; if (prev) next[key] = prev; continue; } // still being written
    if (prev && prev.hash && !prev.evicted && prev.size === st.size && prev.mtimeMs === st.mtimeMs) {
      counts.unchanged++; next[key] = prev; live.add(key); continue; // P5: cheap incremental scan, no re-hash
    }
    counts.changed++;
    if (!o.apply) { if (prev) next[key] = prev; continue; } // dry run: report only
    const r = await stage(it.full, stageDir);
    const st2 = await fsp.lstat(it.full);
    if (st2.mtimeMs !== st.mtimeMs || st2.size !== st.size || r.size !== st.size) { // P4: changed mid-copy
      await fsp.rm(r.tmp, { force: true }); counts.unstable++; if (prev) next[key] = prev; continue;
    }
    const ok = objKey(r.hash);
    if (!known.has(ok)) { await sink.putFile(r.tmp, ok); known.set(ok, r.size); counts.uploaded++; counts.bytes += r.size; }
    await fsp.rm(r.tmp, { force: true });
    next[key] = { size: r.size, mtimeMs: st.mtimeMs, hash: r.hash }; live.add(key);
    if (!prev || prev.hash !== r.hash) events.push({ op: 'put', path: key, hash: r.hash, size: r.size, mtimeMs: Math.round(st.mtimeMs), prev: prev?.hash ?? null });
  }

  // P1: a source that suddenly lacks most of what we knew is a broken mount, not a mass deletion.
  const vanished = Object.keys(state.files).filter((k) => !seen.has(k));
  const knownCount = Object.keys(state.files).length;
  if (!o.allowMassDelete && knownCount >= 10 && vanished.length > Math.max(10, knownCount * 0.2)) {
    throw new Error(`refusing: ${vanished.length} of ${knownCount} known files vanished at once (empty mount?). Re-run with --allow-mass-delete if this is real.`);
  }
  for (const k of vanished) { // P3: deletion is an event, never an erasure
    const p = state.files[k];
    if (p.hash) { events.push({ op: 'tombstone', path: k, prev: p.hash }); counts.tombstones++; }
  }

  // P7: iCloud's conflict copies ("Report 2.docx" beside "Report.docx") recorded as data. Heuristic by name.
  if (o.apply) {
    for (const k of Object.keys(next)) {
      const dir = k.includes('/') ? k.slice(0, k.lastIndexOf('/') + 1) : ''; const base = k.slice(dir.length);
      const m = /^(.*) (\d+)(\.[^.]+)?$/.exec(base); if (!m) continue;
      const orig = dir + m[1] + (m[3] || '');
      if (!next[orig]?.hash || !next[k]?.hash || next[orig].hash === next[k].hash) continue;
      const id = `${k}|${next[k].hash}|${next[orig].hash}`;
      if (state.conflicts[id]) continue;
      state.conflicts[id] = 1; counts.conflicts++;
      events.push({ op: 'conflict', path: k, of: orig, hash: next[k].hash, ofHash: next[orig].hash, heuristic: true });
    }
  }

  log(`${o.apply ? 'apply' : 'dry-run'}: ${JSON.stringify(counts)}`);
  if (!o.apply) return { counts, events: [] };

  // P5: objects are already in the sink. Now the journal segment, then local state. Crash-safe in that order.
  let chain = state.chain, seq = state.seq;
  if (events.length) {
    const ts = iso(now());
    const header = { v: V, type: 'segment', ts, origin: o.origin || os.hostname(), prevChain: chain };
    const lines = [JSON.stringify(header)];
    for (const e of events) { // P6
      const ev = { v: V, seq: ++seq, ts, ...e, origin: header.origin };
      chain = sha256(`${chain}\n${JSON.stringify(ev)}`);
      lines.push(JSON.stringify({ ...ev, chain }));
    }
    const name = `journal/${ts.replace(/[-:.]/g, '')}-${crypto.randomBytes(2).toString('hex')}.jsonl`;
    await sink.putText(name, lines.join('\n') + '\n');
    log(`journal: ${events.length} event(s) -> ${name}`);
  }
  saveState(stateFile, { v: V, chain, seq, files: next, conflicts: state.conflicts });
  await sink.putText('views/health.json', JSON.stringify({ // P9
    v: V, lastOk: iso(now()), source: path.basename(source), origin: o.origin || os.hostname(), head: chain, seq, counts,
  }, null, 2));
  return { counts, events };
}

// ------------------------------------------------------------------ journal reading, folding, verifying

export async function readJournal(sink) {
  const names = [...(await sink.list('journal')).keys()].filter((k) => k.endsWith('.jsonl')).sort();
  const segs = [];
  for (const n of names) {
    const rows = (await sink.getText(n)).split('\n').filter(Boolean).map((l) => JSON.parse(l));
    segs.push({ name: n, header: rows[0], events: rows.slice(1) });
  }
  return segs;
}

export function fold(segs, atMs = Infinity) { // the current tree, or the tree as it was at a moment
  const tree = new Map();
  for (const s of segs) for (const e of s.events) {
    if (Date.parse(e.ts) > atMs) continue;
    if (e.op === 'put') tree.set(e.path, { hash: e.hash, size: e.size, mtimeMs: e.mtimeMs });
    else if (e.op === 'tombstone') tree.delete(e.path);
  }
  return tree;
}

export async function verify(sink, { deep = false, log = console.log } = {}) {
  const segs = await readJournal(sink); const problems = []; const starts = new Map();
  for (const s of segs) {
    let c = s.header.prevChain; starts.set(c, (starts.get(c) || 0) + 1);
    for (const e of s.events) {
      const { chain, ...rest } = e;
      if (sha256(`${c}\n${JSON.stringify(rest)}`) !== chain) { problems.push(`chain broken in ${s.name} at seq ${e.seq}`); break; }
      c = chain;
    }
  }
  const forks = [...starts.values()].filter((n) => n > 1).length; // a crash between journal and state can fork; harmless, reported
  const tree = fold(segs); const objs = await sink.list('objects'); const seenH = new Set();
  for (const [p, m] of tree) {
    const k = objKey(m.hash);
    if (!objs.has(k)) problems.push(`missing object for ${p}`);
    else if (objs.get(k) !== m.size) problems.push(`size mismatch for ${p}`);
    else if (deep && !seenH.has(m.hash)) {
      seenH.add(m.hash); const tmp = path.join(os.tmpdir(), `ledger-verify-${crypto.randomBytes(4).toString('hex')}`);
      await sink.getFile(k, tmp); const h = sha256(await fsp.readFile(tmp)); await fsp.rm(tmp, { force: true });
      if (h !== m.hash) problems.push(`content hash mismatch for ${p}`);
    }
  }
  log(`verify: ${segs.length} segment(s), ${tree.size} live file(s), ${forks} fork(s), ${problems.length} problem(s)`);
  for (const p of problems) log(`  ! ${p}`);
  return { ok: problems.length === 0, problems, forks };
}

export async function restore({ sink, dest, atMs = Infinity, log = console.log }) {
  const root = assertWritable(dest);
  if (fs.existsSync(root) && fs.readdirSync(root).length) throw new Error(`destination not empty: ${root}`);
  const tree = fold(await readJournal(sink), atMs); let n = 0;
  for (const [p, m] of tree) {
    const out = path.resolve(root, ...p.split('/'));
    if (out !== root && !out.startsWith(root + path.sep)) throw new Error(`unsafe path in journal: ${p}`); // tampered log
    await sink.getFile(objKey(m.hash), out);
    if (sha256(await fsp.readFile(out)) !== m.hash) throw new Error(`restored content does not match its hash: ${p}`);
    if (m.mtimeMs) await fsp.utimes(out, new Date(), new Date(m.mtimeMs));
    n++;
  }
  log(`restored ${n} file(s) to ${root}`);
  return n;
}

// ------------------------------------------------------------------ audit (read-only; where the iCloud bytes are)

const JUNK = new Set(['node_modules', '.build', 'DerivedData', 'Pods', '.venv', '__pycache__']);
const fmtB = (n) => { const u = ['B', 'KB', 'MB', 'GB', 'TB']; let i = 0; while (n >= 1000 && i < u.length - 1) { n /= 1000; i++; } return `${n.toFixed(i ? 1 : 0)} ${u[i]}`; };

function confirmDataless(files) { // one `stat` per 200 paths instead of one per file
  const out = new Set();
  if (process.platform !== 'darwin') { for (const f of files) out.add(f); return out; }
  for (let i = 0; i < files.length; i += 200) {
    const chunk = files.slice(i, i + 200);
    const r = spawnSync('stat', ['-f', '%f', ...chunk], { encoding: 'utf8', maxBuffer: 1 << 24 });
    const lines = (r.stdout || '').split('\n');
    chunk.forEach((f, j) => { const fl = parseInt(lines[j], 10); if (!Number.isFinite(fl) || (fl & SF_DATALESS)) out.add(f); }); // unknown = evicted (P1)
  }
  return out;
}

async function hashFile(f) { const h = crypto.createHash('sha256'); await pipeline(fs.createReadStream(f), h); return h.digest('hex'); }

export async function audit(o = {}) {
  const log = o.log || console.log;
  const root = fs.realpathSync(o.root || path.join(os.homedir(), 'Library', 'Mobile Documents'));
  const dupMin = o.dupMin ?? 1 << 20; const topN = o.top ?? 50;
  const groups = new Map(); const files = []; const junk = new Map(); const denied = []; const unreadable = [];
  const g = (name) => { if (!groups.has(name)) groups.set(name, { name, files: 0, apparent: 0, onDisk: 0, dataless: 0, datalessBytes: 0, junkBytes: 0 }); return groups.get(name); };
  const groupOf = (rel) => { const p = rel.split('/'); return p[0] === 'com~apple~CloudDocs' && p.length > 2 ? `iCloud Drive/${p[1]}` : p[0] === 'com~apple~CloudDocs' ? 'iCloud Drive/(root)' : p[0]; };

  const walkA = async (rel, junkRoot) => {
    const full = path.join(root, rel);
    if (DENY.some((rx) => rx.test(full + '/'))) { denied.push(rel); return; } // P10: not even readdir
    let ents; try { ents = await fsp.readdir(full, { withFileTypes: true }); } catch (e) { unreadable.push(`${rel}: ${e.code}`); return; }
    for (const e of ents) {
      const r = rel ? `${rel}/${e.name}` : e.name; const f = path.join(root, r);
      if (e.isSymbolicLink()) continue;
      if (e.isDirectory()) { await walkA(r, junkRoot ?? (JUNK.has(e.name) ? r : undefined)); continue; }
      if (!e.isFile()) continue;
      const legacy = /^\.(.+)\.icloud$/.exec(e.name);
      let st; try { st = await fsp.lstat(f); } catch { continue; }
      if (legacy) { const c = g(groupOf(r)); c.files++; c.dataless++; continue; } // size unknown without parsing the stub
      files.push({ rel: r, full: f, size: st.size, onDisk: st.blocks * 512, zero: st.size > 0 && st.blocks === 0, junkRoot });
    }
  };
  if (!rel0Ok(root)) throw new Error(`not a directory: ${root}`);
  await walkA('', undefined);

  const dl = confirmDataless(files.filter((x) => x.zero).map((x) => x.full));
  for (const x of files) {
    x.dataless = dl.has(x.full); const c = g(groupOf(x.rel));
    c.files++; c.apparent += x.size; c.onDisk += x.onDisk; if (x.dataless) { c.dataless++; c.datalessBytes += x.size; }
    if (x.junkRoot) { c.junkBytes += x.size; junk.set(x.junkRoot, (junk.get(x.junkRoot) || 0) + x.size); }
  }

  // duplicates: same size first, then sha256 of local (non-dataless) copies only; never forces a download
  const bySize = new Map();
  for (const x of files) if (!x.dataless && x.size >= dupMin) { const a = bySize.get(x.size) || []; a.push(x); bySize.set(x.size, a); }
  const dups = []; let hashed = 0;
  for (const [size, xs] of bySize) {
    if (xs.length < 2) continue;
    const byHash = new Map();
    for (const x of xs) { let h; try { h = await hashFile(x.full); hashed++; } catch { continue; } const a = byHash.get(h) || []; a.push(x.rel); byHash.set(h, a); }
    for (const [h, rels] of byHash) if (rels.length > 1) dups.push({ size, hash: h, copies: rels.length, wasted: size * (rels.length - 1), paths: rels });
  }
  dups.sort((a, b) => b.wasted - a.wasted);

  const quota = spawnSync('brctl', ['quota'], { encoding: 'utf8' });
  const qm = /(\d+) bytes of quota remaining/.exec(quota.stdout || '');
  const tot = [...groups.values()].reduce((t, c) => ({ files: t.files + c.files, apparent: t.apparent + c.apparent, onDisk: t.onDisk + c.onDisk, dataless: t.dataless + c.dataless, datalessBytes: t.datalessBytes + c.datalessBytes }), { files: 0, apparent: 0, onDisk: 0, dataless: 0, datalessBytes: 0 });
  const largest = [...files].sort((a, b) => b.size - a.size).slice(0, topN).map((x) => ({ path: x.rel, size: x.size, dataless: x.dataless }));
  const junkList = [...junk].map(([p, b]) => ({ path: p, bytes: b })).sort((a, b) => b.bytes - a.bytes);
  const doc = {
    v: V, generated: iso(Date.now()), root, quotaRemaining: qm ? Number(qm[1]) : null, totals: tot,
    groups: [...groups.values()].sort((a, b) => b.apparent - a.apparent), largest, duplicates: dups, junk: junkList,
    denied, unreadable, hashedForDuplicates: hashed, dupMinBytes: dupMin,
  };

  // baseline: counts only live outside the repo (paths can be private); previous one gives a delta
  const bdir = assertWritable(o.baselineDir || path.join(os.homedir(), '.ledger', 'audit'));
  await fsp.mkdir(bdir, { recursive: true });
  let prev = null; try { prev = JSON.parse(await fsp.readFile(path.join(bdir, 'latest.json'), 'utf8')); } catch { /* first audit */ }
  const stamp = doc.generated.replace(/[-:.]/g, '');
  await fsp.writeFile(path.join(bdir, `audit-${stamp}.json`), JSON.stringify(doc, null, 2));
  await fsp.writeFile(path.join(bdir, 'latest.json'), JSON.stringify(doc, null, 2));

  const L = [];
  L.push(`# AUDIT.md · iCloud containers on this Mac · ${doc.generated}`, '');
  L.push(`Read-only scan of \`${root}\` by \`node ledger.mjs audit\`. Denied (never opened): ${denied.length ? denied.map((d) => `\`${d}\``).join(', ') : 'none'}. Full detail: \`${path.join(bdir, `audit-${stamp}.json`)}\`.`, '');
  L.push(`- **Quota remaining (\`brctl quota\`):** ${qm ? fmtB(Number(qm[1])) : 'unavailable'}`);
  L.push(`- **Local containers:** ${tot.files} files, ${fmtB(tot.apparent)} apparent, ${fmtB(tot.onDisk)} on this disk; ${tot.dataless} dataless placeholders (${fmtB(tot.datalessBytes)} only in the cloud)`);
  if (prev) L.push(`- **Since ${prev.generated}:** apparent ${fmtB(tot.apparent - prev.totals.apparent)} (signed bytes: ${tot.apparent - prev.totals.apparent}), files ${tot.files - prev.totals.files}`);
  L.push(`- Not visible here but counted by Apple: Photos, device Backups, Messages, Mail, app data in CloudKit (not in Mobile Documents). The owner's storage breakdown screenshot is the only source for those.`, '');
  L.push('| Container / Drive folder | Files | Apparent | On disk | Dataless | Dev junk |', '|---|--:|--:|--:|--:|--:|');
  for (const c of doc.groups.slice(0, 15)) L.push(`| \`${c.name}\` | ${c.files} | ${fmtB(c.apparent)} | ${fmtB(c.onDisk)} | ${c.dataless} (${fmtB(c.datalessBytes)}) | ${c.junkBytes ? fmtB(c.junkBytes) : '–'} |`);
  if (doc.groups.length > 15) { const rest = doc.groups.slice(15); L.push(`| ${rest.length} others | ${rest.reduce((t, c) => t + c.files, 0)} | ${fmtB(rest.reduce((t, c) => t + c.apparent, 0))} | ${fmtB(rest.reduce((t, c) => t + c.onDisk, 0))} | | |`); }
  L.push('', `**Largest files** (top 10 of ${largest.length} in the JSON; ☁ = dataless):`);
  for (const x of largest.slice(0, 10)) L.push(`- ${fmtB(x.size)} ${x.dataless ? '☁ ' : ''}\`${x.path}\``);
  L.push('', `**Duplicates** (≥${fmtB(dupMin)}, local copies, sha256): ${dups.length} sets, ${fmtB(dups.reduce((t, d) => t + d.wasted, 0))} redundant${dups.length ? '; top:' : '.'}`);
  for (const d of dups.slice(0, 5)) L.push(`- ${d.copies}× ${fmtB(d.size)}: ${d.paths.slice(0, 3).map((p) => `\`${p}\``).join(', ')}${d.paths.length > 3 ? ' …' : ''}`);
  L.push('', `**Dev junk inside iCloud** (${JUNK.size} dir names): ${junkList.length ? fmtB(junkList.reduce((t, j) => t + j.bytes, 0)) : 'none'}`);
  for (const j of junkList.slice(0, 5)) L.push(`- ${fmtB(j.bytes)} \`${j.path}\``);
  if (unreadable.length) L.push('', `Unreadable: ${unreadable.length} (e.g. \`${unreadable[0]}\`).`);
  const md = L.join('\n') + '\n';
  if (o.out) { await fsp.writeFile(assertWritable(o.out), md); log(`wrote ${o.out} and ${path.join(bdir, 'latest.json')}`); } else log(md);
  return doc;
}
function rel0Ok(root) { try { return fs.statSync(root).isDirectory(); } catch { return false; } }

// ------------------------------------------------------------------ backup-status (read-only; is the Arq copy real?)

export async function backupStatus(o = {}) {
  const log = o.log || console.log; const now = o.now || Date.now;
  const statusFile = assertWritable(o.statusFile || path.join(os.homedir(), '.ledger', 'backup-status.json'));
  let prev = {}; try { prev = JSON.parse(await fsp.readFile(statusFile, 'utf8')); } catch { /* first check */ }
  const out = { v: V, checked: iso(now()), dest: null, lastWrite: null, snapshots: null, restore: prev.restore || null, problems: [] };

  if (o.dest) { // last write and snapshot count from the destination tree (Arq 7: one *.backuprecord per snapshot per folder)
    const dest = fs.realpathSync(o.dest); out.dest = dest; let newest = 0, records = 0, files = 0;
    const w = async (d) => { for (const e of await fsp.readdir(d, { withFileTypes: true })) {
      const f = path.join(d, e.name);
      if (e.isDirectory()) await w(f); else if (e.isFile()) { files++; const st = await fsp.stat(f); if (st.mtimeMs > newest) newest = st.mtimeMs; if (e.name.endsWith('.backuprecord')) records++; }
    } };
    await w(dest);
    out.lastWrite = newest ? iso(newest) : null; out.snapshots = records || null; out.destFiles = files;
    if (!files) out.problems.push('destination is empty');
    else if (now() - newest > (o.maxAgeHours ?? 26) * 3600_000) out.problems.push(`no write to the destination for more than ${o.maxAgeHours ?? 26} h`);
    if (files && !records) out.note = 'no *.backuprecord files (Arq 5 layout): snapshot count unknown; the restore drill is the proof';
  }

  if (o.restored) { // a sample the owner restored with Arq into a scratch dir, compared byte-for-byte with the source
    if (!o.source) throw new Error('--restored needs --source (the original folder the sample came from)');
    const src = fs.realpathSync(o.source); const rd = fs.realpathSync(o.restored);
    let checked = 0, matched = 0, skipped = 0; const bad = [];
    const w = async (rel) => { for (const e of await fsp.readdir(path.join(rd, rel), { withFileTypes: true })) {
      const r = rel ? `${rel}/${e.name}` : e.name;
      if (e.isDirectory()) { await w(r); continue; } if (!e.isFile() || IGNORE.some((rx) => rx.test(r))) continue;
      const orig = path.join(src, r); let st; try { st = await fsp.lstat(orig); } catch { bad.push(`${r}: missing in source`); continue; }
      if (isEvicted(st, orig)) { skipped++; continue; } // never force a download to compare
      checked++;
      if ((await hashFile(path.join(rd, r))) === (await hashFile(orig))) matched++; else bad.push(`${r}: sha256 differs (source may have changed since the snapshot)`);
    } };
    await w('');
    out.restore = { at: iso(now()), source: src, restored: rd, checked, matched, skipped, mismatches: bad.slice(0, 20), ok: checked > 0 && bad.length === 0 };
    if (!checked) out.problems.push('restore sample had no comparable files');
  }
  if (out.restore && !out.restore.ok) out.problems.push('last restore drill did not verify');
  if (!out.restore) out.problems.push('no restore drill recorded yet');
  out.ok = out.problems.length === 0;
  await fsp.mkdir(path.dirname(statusFile), { recursive: true });
  const tmp = `${statusFile}.${process.pid}.tmp`; await fsp.writeFile(tmp, JSON.stringify(out, null, 2)); await fsp.rename(tmp, statusFile);
  log(`backup-status: ${out.ok ? 'OK' : 'NOT OK'}; last write ${out.lastWrite ?? '–'}; snapshots ${out.snapshots ?? '–'}; restore ${out.restore ? `${out.restore.matched}/${out.restore.checked} match (${out.restore.at})` : '–'}`);
  for (const p of out.problems) log(`  ! ${p}`);
  return out;
}

// ------------------------------------------------------------------ quota (read-only; brctl reports bytes remaining, the plan size is config)

const parseBytes = (v) => { const m = /^([\d.]+)\s*(B|KB|MB|GB|TB)?$/i.exec(String(v).trim()); if (!m) throw new Error(`bad size: ${v}`); return Math.round(Number(m[1]) * 1000 ** ['B', 'KB', 'MB', 'GB', 'TB'].indexOf((m[2] || 'B').toUpperCase())); };

export function quota(o = {}) {
  const total = parseBytes(o.total ?? '5GB'); const alert = Number(o.alert ?? 80); const target = Number(o.target ?? 60);
  let remaining = o.remaining;
  if (remaining === undefined) { const r = spawnSync('brctl', ['quota'], { encoding: 'utf8' }); const m = /(\d+) bytes of quota remaining/.exec(r.stdout || ''); if (!m) throw new Error('brctl quota gave no number'); remaining = Number(m[1]); }
  const usedPct = Math.round(((total - remaining) / total) * 1000) / 10;
  const level = remaining > total ? 'inconsistent' : usedPct >= alert ? 'alert' : usedPct > target ? 'over-target' : 'ok';
  return { v: V, checked: iso(Date.now()), total, remaining, usedPct, target, alert, level };
}

// ------------------------------------------------------------------ health (P9: is the mirror fresh?)

export async function health(sink, { maxAgeHours = 24, now = Date.now, log = console.log } = {}) {
  let h; try { h = JSON.parse(await sink.getText('views/health.json')); } catch { log(`health: no views/health.json in ${sink.name}`); return { ok: false, reason: 'missing' }; }
  const ageH = (now() - Date.parse(h.lastOk)) / 3600_000; const ok = ageH <= maxAgeHours;
  log(`health: ${ok ? 'OK' : 'STALE'}; lastOk ${h.lastOk} (${ageH.toFixed(1)} h ago); evicted ${h.counts?.evicted ?? '?'}, unstable ${h.counts?.unstable ?? '?'}`);
  return { ok, ageH, lastOk: h.lastOk, reason: ok ? null : 'stale' };
}

// ------------------------------------------------------------------ overflow (read-only plan: what should leave iCloud for R2)
// Rule: a local file > maxMB is a candidate. When iCloud usage ≥ alert%, take candidates largest-first until projected
// usage ≤ target%. A candidate is "ready" only when the sink already holds its exact bytes (sha256). Moving it out and
// leaving a pointer note is the owner's step; this command never writes to the source.

export async function overflow(o = {}) {
  const log = o.log || console.log;
  const source = fs.realpathSync(o.source); const maxBytes = (o.maxMB ?? 25) * 1e6;
  const q = o.quota ?? quota({ total: o.total, alert: o.alert, target: o.target });
  const sink = o.sink ? openSink(o.sink) : null; const objs = sink ? await sink.list('objects') : new Map();
  const counts = { denied: 0, symlinks: 0 }; const cands = [];
  for await (const it of walk(source, '', counts)) {
    if (it.kind !== 'file' || /(^|\/)\.obsidian\//.test(it.rel)) continue; // app config/plugins must stay where the app loads them
    const st = await fsp.lstat(it.full); if (st.size <= maxBytes) continue;
    const dataless = isEvicted(st, it.full);
    const hash = dataless ? null : await hashFile(it.full); // never forces a download
    cands.push({ path: nfc(it.rel), size: st.size, dataless, hash, ready: !!hash && objs.has(objKey(hash)) });
  }
  cands.sort((a, b) => b.size - a.size);
  const pressure = q.level === 'alert'; const needBytes = pressure ? Math.max(0, (q.total - q.remaining) - q.total * q.target / 100) : 0;
  let picked = 0; for (const c of cands) { c.selected = !pressure || picked < needBytes; if (c.selected) picked += c.size; }
  const doc = { v: V, checked: iso(Date.now()), source, maxMB: maxBytes / 1e6, quota: q, pressure, needBytes, candidates: cands };
  log(`overflow: quota ${q.level} (${q.usedPct}% of ${fmtB(q.total)}); ${cands.length} file(s) > ${fmtB(maxBytes)}; ${cands.filter((c) => c.ready).length} ready (exact copy in sink)${pressure ? `; need ${fmtB(needBytes)} out` : ''}`);
  for (const c of cands.slice(0, 20)) log(`  ${c.ready ? 'ready ' : c.dataless ? 'cloud ' : 'nocopy'} ${c.selected ? '*' : ' '} ${fmtB(c.size).padStart(9)}  ${c.path}`);
  return doc;
}

export function pointerNote(c, sinkSpec) { // what stays in the vault once the owner moves the file out
  return `---\noverflow: ${JSON.stringify({ sink: sinkSpec, key: objKey(c.hash), sha256: c.hash, size: c.size, original: c.path })}\n---\n\n` +
    `**${path.basename(c.path)}** (${fmtB(c.size)}) lives in the overflow lane. Restore: \`node ledger.mjs restore --sink ${sinkSpec} --dest <dir>\`.\n`;
}

// ------------------------------------------------------------------ CLI

async function main() {
  const a = parseArgs(process.argv.slice(2)); const cmd = a._[0];
  const common = () => ({
    source: a.source, sink: openSink(a.sink), apply: !!a.apply, quietSecs: a['quiet-secs'] !== undefined ? Number(a['quiet-secs']) : 60,
    materialize: !!a.materialize, stageDir: a['stage-dir'], state: a.state, origin: a.origin, allowMassDelete: !!a['allow-mass-delete'],
  });
  if (cmd === 'run') { await run(common()); }
  else if (cmd === 'watch') {
    const o = common(); const every = Number(a.every || 300) * 1000; let busy = false, dirty = true;
    try { fs.watch(fs.realpathSync(o.source), { recursive: true }, () => { dirty = true; }); } catch { /* polling alone still works */ }
    setInterval(() => { dirty = true; }, every);
    setInterval(async () => { // fs.watch (FSEvents on macOS) only says "something changed"; the incremental scan does the rest
      if (busy || !dirty) return; dirty = false; busy = true;
      try { await run(o); } catch (e) { console.error(`ledger: ${e.message}`); } finally { busy = false; }
    }, 5000);
  }
  else if (cmd === 'fold') {
    const sink = openSink(a.sink); const tree = fold(await readJournal(sink), a.at ? Date.parse(a.at) : Infinity);
    const doc = { v: V, generated: iso(Date.now()), count: tree.size, files: Object.fromEntries(tree) };
    if (a.write) { await sink.putText('views/tree.json', JSON.stringify(doc, null, 2)); console.log(`wrote views/tree.json (${tree.size} files)`); }
    else console.log(JSON.stringify(doc, null, 2));
  }
  else if (cmd === 'verify') { const r = await verify(openSink(a.sink), { deep: !!a.deep }); process.exit(r.ok ? 0 : 1); }
  else if (cmd === 'restore') { await restore({ sink: openSink(a.sink), dest: a.dest, atMs: a.at ? Date.parse(a.at) : Infinity }); }
  else if (cmd === 'audit') { await audit({ root: a.root === true ? undefined : a.root, out: a.out === true ? undefined : a.out, baselineDir: a['baseline-dir'], top: a.top ? Number(a.top) : undefined, dupMin: a['dup-min'] ? Number(a['dup-min']) : undefined }); }
  else if (cmd === 'backup-status') { const r = await backupStatus({ dest: a.dest, source: a.source, restored: a.restored, statusFile: a['status-file'], maxAgeHours: a['max-age-hours'] ? Number(a['max-age-hours']) : undefined }); process.exit(r.ok ? 0 : 1); }
  else if (cmd === 'quota') { const q = quota({ total: a.total, alert: a.alert, target: a.target }); console.log(JSON.stringify(q)); if (a.write) { const f = assertWritable(path.join(os.homedir(), '.ledger', 'quota.json')); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, JSON.stringify(q, null, 2)); } process.exit(q.level === 'ok' ? 0 : 1); }
  else if (cmd === 'health') { const r = await health(openSink(a.sink), { maxAgeHours: a['max-age-hours'] ? Number(a['max-age-hours']) : 24 }); process.exit(r.ok ? 0 : 1); }
  else if (cmd === 'overflow') { const r = await overflow({ source: a.source, sink: a.sink, maxMB: a['max-mb'] ? Number(a['max-mb']) : undefined, total: a.total, alert: a.alert, target: a.target }); if (a.json) console.log(JSON.stringify(r, null, 2)); }
  else if (cmd === 'selftest') { await selftest(); }
  else { console.error('usage: node ledger.mjs run|watch|fold|verify|restore|health|audit|backup-status|quota|overflow|selftest  (see the header of this file)'); process.exit(64); }
}

// ------------------------------------------------------------------ selftest

async function selftest() {
  const assert = (c, m) => { if (!c) throw new Error(`FAIL: ${m}`); console.log(`  ok  ${m}`); };
  const tmp = await fsp.mkdtemp(path.join(os.tmpdir(), 'ledger-test-'));
  const src = path.join(tmp, 'vault'); const sinkDir = path.join(tmp, 'sink'); const stateFile = path.join(tmp, 'state.json');
  await fsp.mkdir(src, { recursive: true });
  let clock = Date.parse('2026-10-10T12:00:00Z'); const tick = (m = 60_000) => (clock += m);
  const old = new Date(clock - 3600_000);
  const put = async (rel, text) => { const f = path.join(src, rel); await fsp.mkdir(path.dirname(f), { recursive: true }); await fsp.writeFile(f, text); await fsp.utimes(f, old, old); };
  const sink = new LocalDirSink(sinkDir); const quiet = () => {};
  const go = (extra = {}) => run({ source: src, sink, state: stateFile, apply: true, quietSecs: 0, now: () => clock, log: quiet, ...extra });
  const snapshot = async () => { const out = []; const w = async (d) => { for (const e of await fsp.readdir(d, { withFileTypes: true })) { const f = path.join(d, e.name); if (e.isDirectory()) await w(f); else out.push(`${f}:${(await fsp.stat(f)).mtimeMs}:${sha256(await fsp.readFile(f))}`); } }; await w(src); return out.sort().join('\n'); };

  console.log('ledger selftest');
  await put('a.txt', 'alpha'); await put('b/c.txt', 'gamma'); await put('dup1.txt', 'same'); await put('dup2.txt', 'same');
  await put('Report.docx', 'v1'); await put('Report 2.docx', 'v1-conflicting'); await put('.DS_Store', 'junk');
  const before = await snapshot();

  const dry = await go({ apply: false });
  assert(dry.counts.changed === 6 && !fs.existsSync(sinkDir), 'dry run reports 6 candidates and writes nothing');

  tick(); let r = await go();
  assert(r.counts.uploaded === 5, 'identical content stored once (6 files, 5 objects), .DS_Store ignored');
  assert(r.events.filter((e) => e.op === 'put').length === 6 && r.events.some((e) => e.op === 'conflict'), 'six put events and one conflict event recorded');
  assert((await snapshot()) === before, 'source tree byte-for-byte and mtime unchanged (never written)');

  tick(); r = await go();
  assert(r.events.length === 0 && r.counts.unchanged === 6, 're-run with no change emits nothing (idempotent)');

  tick(); const t1 = clock; tick();
  await put('a.txt', 'alpha-2'); await fsp.rm(path.join(src, 'b/c.txt')); tick(); r = await go();
  assert(r.events.some((e) => e.op === 'put' && e.path === 'a.txt' && e.prev) && r.events.some((e) => e.op === 'tombstone' && e.path === 'b/c.txt'), 'edit records prev hash; delete records a tombstone');
  const objs = await sink.list('objects');
  assert(objs.size === 6, 'old object kept after edit and delete (append-only)');

  const segs = await readJournal(sink);
  assert(fold(segs).has('a.txt') && !fold(segs).has('b/c.txt'), 'fold gives the current tree');
  assert(fold(segs, t1).has('b/c.txt') && fold(segs, t1).get('a.txt').size === 5, 'fold --at returns the tree as it was before the edit');
  assert((await verify(sink, { deep: true, log: quiet })).ok, 'verify (deep) passes');

  const dest = path.join(tmp, 'restored'); await restore({ sink, dest, atMs: t1, log: quiet });
  assert((await fsp.readFile(path.join(dest, 'b/c.txt'), 'utf8')) === 'gamma', 'restore --at brings back the deleted file with the right bytes');
  let threw = false; try { await restore({ sink, dest: path.join(tmp, 'Mobile Documents', 'x'), log: quiet }); } catch { threw = true; }
  assert(threw, 'restore refuses to write inside a Mobile Documents path');

  const segFile = path.join(sinkDir, ...segs[0].name.split('/')); const txt = await fsp.readFile(segFile, 'utf8');
  await fsp.writeFile(segFile, txt.replace('"size":5', '"size":6'));
  assert(!(await verify(sink, { log: quiet })).ok, 'verify detects a tampered journal');
  await fsp.writeFile(segFile, txt);

  await put('fresh.txt', 'new'); await fsp.utimes(path.join(src, 'fresh.txt'), new Date(clock), new Date(clock));
  r = await go({ quietSecs: 60 });
  assert(r.counts.deferred === 1, 'a file modified seconds ago is deferred, not captured half-written');

  const big = path.join(tmp, 'big'); await fsp.mkdir(big);
  for (let i = 0; i < 12; i++) { const f = path.join(big, `f${i}.txt`); await fsp.writeFile(f, `n${i}`); await fsp.utimes(f, old, old); }
  const sink2 = new LocalDirSink(path.join(tmp, 'sink2')); const st2 = path.join(tmp, 'state2.json');
  await run({ source: big, sink: sink2, state: st2, apply: true, quietSecs: 0, now: () => clock, log: quiet });
  for (let i = 0; i < 12; i++) await fsp.rm(path.join(big, `f${i}.txt`));
  threw = false; try { await run({ source: big, sink: sink2, state: st2, apply: true, quietSecs: 0, now: () => clock, log: quiet }); } catch (e) { threw = /refusing/.test(e.message); }
  assert(threw, 'a source that suddenly loses every file is refused, not tombstoned');

  threw = false; try { checkSource(await (async () => { const d = path.join(tmp, 'Mobile Documents', 'ZP9ZJ4EF3S~com~gingerlabs~Notability'); await fsp.mkdir(d, { recursive: true }); return d; })()); } catch { threw = true; }
  assert(threw, 'Notability container is refused as a source');
  if (process.platform !== 'darwin') assert(isEvicted({ size: 10, blocks: 0 }, '/nonexistent') === true, 'zero-block file with a size is treated as evicted when it cannot be confirmed');
  assert(isEvicted({ size: 10, blocks: 8 }, '/nonexistent') === false && isEvicted({ size: 0, blocks: 0 }, '/nonexistent') === false, 'normal files and empty files are not evicted');

  const md = path.join(tmp, 'Mobile Documents'); const mk = async (rel, data) => { const f = path.join(md, rel); await fsp.mkdir(path.dirname(f), { recursive: true }); await fsp.writeFile(f, data); };
  const blob = Buffer.alloc(2048, 7);
  await mk('com~apple~CloudDocs/Docs/a.bin', blob); await mk('com~apple~CloudDocs/Old/a copy.bin', blob); await mk('com~apple~CloudDocs/Docs/b.bin', Buffer.alloc(2048, 8));
  await mk('com~apple~CloudDocs/proj/node_modules/x/i.js', 'x'.repeat(300));
  await mk('ZP9ZJ4EF3S~com~gingerlabs~Notability/Documents/n.note', 'secret');
  await fsp.chmod(path.join(md, 'ZP9ZJ4EF3S~com~gingerlabs~Notability'), 0o000); // any readdir would surface as "unreadable"
  const au = await audit({ root: md, baselineDir: path.join(tmp, 'audit'), out: path.join(tmp, 'AUDIT.md'), dupMin: 1024, log: quiet });
  await fsp.chmod(path.join(md, 'ZP9ZJ4EF3S~com~gingerlabs~Notability'), 0o755);
  assert(au.denied.length === 1 && au.unreadable.length === 0 && au.totals.files === 4, 'audit never opens the Notability container and counts the other 4 files');
  assert(au.duplicates.length === 1 && au.duplicates[0].copies === 2 && au.duplicates[0].wasted === 2048, 'audit finds the duplicate by size then sha256');
  assert(au.junk.length === 1 && au.junk[0].path.endsWith('proj/node_modules') && au.junk[0].bytes === 300, 'audit reports node_modules inside iCloud as dev junk');
  assert(au.groups.some((c) => c.name === 'iCloud Drive/Docs' && c.files === 2) && fs.existsSync(path.join(tmp, 'audit', 'latest.json')), 'audit groups by Drive folder and saves a baseline');

  const arq = path.join(tmp, 'arqdest', 'P', 'backupfolders', 'F', 'backuprecords', '00001'); await fsp.mkdir(arq, { recursive: true });
  await fsp.writeFile(path.join(arq, '1.backuprecord'), 'r1'); await fsp.writeFile(path.join(arq, '2.backuprecord'), 'r2');
  const rs = path.join(tmp, 'restoredSample'); await fsp.mkdir(path.join(rs, 'b'), { recursive: true }); await fsp.writeFile(path.join(rs, 'dup1.txt'), 'same');
  const bsFile = path.join(tmp, 'bs.json');
  let bs = await backupStatus({ dest: path.join(tmp, 'arqdest'), source: src, restored: rs, statusFile: bsFile, log: quiet });
  assert(bs.ok && bs.snapshots === 2 && bs.restore.matched === 1, 'backup-status counts Arq snapshots and verifies a restored sample by sha256');
  await fsp.writeFile(path.join(rs, 'dup1.txt'), 'tampered');
  bs = await backupStatus({ source: src, restored: rs, statusFile: bsFile, log: quiet });
  assert(!bs.ok && bs.restore.mismatches.length === 1, 'backup-status fails when a restored file differs from the source');
  bs = await backupStatus({ dest: path.join(tmp, 'arqdest'), statusFile: bsFile, now: () => Date.now() + 30 * 3600_000, log: quiet });
  assert(!bs.ok && bs.problems.some((p) => /no write/.test(p)), 'backup-status flags a destination with no write for over 26 h');

  assert(quota({ total: '5GB', remaining: 1.5e9 }).level === 'over-target' && quota({ total: '5GB', remaining: 0.5e9 }).level === 'alert' && quota({ total: '5GB', remaining: 3e9 }).level === 'ok', 'quota levels: ≤60% ok, >60% over-target, ≥80% alert');
  assert(quota({ total: '5GB', remaining: 16e9 }).level === 'inconsistent', 'quota flags remaining > plan size instead of reporting a negative usage');

  assert((await health(sink, { now: () => clock, log: quiet })).ok && !(await health(sink, { now: () => clock + 25 * 3600_000, log: quiet })).ok, 'health is OK after a run and STALE after 25 h');
  threw = false; try { openSink('/Volumes/ledger-selftest-not-mounted/x'); } catch (e) { threw = /not mounted/.test(e.message); }
  assert(threw, 'a sink on an unmounted volume is refused, not created on the internal disk');

  assert(defaultStatePath('/v', 'dir:/a') !== defaultStatePath('/v', 'rclone:r2:x'), 'state is per source and sink, so a second sink gets a full upload');

  const ovs = path.join(tmp, 'ov'); await fsp.mkdir(ovs);
  for (const [n, mb] of [['big.mov', 3], ['mid.pdf', 2], ['small.md', 0.1]]) { const f = path.join(ovs, n); await fsp.writeFile(f, Buffer.alloc(mb * 1e6, n.length)); await fsp.utimes(f, old, old); }
  const ovSink = new LocalDirSink(path.join(tmp, 'ovsink')); await run({ source: ovs, sink: ovSink, state: path.join(tmp, 'ovstate.json'), apply: true, quietSecs: 0, now: () => clock, log: quiet });
  await fsp.writeFile(path.join(ovs, 'mid.pdf'), Buffer.alloc(2e6, 9)); // changed since mirrored: no longer ready
  let ov = await overflow({ source: ovs, sink: path.join(tmp, 'ovsink'), maxMB: 1, quota: quota({ total: '5GB', remaining: 3e9 }), log: quiet });
  assert(ov.candidates.length === 2 && ov.candidates[0].ready && !ov.candidates[1].ready && ov.candidates.every((c) => c.selected), 'overflow lists files over the limit; ready only when the sink holds the exact bytes');
  ov = await overflow({ source: ovs, maxMB: 1, quota: { ...quota({ total: '10MB', remaining: 1e6 }) }, log: quiet });
  assert(ov.pressure && ov.candidates[0].selected && !ov.candidates[1].selected, 'under quota pressure it selects largest-first only until usage reaches the target');
  assert(/sha256: |"sha256":"/.test(pointerNote(ov.candidates[0], 'rclone:notes:overflow')), 'pointer note records sink, key and sha256');

  await fsp.writeFile(path.join(sinkDir, 'objects', '._appledouble'), 'xattrs');
  assert(![...(await sink.list('objects')).keys()].some((k) => k.includes('/._')), 'AppleDouble ._ files on exFAT sinks are not mistaken for objects');

  const arq5 = path.join(tmp, 'arq5dest', 'UUID', 'packsets'); await fsp.mkdir(arq5, { recursive: true }); await fsp.writeFile(path.join(arq5, 'x.pack'), 'p');
  bs = await backupStatus({ dest: path.join(tmp, 'arq5dest'), source: src, restored: rs, statusFile: path.join(tmp, 'bs5.json'), log: quiet });
  assert(bs.snapshots === null && bs.note && !bs.problems.some((p) => /Arq 7/.test(p)), 'an Arq 5 destination is not a failure; snapshot count is reported unknown');

  await fsp.rm(tmp, { recursive: true, force: true });
  console.log('all passed');
}

if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith('ledger.mjs')) {
  main().catch((e) => { console.error(`ledger: ${e.message}`); process.exit(1); });
}
