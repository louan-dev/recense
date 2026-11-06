// Transcripts from Recense (the Mac app), shown under Gallery's audio and video, and the corrections anyone viewing
// makes to them (corrections.js).
//
// Recense transcribes every audio/video file in Main while it is idle and keeps the result in its own bucket
// (binding KEEP, recense-tmp), one folder per media under keep/<key>/ (layout.js), where key is the file's content key
// (fingerprintKey; a transcript made before those is found under the first 24 hex of SHA-256 of
// "gallery:files/<path>"): asr.json (the original), tr/<lang>.json (en, vi, fr, each on its own),
// corrections.json and history/. When Recense found the recording was already transcribed from another source, the
// file is an alias instead: keep/library.json { aliases: { <key>: { key, shift } } } with shift = this file's time −
// the transcript's time. An older transcript (keep/<key>.v2.json, keep/<key>.edits.json) is read too, and the first
// read writes it out in the new layout (never over what is there, never deleting the old files).
//
// Gallery writes only:
//   keep/<key>/corrections.json      corrections (corrections.js), conditional put on its etag
//   keep/<key>/history/<version>.json the last 20 versions of it
//   keep/<key>/changes.json          { changes: [{ v, at, segId, field, from, to, src }] }, oldest first, the last
//                                    1000: what each correction replaced, so any of them can be put back (a restore
//                                    is one more correction, logged the same way)
//   keep/<key>/asr.json, tr/en.json  only when moving an old transcript over, only where there is none yet
//   keep/locks/<own key>             a viewer asked for a transcript: { state: queued|running|failed, at, beat, path,
//                                    src, redo, progress }. Recense polls keep/locks/, transcribes, writes
//                                    <key>/asr.json, then deletes the lock (or marks it failed). Held for 15 minutes
//                                    from its last beat.
//
// What the page gets: { lines: [{ id, s, e, text, en, enw: [{ w, s: [i] }], words: [{ t, s, e }], fixed?,
// tr?: { vi?, fr?, en? } }], langs: ["en", "vi", ...], complete, version, run? } (times in this file's seconds), or
// { pending: true, run } while there is none yet. tr has each language's translation of the line (a correction of it
// first); langs the translations the media has a file of: the page shows the native language's, else the English.

import { jsonResponse } from "./common.js";
import { applyNative, baseLines, cleanText, correctedLines, emptyDoc, HISTORY, joinWords, mergeOverrides, normalizeDoc, pinsOf, present, teach } from "./corrections.js";
import { asrName, changesName, corrName, entryFor, histName, join, LANGS, oldCorrName, oldTranscriptName, split, srcOf, trName } from "./layout.js";

export const LOCK_TTL = 15 * 60 * 1000;
export const SHARE_EDITS_PER_MIN = 20;
const MAX_BODY = 64 * 1024;
const MAX_EDITS = 100;
const MAX_CHANGES = 1000;

const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
const sha = async (s) => hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));

// The key by the file's path: how transcripts were named before content keys, still read.
export async function transcriptKey(path) {
  return (await sha("gallery:files/" + path)).slice(0, 24);
}

// The key by the file's content, the same Recense computes for it on the Mac or here (ContentKey in main.swift):
// "fp:<bytes>:<sha256 of the first 64 KiB>:<sha256 of the last 64 KiB>", so one recording is one item wherever it is.
// Two ranged reads; null when the file is not there.
export const SPAN = 65536;
export async function fingerprintKey(env, path) {
  if (!env.MAIN) return null;
  const h = await env.MAIN.head("files/" + path).catch(() => null);
  if (!h) return null;
  const part = async (offset, length) => {
    const o = await env.MAIN.get("files/" + path, { range: { offset, length } }).catch(() => null);
    return o ? hex(await crypto.subtle.digest("SHA-256", await o.arrayBuffer())) : null;
  };
  const head = await part(0, Math.min(SPAN, h.size));
  const tail = h.size <= SPAN ? head : await part(h.size - SPAN, SPAN);
  if (head === null || tail === null) return null;
  return (await sha(`fp:${h.size}:${head}:${tail}`)).slice(0, 24);
}

async function readJson(env, name) {
  try {
    const o = await env.KEEP.get(name);
    return o ? await o.json() : null;
  } catch (e) {
    return null;
  }
}
const readKeep = (env, name) => readJson(env, "keep/" + name);

const JSON_TYPE = { httpMetadata: { contentType: "application/json" } };
// written only where nothing is yet (Recense's own, or another viewer's move, stays)
const putNew = (env, name, body) => env.KEEP.put(name, JSON.stringify(body), { ...JSON_TYPE, onlyIf: { etagDoesNotMatch: "*" } }).catch(() => null);

// An old transcript (<key>.v2.json) moved over to <key>/asr.json and <key>/tr/en.json.
async function migrate(env, key, v2) {
  const { asr, en } = split(v2);
  await Promise.all([putNew(env, asrName(key), asr), en ? putNew(env, trName(key, "en"), en) : null]);
}

// A transcript under its key: { c, tr } with c the lines the corrections work on (English inside) and tr the
// translation files there are ({ en, vi, fr }, null where there is none); null when there is no transcript.
async function load(env, key) {
  const [asr, ...files] = await Promise.all([readJson(env, asrName(key)), ...LANGS.map((l) => readJson(env, trName(key, l)))]);
  const tr = Object.fromEntries(LANGS.map((l, i) => [l, files[i] && typeof files[i] === "object" && files[i].lines ? files[i] : null]));
  // (an empty asr.json that isn't complete is the stub a failed fetch once left: no transcript, notes 38)
  if (asr && Array.isArray(asr.segments) && (asr.segments.length || asr.complete)) return { c: join(asr, tr.en), tr };
  const old = await readJson(env, oldTranscriptName(key));
  if (!old || !Array.isArray(old.lines)) return null;
  await migrate(env, key, old);
  if (!tr.en && old.lines.some((l) => l && Array.isArray(l.english))) tr.en = { lang: "en", lines: {} }; // English inside it
  return { c: old, tr };
}

// The transcript a file in Main has (its path under files/): { own, key, shift, c, tr }. own is the file's own key
// (its lock's); key the transcript's (after an alias); c the transcript, null when there is none yet.
async function resolve(env, path, depth = 0) {
  const legacy = await transcriptKey(path);
  const own = (await fingerprintKey(env, path)) || legacy;
  let key = own;
  let shift = 0;
  let t = await load(env, key);
  if (!t && legacy !== own) {
    t = await load(env, legacy);
    if (t) key = legacy;
  }

  if (!t) {
    const lib = await readKeep(env, "library.json");
    const a = lib && lib.aliases && (lib.aliases[own] || lib.aliases[legacy]);
    if (a && /^[0-9a-f]{24}$/.test(a.key)) {
      key = a.key;
      shift = Number(a.shift) || 0;
      t = await load(env, key);
    }
  }

  // a renamed file remembers its first path, which is what Recense knows it by
  if (!t && env.MAIN && depth < 3) {
    const h = await env.MAIN.head("files/" + path).catch(() => null);
    const was = h && h.customMetadata && h.customMetadata.was;
    if (was && was !== path) {
      const r = await resolve(env, was, depth + 1);
      if (r.c) return { ...r, own };
    }
  }

  if (!t || !Array.isArray(t.c.lines)) return { own, key: own, shift: 0, c: null, tr: {} };
  return { own, key, shift, c: t.c, tr: t.tr };
}

// The corrections and their etag. An old <key>.edits.json is moved over to <key>/corrections.json first.
async function readDoc(env, key) {
  let o = await env.KEEP.get(corrName(key)).catch(() => null);
  if (!o) {
    const old = await env.KEEP.get(oldCorrName(key)).catch(() => null);
    if (!old) return { doc: emptyDoc(), etag: null };
    const text = await old.text();
    const put = await env.KEEP.put(corrName(key), text, { ...JSON_TYPE, onlyIf: { etagDoesNotMatch: "*" } }).catch(() => null);
    if (put) {
      let d = null;
      try {
        d = JSON.parse(text);
      } catch (e) {}
      return { doc: normalizeDoc(d), etag: put.etag };
    }
    o = await env.KEEP.get(corrName(key)).catch(() => null); // moved over meanwhile
    if (!o) return { doc: emptyDoc(), etag: null };
  }
  let d = null;
  try {
    d = await o.json();
  } catch (e) {}
  return { doc: normalizeDoc(d), etag: o.etag };
}

// Each line's translations from the language files (vi, fr; the English is in the lines already), a correction of
// one winning. A translation counts for a line when it was made from its words as Recense had them (before
// Gallery's corrections) or as shown.
function withTranslations(lines, tr, before) {
  const langs = LANGS.filter((l) => l !== "en" && tr[l]);
  if (!langs.length) return lines;
  return lines.map((l) => {
    const texts = [before.get(l.id), l.fixed ? l.text : srcOf(l.words.map((w) => ({ text: w.t })))].filter((x) => x != null);
    const found = {};
    for (const lang of langs) {
      const e = entryFor(tr[lang], l.id, texts);
      if (e && !e.same && typeof e.text === "string" && e.text.trim()) found[lang] = e.text.trim();
    }
    return Object.keys(found).length ? { ...l, tr: { ...found, ...(l.tr || {}) } } : l;
  });
}

// the lines as the page gets them
// Whisper invents short lines over music with no voice ("Visions, diaspora", "Thank you for watching"):
// a transcript of nothing but such lines is an instrumental, and shows as none
const PHANTOM = /^(\W*(thank(s| you)( so much)?( for (watching|listening))?|visions,? diaspora|subtitles? by.*|please subscribe.*|you|bye|music|applause)\W*)$/i;
function dropPhantoms(lines) {
  const phantom = (l) => !l.fixed && PHANTOM.test(String(l.text || l.words.map((w) => w.t).join(" ")).trim());
  return lines.length && lines.every(phantom) ? [] : lines;
}

function shape(r, doc) {
  const before = new Map(applyNative(baseLines(r.c), doc).map((l) => [l.id, l.words.map((w) => w.t).join(" ")]));
  return present(dropPhantoms(withTranslations(correctedLines(r.c, doc), r.tr, before)), r.shift);
}

const langsOf = (r) => LANGS.filter((l) => r.tr[l]);
// the language sung or spoken (asr.json's `language`, else most of its words' own), two letters: the prosogram's French
// liaisons and Vietnamese tones hang on it. `langs` is only the translations there are.
const NAMES = { french: "fr", english: "en", vietnamese: "vi", spanish: "es", german: "de", italian: "it", portuguese: "pt", japanese: "ja", chinese: "zh", mandarin: "zh", cantonese: "zh", korean: "ko", amharic: "am", zulu: "zu", isizulu: "zu" };
const spokenOf = (r) => {
  const two = (x) => (typeof x !== "string" || !x.trim() ? "" : NAMES[x.trim().toLowerCase()] || x.trim().slice(0, 2).toLowerCase());
  const own = two(r.c && r.c.language);
  if (own) return own;
  const n = {};
  for (const l of (r.c && r.c.lines) || []) for (const w of l.words || []) { const k = two(w.lang); if (k) n[k] = (n[k] || 0) + 1; }
  return Object.keys(n).sort((a, b) => n[b] - n[a])[0] || "";
};

// ---------- the lock ----------

const lockKey = (own) => "keep/locks/" + own;

// what viewers are told of a lock: null when there is none or it has lapsed (nobody beat it for 15 minutes)
function runState(lock, now = Date.now()) {
  if (!lock || typeof lock !== "object") return null;
  if (lock.state === "failed") return { state: "failed", error: String(lock.error || "") };
  if (now - (Number(lock.beat) || Number(lock.at) || 0) > LOCK_TTL) return null;
  return { state: lock.state === "running" ? "running" : "queued", at: Number(lock.at) || 0, progress: Number(lock.progress) || 0, redo: !!lock.redo };
}

async function readLock(env, own) {
  const o = await env.KEEP.get(lockKey(own)).catch(() => null);
  if (!o) return { lock: null, etag: null };
  let lock = null;
  try {
    lock = await o.json();
  } catch (e) {}
  return { lock, etag: o.etag };
}

// ---------- reading ----------

// The transcript of a file in Main (its path under files/), corrected and shaped for the page.
export async function transcriptFor(env, path) {
  if (!env.KEEP) return { pending: true };
  const r = await resolve(env, path);
  const run = runState((await readLock(env, r.own)).lock);
  if (!r.c) return { pending: true, run };
  const { doc } = await readDoc(env, r.key);
  const out = { lines: shape(r, doc), lang: spokenOf(r), langs: langsOf(r), complete: !!r.c.complete, version: doc.version, shift: r.shift || 0 };
  if (run) out.run = run;
  return out;
}

// ?f=features: the voice measured frame by frame (keep/<key>/features.json, Recense's Features: hop, floor, db, onset,
// pitch, clarity, voiced), with the file's shift against the transcript, for the karaoke light to take its shape (notes 33)
export async function transcriptResponse(env, path, want) {
  if (want === "features") {
    if (!env.KEEP) return jsonResponse({ none: true });
    const r = await resolve(env, path);
    const f = await readKeep(env, r.key + "/features.json");
    return jsonResponse(f && Array.isArray(f.db) ? { ...f, shift: r.shift || 0 } : { none: true });
  }
  const t = await transcriptFor(env, path);
  return jsonResponse(t);
}

// ---------- correcting ----------

async function readBody(req) {
  const len = Number(req.headers.get("content-length") || 0);
  if (len > MAX_BODY) return { error: new Response("Too big", { status: 413 }) };
  const raw = await req.text();
  if (raw.length > MAX_BODY) return { error: new Response("Too big", { status: 413 }) };
  try {
    return { body: raw ? JSON.parse(raw) : {} };
  } catch (e) {
    return { error: new Response("Bad JSON", { status: 400 }) };
  }
}

// share only: 20 edits a minute per address per transcript, counted over the last 60 s (PUBLIC rate/tx/, swept daily)
async function rateOk(env, key, ip, n) {
  const k = "rate/tx/" + key + "/" + (await sha("ip:" + ip)).slice(0, 20);
  const now = Date.now();
  let t = [];
  try {
    const o = await env.PUBLIC.get(k);
    if (o) t = ((await o.json()).t || []).filter((x) => now - x < 60000);
  } catch (e) {}
  if (t.length + n > SHARE_EDITS_PER_MIN) return false;
  for (let i = 0; i < n; i++) t.push(now);
  await env.PUBLIC.put(k, JSON.stringify({ t }));
  return true;
}

export async function rateSweep(env) {
  const day = Date.now() - 86400000;
  for (const prefix of ["rate/tx/", "rate/dav/"]) await sweepRates(env, prefix, day);
}

async function sweepRates(env, prefix, day) {
  let cursor;
  do {
    const r = await env.PUBLIC.list({ prefix, cursor });
    const old = r.objects.filter((o) => o.uploaded.getTime() < day).map((o) => o.key);
    if (old.length) await env.PUBLIC.delete(old);
    cursor = r.truncated ? r.cursor : undefined;
  } while (cursor);
}

const conflict = (doc) => jsonResponse({ conflict: true, version: doc.version, overrides: doc.overrides, glossary: doc.glossary }, 409);

// PUT { version, edits: [{ segId, field, to, updatedAt? }] }   src = "main" | "share"
export async function transcriptSave(req, env, path, src) {
  if (!env.KEEP) return new Response("No transcripts here", { status: 503 });
  const { body, error } = await readBody(req);
  if (error) return error;

  const edits = body && Array.isArray(body.edits) ? body.edits : null;
  if (!edits || !edits.length || edits.length > MAX_EDITS || !Number.isInteger(body.version)) return new Response("Bad request", { status: 400 });
  const now = Date.now();
  const clean = [];
  for (const e of edits) {
    const segId = e && (typeof e.segId === "string" || Number.isInteger(e.segId)) ? String(e.segId) : "";
    const field = e && typeof e.field === "string" && /^(text|time|tr\.[a-z]{2,3})$/.test(e.field) ? e.field : "";
    const to = e && typeof e.to === "string" ? cleanText(e.to) : null;
    if (!segId || segId.length > 64 || !field) return new Response("Bad edit", { status: 400 });
    if (to === null) return new Response("Text too long", { status: 400 });
    if (field === "time" && to && JSON.stringify(Object.entries(pinsOf(to)).map(([i, p]) => (p.c ? [+i, p.s, p.e, p.k, p.c] : [+i, p.s, p.e, p.k]))) !== to) return new Response("Bad timing", { status: 400 });
    const u = Number(e.updatedAt);
    clean.push({ segId, field, to, updatedAt: Number.isFinite(u) && u <= now && u > now - 7 * 86400000 ? u : now });
  }

  const r = await resolve(env, path);
  if (!r.c) return jsonResponse({ pending: true }, 404);

  if (src === "share") {
    const ip = req.headers.get("cf-connecting-ip") || "unknown";
    if (!(await rateOk(env, r.key, ip, clean.length))) return new Response("Too many edits; try again in a minute", { status: 429, headers: { "retry-after": "60" } });
  }

  const { doc, etag } = await readDoc(env, r.key);
  if (body.version !== doc.version) return conflict(doc);

  // segments are the transcript's lines once Recense's own edits are laid over (overrides never change ids)
  const base = new Map(applyNative(baseLines(r.c), doc).map((l) => [l.id, l]));
  const shown = new Map(correctedLines(r.c, doc).map((l) => [l.id, l]));
  const wasText = (s) => (s ? (s.fixed ? s.text : joinWords(s.words.map((w) => w.t))) : "");
  const logged = [];
  for (const e of clean) {
    const line = base.get(e.segId);
    if (!line) return new Response("No such segment: " + e.segId, { status: 400 });
    const o = { segId: e.segId, start: line.words[0].s, end: line.words[line.words.length - 1].e, field: e.field, to: e.to, src, updatedAt: e.updatedAt };
    const had = doc.overrides.find((x) => x.segId === o.segId && x.field === o.field);
    if (had && (Number(had.updatedAt) || 0) > o.updatedAt) continue; // a later correction of it is already saved
    const s = shown.get(o.segId);
    const from = o.field === "time" ? (had ? had.to : "") : o.field === "text" ? (s ? wasText(s) : joinWords(line.words.map((w) => w.t))) : (had ? had.to : (s && s.tr && s.tr[o.field.slice(3)]) || "");
    if (o.field === "text") teach(doc.glossary, from, o.to);
    if (from !== o.to) logged.push({ segId: o.segId, field: o.field, from, to: o.to, src, at: o.updatedAt });
    doc.overrides = mergeOverrides(doc.overrides, [o]);
  }
  doc.version += 1;
  doc.updatedAt = now;

  const json = JSON.stringify(doc);
  const put = await env.KEEP.put(corrName(r.key), json, { ...JSON_TYPE, onlyIf: etag ? { etagMatches: etag } : { etagDoesNotMatch: "*" } });
  if (!put) return conflict((await readDoc(env, r.key)).doc);

  await Promise.all([
    env.KEEP.put(histName(r.key, doc.version), json, JSON_TYPE),
    doc.version > HISTORY ? env.KEEP.delete(histName(r.key, doc.version - HISTORY)) : null,
    logChanges(env, r.key, logged.map((c) => ({ v: doc.version, ...c }))),
  ]);

  return jsonResponse({ ok: true, version: doc.version, lines: shape(r, doc), lang: spokenOf(r), langs: langsOf(r), glossary: doc.glossary });
}

// The change log, appended on its etag (two saves at once both land); never fails the save it records.
async function logChanges(env, key, add) {
  if (!add.length) return;
  for (let i = 0; i < 4; i++) {
    const o = await env.KEEP.get(changesName(key)).catch(() => null);
    let log = { changes: [] };
    if (o) log = await o.json().catch(() => log);
    if (!Array.isArray(log.changes)) log.changes = [];
    log.changes = log.changes.concat(add).slice(-MAX_CHANGES);
    const put = await env.KEEP.put(changesName(key), JSON.stringify(log), { ...JSON_TYPE, onlyIf: o ? { etagMatches: o.etag } : { etagDoesNotMatch: "*" } }).catch(() => null);
    if (put) return;
  }
}

// GET: the corrections made to this file's transcript, newest first
export async function transcriptChanges(env, path) {
  if (!env.KEEP) return new Response("No transcripts here", { status: 503 });
  const r = await resolve(env, path);
  if (!r.c) return jsonResponse({ changes: [] });
  const log = await readJson(env, changesName(r.key));
  const changes = log && Array.isArray(log.changes) ? log.changes.slice().reverse() : [];
  return jsonResponse({ changes });
}

// ---------- asking for a transcript ----------

// POST { retry?, retranscribe? }: when the file has no transcript (or one is to be made again), queue it for Recense
// under the lock, unless someone already has. Never when it has one, unless asked to retranscribe.
export async function transcriptRun(req, env, path, src) {
  if (!env.KEEP) return new Response("No transcripts here", { status: 503 });
  const { body, error } = await readBody(req);
  if (error) return error;
  const redo = !!(body && body.retranscribe) && src === "main";
  const retry = !!(body && body.retry);
  const lang = body && LANGS.includes(body.lang) ? body.lang : null; // the viewer's language, translated first

  const r = await resolve(env, path);
  if (r.c && !redo) return jsonResponse({ state: "done" });

  const { lock, etag } = await readLock(env, r.own);
  const st = runState(lock);
  if (st && st.state !== "failed") return jsonResponse(st); // someone is on it: wait for it
  if (st && !retry && !redo) return jsonResponse(st); // it failed: Retry is the viewer's call

  const now = Date.now();
  const next = { state: "queued", at: now, beat: now, path, src, redo, progress: 0, ...(lang ? { lang } : {}) };
  const ok = await env.KEEP.put(lockKey(r.own), JSON.stringify(next), {
    httpMetadata: { contentType: "application/json" },
    onlyIf: etag ? { etagMatches: etag } : { etagDoesNotMatch: "*" },
  });
  if (!ok) return jsonResponse(runState((await readLock(env, r.own)).lock) || { state: "queued", at: now, progress: 0 });
  return jsonResponse({ state: "queued", at: now, progress: 0, redo }, 202);
}
