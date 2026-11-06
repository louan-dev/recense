#!/usr/bin/env node
// canary.mjs: proves iCloud sync works for the Obsidian vault (PROGRESS A4). Zero dependencies.
// Kept apart from ledger.mjs on purpose: the ledger never writes to an iCloud folder; this writes one note.
//
//   node canary.mjs start [--vault DIR]            write _sync-canary.md with a fresh nonce
//   node canary.mjs check [--vault DIR] [--wait MIN]  report hops; with --wait, block (fs.watch, no polling)
//                                                   until the iPad line arrives back on this Mac
// On each device, open the note in Obsidian and append one line:  ipad 18:42   (device name, local HH:MM)
// Results: ~/.ledger/canary.json (start time, nonce, hops, arrival back on the Mac).

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';

const VAULT = path.join(os.homedir(), 'Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian');
const NOTE = '_sync-canary.md';
const STATE = path.join(os.homedir(), '.ledger', 'canary.json');
const HOPS = ['iphone', 'ipad'];

const args = process.argv.slice(2); const cmd = args[0];
const opt = (k, d) => { const i = args.indexOf(`--${k}`); return i >= 0 && args[i + 1] ? args[i + 1] : d; };
let vault = opt('vault', VAULT); let file = path.join(vault, NOTE);
const load = () => { try { return JSON.parse(fs.readFileSync(STATE, 'utf8')); } catch { return null; } };
const save = (s) => { fs.mkdirSync(path.dirname(STATE), { recursive: true }); fs.writeFileSync(STATE, JSON.stringify(s, null, 2)); };

export function parse(text, startMs) { // "- iphone 18:42" or "iphone 18:42:10" → ms on the start's day (rolls past midnight)
  const hops = {};
  for (const line of text.split('\n')) {
    const m = /^\s*-?\s*(iphone|ipad)\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*$/i.exec(line); if (!m) continue;
    const d = new Date(startMs); d.setHours(+m[2], +m[3], +(m[4] || 0), 0);
    let t = d.getTime(); if (t < startMs - 60_000) t += 86_400_000;
    hops[m[1].toLowerCase()] ??= t;
  }
  return hops;
}

function report(s, text) {
  const hops = parse(text, s.startMs); let prev = s.startMs; const out = [];
  for (const h of HOPS) { if (!hops[h]) { out.push(`${h}: not yet`); break; } out.push(`${h}: +${Math.max(0, Math.round((hops[h] - prev) / 60000))} min`); prev = hops[h]; }
  if (s.backMs) out.push(`back on Mac: +${Math.round((s.backMs - (hops.ipad ?? s.startMs)) / 1000)} s; round trip ${Math.round((s.backMs - s.startMs) / 60000)} min`);
  return { hops, line: out.join(' · ') };
}

function check(s) {
  let st; try { st = fs.lstatSync(file); } catch { return { missing: true }; }
  if (st.size > 0 && st.blocks === 0) return { dataless: true }; // reading would force a download; report instead
  const text = fs.readFileSync(file, 'utf8');
  if (!text.includes(s.nonce)) return { foreign: true };
  const r = report(s, text);
  if (r.hops.ipad && !s.backMs) { s.backMs = Date.now(); s.hops = r.hops; save(s); r.line = report(s, text).line; }
  return r;
}

if (cmd === 'start') {
  if (!fs.existsSync(vault)) { console.error(`vault not found: ${vault}`); process.exit(1); }
  if (fs.existsSync(file)) { console.error(`${NOTE} already exists; rename or delete it yourself first (this tool never deletes)`); process.exit(1); }
  const s = { startMs: Date.now(), nonce: crypto.randomBytes(4).toString('hex'), vault };
  const t = new Date(s.startMs);
  fs.writeFileSync(file, `# Sync canary ${s.nonce}\n\nStarted on the Mac at ${t.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })} (${t.toISOString()}).\nOn the iPhone, then the iPad: append one line, device and local time, like \`iphone 18:42\`.\n\n`, { flag: 'wx' });
  save(s); console.log(`canary ${s.nonce} written to ${file}`);
} else if (cmd === 'check') {
  const s = load(); if (!s) { console.error('no canary started'); process.exit(1); }
  vault = opt('vault', s.vault); file = path.join(vault, NOTE); // the vault the canary was started in
  const r = check(s);
  if (r.line && (s.backMs || !opt('wait'))) { console.log(r.line); process.exit(s.backMs ? 0 : 2); }
  if (!opt('wait')) { console.log(JSON.stringify(r)); process.exit(2); }
  const deadline = setTimeout(() => { console.log(`timeout: ${JSON.stringify(check(s))}`); process.exit(2); }, Number(opt('wait')) * 60_000);
  fs.watch(vault, (_e, name) => { // FSEvents: woken only when the folder changes
    if (name && name !== NOTE) return;
    const x = check(s); if (s.backMs) { clearTimeout(deadline); console.log(x.line); process.exit(0); }
  });
  console.log(`waiting up to ${opt('wait')} min for the iPad line (${r.line ?? JSON.stringify(r)})`);
} else if (cmd === 'selftest') {
  const start = new Date(2026, 9, 13, 23, 50).getTime();
  const h = parse('x\n- iphone 23:55\nipad 00:03:30\n', start);
  const ok = h.iphone - start === 5 * 60_000 && h.ipad - start === 13.5 * 60_000;
  console.log(ok ? 'canary selftest: ok (parses hops, rolls past midnight)' : 'canary selftest: FAIL'); process.exit(ok ? 0 : 1);
} else { console.error('usage: node canary.mjs start|check [--vault DIR] [--wait MIN]|selftest'); process.exit(64); }
