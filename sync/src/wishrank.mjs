#!/usr/bin/env node
// wishrank: the wish-order law (docs/law/order.md) as code.
// Stars set the group; emphasis (distinct days in the owner's own words) sets the order inside it.
// Order of writing never decides. Local files only; no network.
//
//   node src/wishrank.mjs            ranked queue of open triage entries, with the evidence
//   node src/wishrank.mjs order IDS  the given T-#### ids in law order, one per line (triage-watch uses this)
//   node src/wishrank.mjs selftest
//
// Env (defaults in brackets):
//   WISHRANK_TRIAGE      [~/Developer/recense/docs/specs/triage.md]
//   WISHRANK_ARCHIVE     [<triage dir>/triage-archive.md]   owner quotes there count as emphasis
//   WISHRANK_WISHES      [~/.claude/context/recense/notes/WISHES.md]  PAUSED objectives
//   WISHRANK_TRANSCRIPTS [~/.claude/projects]   *.jsonl one level down; "" = none
//   WISHRANK_CACHE       [~/.cache/recense/wishrank-owner.json]  per-file cache (mtime+size); "" = none

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import readline from 'node:readline';

const HOME = os.homedir();
const env = (k, d) => (process.env[k] === undefined ? d : process.env[k]);
const CLOSED = new Set(['MERGED', 'WONTFIX', 'PARKED', 'FIXED', 'READY']);
const STATUSES = /^(?:!\s*)?(NEW|SCOUTING|FIXING|READY|MERGED|HELD|PARKED|WONTFIX|FIXED)\b/;

// ---------- stars ----------
// A rating is a run of * at the start of the wish (after "-", "!", "1)" and spaces).
// Stars on both sides of the text (*text*, **text**) are formatting, not a rating.
export function stars(quote) {
  const m = quote.match(/^\s*(?:(?:[-–!]|\d+[).]|\*(?=\s+\*))\s*)*(\*+)\s*([\s\S]*)$/);  // "* ***x": a bullet, then 3
  if (!m) return 0;
  const n = m[1].length, rest = m[2].trimEnd();
  if (rest.length && /\*+$/.test(rest) && rest.match(/\*+$/)[0].length === n) return 0;
  return n;
}

// ---------- triage ----------
export function parseTriage(text, { source = 'triage' } = {}) {
  const out = [];
  let e = null;
  for (const raw of text.split('\n')) {
    const line = raw.replace(/\r$/, '');
    const h = line.match(/^## (T-\d{4}) · (.*)$/);
    if (h) { e = { id: h[1], title: h[2].trim(), quotes: [], keys: [], echoes: [], status: '', bang: false, owner: false, day: '', source }; out.push(e); continue; }
    if (/^# /.test(line)) { e = null; continue; }
    if (!e) continue;
    if (!e.status) {
      const s = line.match(/^(!\s*)?([A-Z]+) · [^·]* · (\d{4}-\d{2}-\d{2}) · (.*)$/);
      if (s) { e.bang = !!s[1]; e.status = s[2]; e.day = s[3]; e.owner = /owner/.test(s[4]); continue; }
    }
    if (line.startsWith('> ')) { e.quotes.push(line.slice(2)); continue; }
    const k = line.match(/^Keys:\s*(.*)$/);
    if (k) { if (k[1].trim()) e.keys.push(k[1].trim()); continue; }  // one regex per line; | inside is alternation
    const ec = line.match(/^Echoes:\s*(.*)$/);
    if (ec) { e.echoes.push(...(ec[1].match(/T-\d{4}/g) || [])); continue; }
    const u = line.match(/^- \d{4}-\d{2}-\d{2}[^·]* · ([^·]+?) · /);
    if (u) { const m = u[1].trim().match(STATUSES); if (m) e.status = m[1]; }
  }
  for (const x of out) x.rating = Math.max(0, ...x.quotes.map(stars));
  return out;
}

// ---------- owner texts (emphasis evidence) ----------
const SKIP = [/^\[Request interrupted/, /^Another Claude session sent/, /^Caveat:/, /^This session is being continued/,
  /^\[Earlier usage-limit/, /^I hit my usage limit/, /^\[Usage limit/, /^<(?!pasted_content)/, /^Base directory for this skill/];

export function ownerText(o) {
  if (!o || o.type !== 'user' || o.isMeta || o.isSidechain || o.isCompactSummary) return null;
  let c = o.message && o.message.content;
  if (Array.isArray(c)) c = c.filter(x => x && x.type === 'text').map(x => x.text).join('\n');
  if (typeof c !== 'string') return null;
  c = c.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, '').trim();
  if (!c || SKIP.some(r => r.test(c))) return null;
  return c;
}

export const hashOf = t => crypto.createHash('sha1').update(t.replace(/\s+/g, ' ').trim()).digest('hex');
export const dayOf = ts => { const d = new Date(ts); return isNaN(d) ? '' : `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };

async function readJsonl(file) {
  const texts = [];
  const rl = readline.createInterface({ input: fs.createReadStream(file), crlfDelay: Infinity });
  for await (const line of rl) {
    if (!line.includes('"type":"user"')) continue;
    let o; try { o = JSON.parse(line); } catch { continue; }
    const t = ownerText(o);
    if (t) texts.push({ d: dayOf(o.timestamp), t });
  }
  return texts;
}

async function transcriptTexts(root, cachePath) {
  if (!root || !fs.existsSync(root)) return { texts: [], files: 0 };
  let cache = {};
  if (cachePath) try { cache = JSON.parse(fs.readFileSync(cachePath, 'utf8')); } catch {}
  const next = {}, texts = [];
  let files = 0;
  for (const dir of fs.readdirSync(root).sort()) {
    const p = path.join(root, dir);
    let names; try { names = fs.readdirSync(p); } catch { continue; }
    for (const n of names.filter(n => n.endsWith('.jsonl')).sort()) {
      const f = path.join(p, n), st = fs.statSync(f), key = `${st.mtimeMs}:${st.size}`;
      const got = cache[f] && cache[f].key === key ? cache[f].texts : await readJsonl(f);
      next[f] = { key, texts: got };
      files++;
      for (const x of got) texts.push({ ...x, f: n });
    }
  }
  if (cachePath) try { fs.mkdirSync(path.dirname(cachePath), { recursive: true }); fs.writeFileSync(cachePath, JSON.stringify(next)); } catch {}
  return { texts, files };
}

// Identical texts (a paste repeated) count once, on the earliest day.
export function dedupe(texts) {
  const by = new Map();
  for (const x of texts) {
    const h = hashOf(x.t), was = by.get(h);
    if (!was || (x.d && x.d < was.d)) by.set(h, { ...x, h });
  }
  return [...by.values()];
}

// ---------- ranking ----------
export function emphasis(entry, texts) {
  if (!entry.keys.length) return { days: 0, msgs: 0, files: 0, nokeys: true };
  let res;
  try { res = entry.keys.map(k => new RegExp(k, 'iu')); } catch (err) { return { days: 0, msgs: 0, files: 0, badkeys: String(err.message) }; }
  const days = new Set(), files = new Set();
  let msgs = 0;
  for (const x of texts) if (res.some(r => r.test(x.t))) { msgs++; if (x.d) days.add(x.d); files.add(x.f); }
  return { days: days.size, msgs, files: files.size };
}

const cmp = (a, b) => (b.bang - a.bang) || (b.group - a.group) || (b.em.days - a.em.days) || (b.em.msgs - a.em.msgs) || (b.em.files - a.em.files);

export function rank(entries, texts) {
  const byId = new Map(entries.map(e => [e.id, e]));
  const open = entries.filter(e => e.source === 'triage' && !CLOSED.has(e.status));
  for (const e of open) {
    e.em = emphasis(e, texts);
    e.group = e.rating;
    e.why = e.rating ? 'rated' : '';
    if (!e.rating) {
      const borrowed = Math.max(0, ...e.echoes.map(id => (byId.get(id) || {}).rating || 0));
      if (borrowed) { e.group = borrowed; e.why = 'echo'; }
    }
  }
  // Unrated with nothing to borrow: last, unless it beats every wish in the lowest rated group on emphasis.
  const rated = open.filter(e => e.group > 0);
  if (rated.length) {
    const low = Math.min(...rated.map(e => e.group));
    const lowGroup = rated.filter(e => e.group === low);
    const top = lowGroup.reduce((m, e) => (cmp({ ...e, bang: 0, group: 0 }, { ...m, bang: 0, group: 0 }) < 0 ? e : m));
    for (const e of open.filter(e => e.group === 0)) {
      const beats = (e.em.days > top.em.days) || (e.em.days === top.em.days && (e.em.msgs > top.em.msgs || (e.em.msgs === top.em.msgs && e.em.files > top.em.files)));
      if (beats) { e.group = low; e.why = 'promoted'; }
    }
  }
  const sorted = [...open].sort((a, b) => cmp(a, b) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  for (let i = 1; i < sorted.length; i++) if (!cmp(sorted[i - 1], sorted[i])) { sorted[i - 1].tie = true; sorted[i].tie = true; }
  return sorted;
}

// ---------- output ----------
function line(e) {
  const ev = e.em.nokeys ? 'no Keys: line' : e.em.badkeys ? `bad Keys: ${e.em.badkeys}` : `${e.em.days}d ${e.em.msgs}m ${e.em.files}f`;
  const flags = [e.why === 'echo' && 'echo', e.why === 'promoted' && 'promoted', e.tie && 'TIE: owner decides', e.status !== 'NEW' && e.status].filter(Boolean);
  return `${e.id} · ${ev}${flags.length ? ' · ' + flags.join(' · ') : ''}\n    ${e.title}`;
}

function paused(wishesPath, ranked) {
  let txt = ''; try { txt = fs.readFileSync(wishesPath, 'utf8'); } catch { return []; }
  const pos = new Map(ranked.map((e, i) => [e.id, i + 1]));
  return txt.split('\n').filter(l => /PAUSED:/.test(l)).map(l => {
    const ids = (l.match(/T-\d{4}/g) || []).filter(id => pos.has(id));
    const best = ids.length ? Math.min(...ids.map(id => pos.get(id))) : Infinity;
    return { best, l: l.replace(/^-\s*/, '').slice(0, 140) };
  }).sort((a, b) => a.best - b.best);
}

async function load() {
  const triage = env('WISHRANK_TRIAGE', path.join(HOME, 'Developer/recense/docs/specs/triage.md'));
  const archive = env('WISHRANK_ARCHIVE', path.join(path.dirname(triage), 'triage-archive.md'));
  const entries = parseTriage(fs.readFileSync(triage, 'utf8'));
  let arch = []; try { arch = parseTriage(fs.readFileSync(archive, 'utf8'), { source: 'archive' }); } catch {}
  const all = [...entries, ...arch.filter(a => !entries.some(e => e.id === a.id))];
  const quoteTexts = all.filter(e => e.owner).flatMap(e => e.quotes.map(t => ({ d: e.day, t, f: path.basename(e.source === 'archive' ? archive : triage) })));
  const tr = await transcriptTexts(env('WISHRANK_TRANSCRIPTS', path.join(HOME, '.claude/projects')), env('WISHRANK_CACHE', path.join(HOME, '.cache/recense/wishrank-owner.json')));
  const texts = dedupe([...tr.texts, ...quoteTexts]);
  return { all, texts, files: tr.files };
}

async function main(argv) {
  const cmd = argv[0] || 'list';
  if (cmd === 'selftest') return selftest();
  const { all, texts, files } = await load();
  const ranked = rank(all, texts);
  if (cmd === 'order') {
    const want = new Set(argv.slice(1));
    const pos = ranked.map(e => e.id).filter(id => want.has(id));
    for (const id of argv.slice(1)) if (!pos.includes(id)) pos.push(id);  // unknown ids keep their place at the end
    process.stdout.write(pos.join('\n') + (pos.length ? '\n' : ''));
    return 0;
  }
  const days = new Set(texts.map(x => x.d).filter(Boolean)).size;
  const out = [`Wish queue · law: docs/law/order.md`, `Evidence: ${files} transcripts · ${texts.length} owner messages · ${days} days`, `d = days · m = messages · f = files`, ''];
  let g = null, n = 0;
  for (const e of ranked) {
    const head = e.bang ? '! fix now' : e.group ? `${'*'.repeat(e.group)} (${e.group})` : 'unrated';
    if (head !== g) { out.push(`${g === null ? '' : '\n'}${head}`); g = head; }
    out.push(`${String(++n).padStart(2)}. ${line(e)}`);
  }
  const p = paused(env('WISHRANK_WISHES', path.join(HOME, '.claude/context/recense/notes/WISHES.md')), ranked);
  if (p.length) { out.push('', 'PAUSED (resume the highest-ranked first)'); for (const x of p) out.push(`- ${x.best === Infinity ? 'no T-id' : '#' + x.best} · ${x.l}`); }
  console.log(out.join('\n'));
  return 0;
}

// ---------- selftest ----------
function selftest() {
  let fail = 0;
  const ok = (c, m) => { console.log(`${c ? 'ok  ' : 'FAIL'} ${m}`); if (!c) fail = 1; };
  const T = (id, q, extra = '', st = 'NEW', bang = '') =>
    `## ${id} · ${id} title\n${bang}${st} · Other · 2026-11-14 · owner\n> ${q}\n${extra}`;
  const tx = (d, t, f = 'a.jsonl') => ({ d, t, f });

  ok(stars('*****goal') === 5 && stars('- ****x') === 4 && stars('1) *****pulltube') === 5 && stars('! ***fix') === 3 && stars('* ***mini') === 3 && stars('-*  x') === 1, 'stars: leading run, after -, 1), !, a "* " bullet');
  ok(stars('*claude*') === 0 && stars('**hello claude**') === 0 && stars('plain') === 0, 'stars: *text* on both sides is formatting');
  ok(stars('**a** and b') === 2 || stars('**a** and b') === 0, 'stars: inner pair parses without throwing');

  const doc = ['Next ID: T-0009', '# Inbox', '- ', '# Open',
    T('T-0001', '** low but loud', 'Keys: loud'),
    T('T-0002', '***** quiet five', 'Keys: quiet'),
    T('T-0003', '***** busy five', 'Keys: busy'),
    T('T-0004', 'plain echo', 'Keys: echo\nEchoes: T-0002'),
    T('T-0005', '*just formatting*', 'Keys: zzz'),
    T('T-0006', '** twice', 'Keys: twice\n> ****** twice again'),
    T('T-0007', '***** merged one', 'Keys: busy', 'NEW') + '\n- 2026-11-14 · MERGED · claude · done\n',
    T('T-0008', 'urgent', 'Keys: urgent', 'NEW', '! '),
  ].join('\n');
  const es = parseTriage(doc);
  ok(es.length === 8 && es[5].rating === 6, 'parse: 8 entries; rated twice → highest wins');
  ok(es[6].status === 'MERGED', 'parse: later status line wins');
  const texts = [tx('2026-11-01', 'busy'), tx('2026-11-02', 'busy'), tx('2026-11-03', 'quiet'),
    tx('2026-11-01', 'loud'), tx('2026-11-02', 'loud'), tx('2026-11-03', 'loud'), tx('2026-11-04', 'loud')];
  const r = rank(es, texts).map(e => e.id);
  ok(r[0] === 'T-0008', '! fix-now comes first');
  ok(r[1] === 'T-0006', '6 stars before 5');
  ok(r.indexOf('T-0003') < r.indexOf('T-0002'), 'same group: more days first (filing order ignored)');
  ok(r.indexOf('T-0002') < r.indexOf('T-0001'), 'stars beat emphasis across groups (loud has 4 days, 2 stars)');
  ok(!r.includes('T-0007'), 'MERGED entries leave the queue');
  const ranked = rank(es, texts), e4 = ranked.find(e => e.id === 'T-0004');
  ok(e4.group === 5 && e4.why === 'echo', 'unrated borrows the rating it echoes');
  ok(ranked.find(e => e.id === 'T-0005').group === 0 && r[r.length - 1] === 'T-0005', '*text* unrated, no echo, low emphasis → last');

  const es2 = parseTriage([T('T-0010', '** a', 'Keys: aa'), T('T-0011', '** b', 'Keys: bb'), T('T-0012', 'loud plain', 'Keys: pp')].join('\n'));
  const t2 = [tx('2026-11-01', 'aa'), tx('2026-11-01', 'bb'), tx('2026-11-02', 'pp'), tx('2026-11-03', 'pp')];
  const r2 = rank(es2, t2);
  ok(r2.find(e => e.id === 'T-0012').group === 2 && r2[0].id === 'T-0012', 'unrated beating every wish in the group above moves up one group');
  ok(r2[1].tie && r2[2].tie, 'full tie is flagged for the owner');

  const es3 = parseTriage([T('T-0020', '* x', 'Keys: x'), T('T-0021', '* y', 'Keys: y')].join('\n'));
  const r3 = rank(es3, [tx('2026-11-01', 'x', 'a'), tx('2026-11-01', 'y', 'a'), tx('2026-11-01', 'y y', 'b')]);
  ok(r3[0].id === 'T-0021', 'tie 1 (days) → messages decide');

  const d = dedupe([tx('2026-11-05', 'same  paste'), tx('2026-11-02', 'same paste'), tx('2026-11-03', 'other')]);
  ok(d.length === 2 && d.find(x => x.t.startsWith('same')).d === '2026-11-02', 'identical pastes count once, earliest day');

  ok(ownerText({ type: 'user', message: { content: 'hello' } }) === 'hello', 'owner text: plain string');
  ok(ownerText({ type: 'user', message: { content: [{ type: 'tool_result', content: 'x' }] } }) === null, 'owner text: tool results are not the owner');
  ok(ownerText({ type: 'user', isMeta: true, message: { content: 'x' } }) === null && ownerText({ type: 'user', message: { content: '<command-name>/x</command-name>' } }) === null, 'owner text: meta and command tags skipped');
  ok(ownerText({ type: 'user', message: { content: '<pasted_content id="1">law</pasted_content>' } }) !== null, 'owner text: pastes count');
  ok(ownerText({ type: 'user', message: { content: '<system-reminder>r</system-reminder>\nreal words' } }) === 'real words', 'owner text: reminders stripped');

  const grp = parseTriage(T('T-0031', '* x', 'Keys: searchable (audio|text)|zz'));
  ok(rank(grp, [tx('2026-11-01', 'searchable text')])[0].em.days === 1, 'Keys: a group with | inside stays one pattern');
  const bad = parseTriage(T('T-0030', '* x', 'Keys: ( broken'));
  ok(rank(bad, [tx('2026-11-01', 'x')])[0].em.badkeys, 'a broken Keys: pattern is reported, not thrown');

  const again = JSON.stringify(rank(parseTriage(doc), texts).map(e => [e.id, e.group, e.em]));
  ok(again === JSON.stringify(rank(parseTriage(doc), texts).map(e => [e.id, e.group, e.em])), 'deterministic: same input, same order');
  console.log(fail ? 'wishrank selftest: FAIL' : 'wishrank selftest: ok');
  return fail;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main(process.argv.slice(2)).then(c => process.exit(c || 0), err => { console.error(`wishrank: ${err.message}`); process.exit(2); });
}
