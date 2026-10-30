// The assistant (owner-only, under /main/api/ai/…; the /main gate and sameSite() in worker.js run first).
//   POST /main/api/ai/ask     { q, scope: { root: "main"|"archive"|"all", path }, history }  → NDJSON stream:
//                             {sources:[…]} first, then {t:"…"} pieces of the answer, then {done:true} (or {error})
//   POST /main/api/ai/search  { q, scope } → { hits }
//   GET  /main/api/ai/status  → how much is indexed
//   POST /main/api/ai/index   → one indexing step; call until { done: true } (the nightly cron also steps)
//
// Runs on Workers AI (env.AI) with a Vectorize index (env.VECTORS, 1024 dims, cosine, metadata index on "root").
// The owner's documents are the authority; the model may add general knowledge only where they are silent (ai-core.js).
// Indexing works in small steps so a 3,000-page book never meets a request's limits: a document's text is extracted
// once (ai/text/<id>.txt in MAIN) and then embedded a slice at a time; ai/index.json in MAIN remembers where it got to.
import { jsonResponse } from "./common.js";
import { transcriptFor } from "./transcript.js";
import { kindOf, chunkText, chunkTranscript, nameText, pick, buildMessages, vectorId } from "./ai-core.js";

const CHAT = "@cf/openai/gpt-oss-120b";       // env.AI_CHAT_MODEL overrides (a var in wrangler.toml)
const EMBED = "@cf/baai/bge-m3";              // changing it means re-indexing everything (different vectors)
const STATE = "ai/index.json";
const TEXT = "ai/text/";
const ROOTS = { main: { bucket: "MAIN", prefix: "files/" }, archive: { bucket: "ARCHIVE", prefix: "chauphan/" } };
const MAX_DOC = 40 * 1024 * 1024;              // larger documents are indexed by name only
const SLICE = 96;                              // passages embedded per call
const STEP_CALLS = 24;                         // AI / Vectorize calls one step may make

const ready = (env) => !!(env.AI && env.VECTORS);
const notReady = () => jsonResponse({ ok: false, error: "The assistant isn't set up yet (Workers AI and Vectorize bindings)." }, 503);

export async function aiRoute(req, env, ctx, url, path, method) {
  if (path === "/main/api/ai/status" && method === "GET") return status(env);
  if (!ready(env)) return notReady();
  if (path === "/main/api/ai/index" && method === "POST") return jsonResponse(await indexStep(env));
  if (method !== "POST") return new Response("Method not allowed", { status: 405 });
  let body;
  try { body = await req.json(); } catch { return new Response("Bad JSON", { status: 400 }); }
  const q = String(body?.q || "").trim().slice(0, 4000);
  if (!q) return new Response("Empty question", { status: 400 });
  const scope = cleanScope(body.scope);
  if (path === "/main/api/ai/search") return jsonResponse({ ok: true, hits: (await retrieve(env, q, scope)).map(publicHit) });
  if (path === "/main/api/ai/ask") return ask(env, ctx, q, scope, body.history);
  return new Response("Not found", { status: 404 });
}

function cleanScope(s) {
  const root = s && ["main", "archive", "all"].includes(s.root) ? s.root : "all";
  const path = root === "all" ? "" : String(s?.path || "").replace(/^\/+|\/+$/g, "").slice(0, 1024);
  return { root, path };
}

const publicHit = (h) => ({ root: h.root, path: h.path, kind: h.kind, t: h.t ?? null, text: h.text, score: h.score });

async function embed(env, texts) {
  const r = await env.AI.run(env.AI_EMBED_MODEL || EMBED, { text: texts });
  if (!r || !Array.isArray(r.data) || r.data.length !== texts.length) throw new Error("embedding failed");
  return r.data;
}

async function retrieve(env, q, scope) {
  const [v] = await embed(env, [q]);
  const opts = { topK: 20, returnMetadata: "all" };
  if (scope.root !== "all") opts.filter = { root: scope.root };
  const res = await env.VECTORS.query(v, opts);
  const matches = (res?.matches || []).filter((m) => m.metadata).map((m) => ({ ...m.metadata, score: Math.round(m.score * 1000) / 1000 }));
  return pick(matches, scope, 8, 4);
}

// ---------- answering ----------

function ask(env, ctx, q, scope, history) {
  const enc = new TextEncoder(), { readable, writable } = new TransformStream();
  const w = writable.getWriter(), send = (o) => w.write(enc.encode(JSON.stringify(o) + "\n"));
  ctx.waitUntil((async () => {
    try {
      const hits = await retrieve(env, q, scope);
      await send({ sources: hits.map((h, i) => ({ n: i + 1, root: h.root, path: h.path, kind: h.kind, t: h.t ?? null })) });
      const stream = await env.AI.run(env.AI_CHAT_MODEL || CHAT, {
        messages: buildMessages(q, hits, history), stream: true, max_tokens: 2000, temperature: 0.2,
      });
      const strip = thinkStripper();
      for await (const piece of sseText(stream)) { const t = strip(piece); if (t) await send({ t }); }
      await send({ done: true });
    } catch (e) {
      await send({ error: "The assistant couldn't answer: " + (e && e.message ? e.message : "unknown error") });
    } finally {
      await w.close();
    }
  })());
  return new Response(readable, { headers: { "content-type": "application/x-ndjson; charset=utf-8", "cache-control": "no-store" } });
}

/** The answer's text out of Workers AI's event stream, whichever shape the model streams in. Reasoning is dropped. */
async function* sseText(stream) {
  const reader = stream.pipeThrough(new TextDecoderStream()).getReader();
  let buf = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += value;
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
      if (!line.startsWith("data:")) continue;
      const data = line.slice(5).trim();
      if (!data || data === "[DONE]") continue;
      let o; try { o = JSON.parse(data); } catch { continue; }
      const t = typeof o.response === "string" ? o.response : o.choices?.[0]?.delta?.content;
      if (typeof t === "string" && t) yield t;
    }
  }
}

/** Removes <think>…</think> blocks a reasoning model may stream inline. */
export function thinkStripper() {
  let inside = false, pend = "";
  return (s) => {
    let out = "", x = pend + s; pend = "";
    while (x) {
      const tag = inside ? "</think>" : "<think>", i = x.indexOf(tag);
      if (i >= 0) { if (!inside) out += x.slice(0, i); x = x.slice(i + tag.length); inside = !inside; continue; }
      // keep a possible partial tag for the next piece
      let k = 0; for (let n = Math.min(tag.length - 1, x.length); n > 0; n--) if (tag.startsWith(x.slice(-n))) { k = n; break; }
      if (!inside) out += x.slice(0, x.length - k);
      pend = x.slice(x.length - k); x = "";
    }
    return out;
  };
}

// ---------- indexing ----------

async function readState(env) {
  const o = await env.MAIN.get(STATE);
  const s = o ? await o.json().catch(() => null) : null;
  return s && s.v === 1 ? s : { v: 1, files: {}, updated: null };
}
const writeState = (env, s) => env.MAIN.put(STATE, JSON.stringify({ ...s, updated: new Date().toISOString() }), { httpMetadata: { contentType: "application/json" } });

async function listAll(env) {
  const out = [];
  for (const [root, { bucket, prefix }] of Object.entries(ROOTS)) {
    const b = env[bucket]; if (!b) continue;
    let cursor;
    do {
      const r = await b.list({ prefix, cursor });
      for (const o of r.objects) {
        const rel = o.key.slice(prefix.length);
        if (!rel || rel.endsWith("/") || rel.split("/").some((s) => s.startsWith("."))) continue;   // folders, hidden, trash
        out.push({ root, rel, etag: o.etag, size: o.size });
      }
      cursor = r.truncated ? r.cursor : undefined;
    } while (cursor);
  }
  return out;
}

async function status(env) {
  const s = await readState(env);
  const files = Object.values(s.files);
  return jsonResponse({
    ok: true, ready: ready(env), chat: env.AI_CHAT_MODEL || CHAT, embed: env.AI_EMBED_MODEL || EMBED,
    files: files.length, complete: files.filter((f) => f.done).length, passages: files.reduce((a, f) => a + (f.pos || 0), 0), updated: s.updated,
  });
}

/** One step: forget removed files, then (re)index changed ones a slice at a time, within STEP_CALLS calls. */
export async function indexStep(env) {
  const s = await readState(env), now = await listAll(env);
  const seen = new Set(now.map((f) => f.root + ":" + f.rel));
  let calls = 0;

  for (const key of Object.keys(s.files)) {                       // removed or moved: their vectors go
    if (seen.has(key)) continue;
    const f = s.files[key];
    const ids = await Promise.all(Array.from({ length: f.pos || 0 }, (_, n) => vectorId(f.root, f.rel, n)));
    for (let i = 0; i < ids.length && calls < STEP_CALLS; i += 1000) { await env.VECTORS.deleteByIds(ids.slice(i, i + 1000)); calls++; }
    await env.MAIN.delete(TEXT + f.id + ".txt");
    delete s.files[key];
  }

  for (const f of now) {
    if (calls >= STEP_CALLS) break;
    const key = f.root + ":" + f.rel;
    let st = s.files[key];
    if (st && st.etag === f.etag && st.done) continue;
    if (!st || st.etag !== f.etag) {                              // new or changed: start over (old vectors are overwritten by id)
      const id = (await vectorId(f.root, f.rel, 0)).slice(0, 32);
      st = s.files[key] = { root: f.root, rel: f.rel, etag: f.etag, id, pos: 0, total: null, done: false };
      const text = await sourceText(env, f);
      calls += text.calls;
      await env.MAIN.put(TEXT + id + ".txt", JSON.stringify(text.passages));
    }
    const o = await env.MAIN.get(TEXT + st.id + ".txt");
    const passages = o ? await o.json() : [];
    st.total = passages.length;
    while (st.pos < passages.length && calls + 2 <= STEP_CALLS) {
      const slice = passages.slice(st.pos, st.pos + SLICE);
      const vecs = await embed(env, slice.map((p) => p.text)); calls++;
      const rows = await Promise.all(slice.map(async (p, i) => ({
        id: await vectorId(f.root, f.rel, st.pos + i), values: vecs[i],
        metadata: { root: f.root, path: f.rel, kind: p.kind, text: p.text.slice(0, 1500), ...(p.t != null ? { t: p.t } : {}) },
      })));
      await env.VECTORS.upsert(rows); calls++;
      st.pos += slice.length;
    }
    if (st.pos >= passages.length) st.done = true;
  }

  await writeState(env, s);
  const left = now.filter((f) => { const st = s.files[f.root + ":" + f.rel]; return !st || !st.done || st.etag !== f.etag; }).length;
  return { ok: true, done: left === 0, left, files: now.length };
}

/** A file's passages: its name always; a document's text (Workers AI toMarkdown); a Main recording's transcript. */
async function sourceText(env, f) {
  const passages = [{ text: nameText(f.root, f.rel), kind: "name" }];
  const kind = kindOf(f.rel);
  let calls = 0;
  try {
    if (kind === "doc" && f.size <= MAX_DOC) {
      const o = await env[ROOTS[f.root].bucket].get(ROOTS[f.root].prefix + f.rel);
      if (o) {
        const name = f.rel.split("/").pop();
        const [r] = await env.AI.toMarkdown([{ name, blob: new Blob([await o.arrayBuffer()], { type: o.httpMetadata?.contentType || "application/octet-stream" }) }]);
        calls++;
        const md = r && r.format !== "error" ? String(r.data || "") : "";
        for (const c of chunkText(md)) passages.push({ text: c, kind: "doc" });
      }
    } else if (kind === "media" && f.root === "main") {
      const t = await transcriptFor(env, f.rel);
      for (const c of chunkTranscript(t && t.lines)) passages.push({ text: c.text, t: c.t, kind: "transcript" });
    }
  } catch { /* unreadable: keep the name, so it's still findable */ }
  return { passages, calls };
}
