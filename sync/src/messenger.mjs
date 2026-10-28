#!/usr/bin/env node
// messenger.mjs: ingest Meta "Download your information" exports (PROGRESS A8). Zero deps.
//   node messenger.mjs ingest [--inbox DIR] [--out DIR]      every new *.zip in the inbox, oldest first
//   node messenger.mjs status [--inbox DIR] [--max-age-days 35]   exit 1 when the newest export is too old
// Inbox default: /Volumes/SanDisk/inbox/messenger (owner saves each finished zip there). The zip is never
// edited, moved or deleted. Per zip: sha256, an extracted copy under OUT/raw/<stamp>-<sha8>/, and a derived
// OUT/threads/<stamp>-<sha8>/ with one <thread>.jsonl per thread + index.json. Meta stores UTF-8 as Latin-1
// \u00XX escapes; the derived copy repairs that, the raw copy stays byte-identical.
// Counts (threads, messages) must not shrink vs the previous export; a shrink is reported and exits 1.
import { createReadStream, existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { basename, join, relative } from 'node:path';

const args = process.argv.slice(2), cmd = args[0];
const opt = (k, d) => { const i = args.indexOf('--' + k); return i >= 0 ? args[i + 1] : d; };
const inbox = opt('inbox', '/Volumes/SanDisk/inbox/messenger');
const out = opt('out', join(inbox, '..', '..', 'messenger'));
const statePath = join(out, 'exports.json');

const sha256 = p => new Promise((res, rej) => { const h = createHash('sha256'); createReadStream(p).on('data', d => h.update(d)).on('end', () => res(h.digest('hex'))).on('error', rej); });
const load = () => existsSync(statePath) ? JSON.parse(readFileSync(statePath, 'utf8')) : { v: 1, exports: [] };
// Meta's mojibake: each UTF-8 byte became one U+00XX char. Repair only when the result is valid UTF-8.
const fix = s => { if (typeof s !== 'string' || !/[\u0080-ÿ]/.test(s) || /[^\u0000-ÿ]/.test(s)) return s; const b = Buffer.from(s, 'latin1'), t = b.toString('utf8'); return t.includes('�') ? s : t; };
const deep = v => Array.isArray(v) ? v.map(deep) : v && typeof v === 'object' ? Object.fromEntries(Object.entries(v).map(([k, x]) => [fix(k), deep(x)])) : fix(v);
const safe = s => String(s).replace(/[\/\\:\0-\x1f]/g, '_').slice(0, 120) || '_';

function walk(dir, hit) { for (const e of readdirSync(dir, { withFileTypes: true })) { const p = join(dir, e.name); if (e.isDirectory()) walk(p, hit); else hit(p); } }

function normalize(raw, dest) {
  // Thread folders hold message_1.json, message_2.json, ... (newer exports may differ: verify on real data).
  const threads = new Map();
  walk(raw, p => { const m = /\/messages\/([^/]+)\/([^/]+)\/message_\d+\.json$/.exec(p); if (m) { const k = m[1] + '/' + m[2]; (threads.get(k) || threads.set(k, []).get(k)).push(p); } });
  mkdirSync(dest, { recursive: true });
  const index = []; let messages = 0;
  for (const [key, files] of [...threads].sort()) {
    let title = '', participants = [], msgs = [];
    for (const f of files) { const j = deep(JSON.parse(readFileSync(f, 'utf8'))); title ||= j.title || ''; participants = j.participants?.length ? j.participants : participants; msgs.push(...(j.messages || [])); }
    msgs.sort((a, b) => (a.timestamp_ms || 0) - (b.timestamp_ms || 0));
    const [folder, thread] = key.split('/');
    const name = `${safe(folder)}__${safe(thread)}.jsonl`;
    writeFileSync(join(dest, name), msgs.map(m => JSON.stringify(m)).join('\n') + (msgs.length ? '\n' : ''));
    index.push({ file: name, folder, thread, title, participants: participants.map(p => p.name), messages: msgs.length, first: msgs[0]?.timestamp_ms ?? null, last: msgs.at(-1)?.timestamp_ms ?? null });
    messages += msgs.length;
  }
  const folders = [...new Set(index.map(t => t.folder))].sort();
  writeFileSync(join(dest, 'index.json'), JSON.stringify({ v: 1, threads: index.length, messages, folders, list: index }, null, 1));
  return { threads: index.length, messages, folders };
}

async function ingest() {
  if (!existsSync(inbox)) { console.log(`skip: ${inbox} not present`); return 0; }
  const st = load(), known = new Set(st.exports.map(e => e.sha256));
  const zips = readdirSync(inbox).filter(n => /\.zip$/i.test(n) && !n.startsWith('._')).map(n => join(inbox, n)).sort((a, b) => statSync(a).mtimeMs - statSync(b).mtimeMs);
  let rc = 0;
  for (const z of zips) {
    const s1 = statSync(z); if (Date.now() - s1.mtimeMs < 60e3) { console.log(`wait: ${basename(z)} still being written`); continue; }
    const sha = await sha256(z); if (known.has(sha)) continue;
    const stamp = new Date(s1.mtimeMs).toISOString().replace(/[-:]/g, '').slice(0, 15) + 'Z', id = `${stamp}-${sha.slice(0, 8)}`;
    const raw = join(out, 'raw', id), dest = join(out, 'threads', id);
    mkdirSync(raw, { recursive: true });
    execFileSync('/usr/bin/ditto', ['-x', '-k', z, raw]); // extract a copy; the zip is untouched
    const c = normalize(raw, dest);
    const e2ee = c.folders.some(f => /e2ee|encrypted/i.test(f));
    const prev = st.exports.at(-1);
    const shrink = prev && (c.threads < prev.threads || c.messages < prev.messages);
    st.exports.push({ id, zip: basename(z), bytes: s1.size, sha256: sha, at: new Date().toISOString(), ...c, e2eeFolder: e2ee, shrink: !!shrink });
    writeFileSync(statePath, JSON.stringify(st, null, 1));
    console.log(`ingested ${basename(z)}: ${c.threads} threads, ${c.messages} messages, folders ${c.folders.join(',')}${e2ee ? '' : ' (no end-to-end encrypted folder: gap until an E2EE export is added)'} → ${relative(out, dest)}`);
    if (shrink) { console.error(`SHRINK vs ${prev.id}: threads ${prev.threads}→${c.threads}, messages ${prev.messages}→${c.messages}`); rc = 1; }
    known.add(sha);
  }
  return rc;
}

function status() {
  const st = load(), last = st.exports.at(-1), max = Number(opt('max-age-days', 35));
  if (!last) { console.log('messenger: no export ingested yet'); return 1; }
  const age = (Date.now() - Date.parse(last.at)) / 864e5;
  console.log(`messenger: newest ${last.id} (${age.toFixed(1)} d ago), ${last.threads} threads, ${last.messages} messages${age > max ? ' — STALE' : ''}`);
  return age > max ? 1 : 0;
}

if (cmd === 'ingest') process.exit(await ingest());
else if (cmd === 'status') process.exit(status());
else { console.error('usage: node messenger.mjs ingest|status [--inbox DIR] [--out DIR] [--max-age-days N]'); process.exit(2); }
