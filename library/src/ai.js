// The assistant (owner-only, under /main/api/ai/…; the /main gate and sameSite() in worker.js run first).
//   POST /main/api/ai/ask     { q, scope: { root: "main"|"archive"|"all", path }, history }  → NDJSON stream:
//                             {sources:[…]} first, then {t:"…"} pieces of the answer, then {done:true} (or {error})
//   POST /main/api/ai/search  { q, scope } → { hits }
//   GET  /main/api/ai/status  → how much is indexed
//   POST /main/api/ai/index   → one indexing step; call until { done: true } (the nightly cron also steps)
//   GET  /main/api/ai/authority            → the owner's corrections of what a file or folder is worth as evidence
//   PUT  /main/api/ai/authority { root, path, auth: "reference"|"personal"|null } → set or clear one (a folder covers what's in it)
//   GET  /main/api/ai/memory  → what it remembers about the owner;  POST { text } adds one;  DELETE ?id=… forgets one
// After each answer a small model notes durable things the owner said about themselves (ai/memory.json in MAIN); they go into
// every later answer. Before searching, the same small model turns the question into up to three searches, so "should I meet a
// friend at 5 pm?" also finds the owner's reflections on evenings and energy.
// Calendar questions (the planner flags them) run with tools instead of streaming: list_events reads the owner's own
// calendar (Sync's CalDAV store, binding CALENDAR) and their iCloud calendars (the 30-minute backup); create_event,
// update_event and add_invitee write only the owner's own calendar (calendar.js). An invite gives a /c/<token>.ics link.
// Each document is classified once when indexed (published reference vs the owner's personal writing, ai-core.js); the
// owner's corrections (ai/authority.json in MAIN) win over that at question time, so fixing one needs no re-indexing.
//
// Runs on Workers AI (env.AI) with a Vectorize index (env.VECTORS, 1024 dims, cosine, metadata index on "root").
// The owner's documents are the authority; the model may add general knowledge only where they are silent (ai-core.js).
// Indexing works in small steps so a 3,000-page book never meets a request's limits: a document's text is extracted
// once (ai/text/<id>.txt in MAIN) and then embedded a slice at a time; ai/index.json in MAIN remembers where it got to.
import { jsonResponse } from "./common.js";
import { transcriptFor } from "./transcript.js";
import { kindOf, chunkText, chunkTranscript, nameText, pick, buildMessages, vectorId, classifyMessages, parseAuth, AUTH,
  planMessages, parseQueries, memoryMessages, applyMemory, wantsCalendar, CALENDAR_TOOLS, calendarGuide } from "./ai-core.js";
import { listEvents, createEvent, updateEvent, addInvitee, showLocal, TZ_DEFAULT } from "./calendar.js";

const CHAT = "@cf/openai/gpt-oss-120b";       // env.AI_CHAT_MODEL overrides (a var in wrangler.toml)
const FAST = "@cf/openai/gpt-oss-20b";      // env.AI_FAST_MODEL: planning searches and noting memories
const EMBED = "@cf/baai/bge-m3";              // changing it means re-indexing everything (different vectors)
const STATE = "ai/index.json";
const AUTHORITY = "ai/authority.json";
const MEMORY = "ai/memory.json";
const TEXT = "ai/text/";
const ROOTS = { main: { bucket: "MAIN", prefix: "files/" }, archive: { bucket: "ARCHIVE", prefix: "chauphan/" } };
const MAX_DOC = 40 * 1024 * 1024;              // larger documents are indexed by name only
const SLICE = 96;                              // passages embedded per call
const STEP_CALLS = 24;                         // AI / Vectorize calls one step may make

const ready = (env) => !!(env.AI && env.VECTORS);
const notReady = () => jsonResponse({ ok: false, error: "The assistant isn't set up yet (Workers AI and Vectorize bindings)." }, 503);

export async function aiRoute(req, env, ctx, url, path, method) {
  if (path === "/main/api/ai/status" && method === "GET") return status(env);
  if (path === "/main/api/ai/authority" && method === "GET") return jsonResponse({ ok: true, rules: await readAuthority(env) });
  if (path === "/main/api/ai/authority" && method === "PUT") return setAuthority(req, env);
  if (path === "/main/api/ai/memory") return memoryRoute(req, env, url, method);
  if (!ready(env)) return notReady();
  if (path === "/main/api/ai/index" && method === "POST") return jsonResponse(await indexStep(env));
  if (method !== "POST") return new Response("Method not allowed", { status: 405 });
  let body;
  try { body = await req.json(); } catch { return new Response("Bad JSON", { status: 400 }); }
  const q = String(body?.q || "").trim().slice(0, 4000);
  if (!q) return new Response("Empty question", { status: 400 });
  const scope = cleanScope(body.scope);
  if (path === "/main/api/ai/search") return jsonResponse({ ok: true, hits: (await retrieve(env, [q], scope)).map(publicHit) });
  if (path === "/main/api/ai/ask") return ask(env, ctx, q, scope, body.history, (url || new URL(req.url)).origin);
  return new Response("Not found", { status: 404 });
}

function cleanScope(s) {
  const root = s && ["main", "archive", "all"].includes(s.root) ? s.root : "all";
  const path = root === "all" ? "" : String(s?.path || "").replace(/^\/+|\/+$/g, "").slice(0, 1024);
  return { root, path };
}

const publicHit = (h) => ({ root: h.root, path: h.path, kind: h.kind, auth: h.auth, t: h.t ?? null, text: h.text, score: h.score });

// ---------- the owner's corrections of authority ----------

async function readAuthority(env) {
  const o = await env.MAIN.get(AUTHORITY);
  const r = o ? await o.json().catch(() => null) : null;
  return r && typeof r === "object" && !Array.isArray(r) ? r : {};
}

async function setAuthority(req, env) {
  let b; try { b = await req.json(); } catch { return new Response("Bad JSON", { status: 400 }); }
  const root = ["main", "archive"].includes(b?.root) ? b.root : null;
  const path = String(b?.path ?? "").replace(/^\/+|\/+$/g, "").slice(0, 1024);
  if (!root || (b.auth !== null && !AUTH.includes(b.auth))) return new Response("Bad rule", { status: 400 });
  const rules = await readAuthority(env), key = root + ":" + path;
  if (b.auth === null) delete rules[key]; else rules[key] = b.auth;
  await env.MAIN.put(AUTHORITY, JSON.stringify(rules), { httpMetadata: { contentType: "application/json" } });
  return jsonResponse({ ok: true, rules });
}

/** The owner's rule for a passage, if any: the longest matching file or folder (or the whole root, path ""). */
export function ruleFor(rules, root, path) {
  let best = null, len = -1;
  for (const [k, v] of Object.entries(rules)) {
    const i = k.indexOf(":"), r = k.slice(0, i), p = k.slice(i + 1);
    if (r !== root || !(p === "" || path === p || path.startsWith(p + "/"))) continue;
    if (p.length > len) { best = v; len = p.length; }
  }
  return best;
}

async function embed(env, texts) {
  const r = await env.AI.run(env.AI_EMBED_MODEL || EMBED, { text: texts });
  if (!r || !Array.isArray(r.data) || r.data.length !== texts.length) throw new Error("embedding failed");
  return r.data;
}

/** The passages that bear on any of the queries: one embedding call, one Vectorize query each, best score per passage. */
async function retrieve(env, queries, scope) {
  const vecs = await embed(env, queries);
  const opts = { topK: 20, returnMetadata: "all" };
  if (scope.root !== "all") opts.filter = { root: scope.root };
  const results = await Promise.all(vecs.map((v) => env.VECTORS.query(v, opts)));
  const best = new Map();
  for (const res of results) for (const m of res?.matches || []) {
    if (!m.metadata) continue;
    const had = best.get(m.id);
    if (!had || m.score > had.score) best.set(m.id, m);
  }
  const rules = await readAuthority(env);
  const matches = [...best.values()].sort((a, b) => b.score - a.score).map((m) => {
    const h = { ...m.metadata, score: Math.round(m.score * 1000) / 1000 };
    const r = h.auth !== "name" && ruleFor(rules, h.root, h.path);
    if (r) h.auth = r === "personal" && h.kind === "transcript" ? "transcript" : r;
    return h;
  });
  return pick(matches, scope, 10, 4);
}

/** Up to three searches for the question (the question itself first), and whether it is about the calendar. */
async function plan(env, q, history) {
  let r = null;
  try { r = reply(await env.AI.run(env.AI_FAST_MODEL || FAST, { messages: planMessages(q, history), max_tokens: 600, temperature: 0 })); } catch { r = null; }
  return { queries: parseQueries(r, q), calendar: wantsCalendar(r, q, history) };
}

const reply = (r) => (typeof r?.response === "string" ? r.response : r?.choices?.[0]?.message?.content);

// ---------- memory ----------

async function readMemory(env) {
  const o = await env.MAIN.get(MEMORY);
  const r = o ? await o.json().catch(() => null) : null;
  return Array.isArray(r) ? r : [];
}
const writeMemory = (env, m) => env.MAIN.put(MEMORY, JSON.stringify(m), { httpMetadata: { contentType: "application/json" } });

async function memoryRoute(req, env, url, method) {
  const mem = await readMemory(env);
  if (method === "GET") return jsonResponse({ ok: true, memories: mem });
  if (method === "DELETE") {
    const id = url ? url.searchParams.get("id") : new URL(req.url).searchParams.get("id");
    const next = mem.filter((m) => m.id !== id);
    if (next.length === mem.length) return new Response("No such memory", { status: 404 });
    await writeMemory(env, next);
    return jsonResponse({ ok: true, memories: next });
  }
  if (method === "POST") {
    let b; try { b = await req.json(); } catch { return new Response("Bad JSON", { status: 400 }); }
    const text = String(b?.text || "").trim();
    if (!text) return new Response("Empty memory", { status: 400 });
    const { memories } = applyMemory(mem, JSON.stringify({ remember: [text] }));
    await writeMemory(env, memories);
    return jsonResponse({ ok: true, memories });
  }
  return new Response("Method not allowed", { status: 405 });
}

/** After an answer: what the owner said about themselves worth keeping, and memories they asked to drop. */
async function remember(env, q, answer) {
  try {
    const mem = await readMemory(env);
    const r = await env.AI.run(env.AI_FAST_MODEL || FAST, { messages: memoryMessages(q, answer, mem), max_tokens: 800, temperature: 0 });
    const { memories, changed } = applyMemory(mem, reply(r));
    if (changed) await writeMemory(env, memories);
  } catch { /* a missed memory is not worth failing over */ }
}

// ---------- answering ----------

function ask(env, ctx, q, scope, history, origin) {
  const enc = new TextEncoder(), { readable, writable } = new TransformStream();
  const w = writable.getWriter(), send = (o) => w.write(enc.encode(JSON.stringify(o) + "\n"));
  ctx.waitUntil((async () => {
    let answer = "", ok = false;
    try {
      const [{ queries, calendar }, memories] = await Promise.all([plan(env, q, history), readMemory(env)]);
      const hits = await retrieve(env, queries, scope);
      await send({ sources: hits.map((h, i) => ({ n: i + 1, root: h.root, path: h.path, kind: h.kind, auth: h.auth, t: h.t ?? null })) });
      const messages = buildMessages(q, hits, history, memories);
      if (calendar) {
        const tz = env.OWNER_TZ || TZ_DEFAULT;
        messages[0].content += calendarGuide(showLocal(Date.now(), tz), tz);
        answer = await withTools(env, messages, origin, send);
        if (answer) await send({ t: answer });
      } else {
        const stream = await env.AI.run(env.AI_CHAT_MODEL || CHAT, { messages, stream: true, max_tokens: 2000, temperature: 0.2 });
        const strip = thinkStripper();
        for await (const piece of sseText(stream)) { const t = strip(piece); if (t) { answer += t; await send({ t }); } }
      }
      await send({ done: true });
      ok = true;
    } catch (e) {
      await send({ error: "The assistant couldn't answer: " + (e && e.message ? e.message : "unknown error") });
    } finally {
      await w.close();
    }
    if (ok) await remember(env, q, answer);
  })());
  return new Response(readable, { headers: { "content-type": "application/x-ndjson; charset=utf-8", "cache-control": "no-store" } });
}

/** Lets the model call the calendar tools until it answers (at most 6 rounds). Progress goes to the page as {tool, ok}. */
async function withTools(env, messages, origin, send) {
  for (let round = 0; round < 6; round++) {
    const r = await env.AI.run(env.AI_CHAT_MODEL || CHAT, { messages, tools: CALENDAR_TOOLS, max_tokens: 2000, temperature: 0.2 });
    const msg = r?.choices?.[0]?.message || {};
    const content = typeof r?.response === "string" ? r.response : msg.content || "";
    const calls = (Array.isArray(r?.tool_calls) ? r.tool_calls : Array.isArray(msg.tool_calls) ? msg.tool_calls : []).map((c, i) => ({
      id: c.id || `call_${round}_${i}`, name: c.function?.name ?? c.name, args: c.function?.arguments ?? c.arguments ?? {},
    }));
    if (!calls.length) { const strip = thinkStripper(); return strip(String(content || "")).trim(); }
    messages.push({ role: "assistant", content: content || "", tool_calls: calls.map((c) => ({ id: c.id, type: "function", function: { name: c.name, arguments: typeof c.args === "string" ? c.args : JSON.stringify(c.args) } })) });
    for (const c of calls) {
      let result;
      try {
        const args = typeof c.args === "string" ? JSON.parse(c.args || "{}") : c.args;
        result = await runTool(env, c.name, args, origin);
      } catch (e) { result = { ok: false, error: e && e.message ? e.message : String(e) }; }
      await send({ tool: c.name, ok: result.ok !== false });
      messages.push({ role: "tool", tool_call_id: c.id, name: c.name, content: JSON.stringify(result).slice(0, 12000) });
    }
  }
  return "I couldn't finish that with the calendar; please try again or say it differently.";
}

async function runTool(env, name, a, origin) {
  if (name === "list_events") {
    const r = await listEvents(env, a.start_date, a.end_date);
    const events = r.events.slice(0, 80).map(({ start, end, ...e }) => e);
    return { ok: true, timezone: r.tz, count: r.events.length, events, ...(r.events.length > 80 ? { note: "first 80 shown" } : {}),
      ...(r.partial ? { note: "the iCloud calendars are still being read; some events may be missing" } : {}) };
  }
  if (name === "create_event") return createEvent(env, a);
  if (name === "update_event") return updateEvent(env, a);
  if (name === "add_invitee") return addInvitee(env, a, origin);
  return { ok: false, error: "unknown tool " + name };
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
        metadata: { root: f.root, path: f.rel, kind: p.kind, auth: p.auth, text: p.text.slice(0, 1500), ...(p.t != null ? { t: p.t } : {}) },
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
  const passages = [{ text: nameText(f.root, f.rel), kind: "name", auth: "name" }];
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
        const chunks = chunkText(md);
        const auth = chunks.length ? await classify(env, f.rel, md) : "personal";
        if (chunks.length) calls++;
        for (const c of chunks) passages.push({ text: c, kind: "doc", auth });
      }
    } else if (kind === "media" && f.root === "main") {
      const t = await transcriptFor(env, f.rel);
      const chunks = chunkTranscript(t && t.lines);
      const auth = chunks.length && (await classify(env, f.rel, chunks.map((c) => c.text).join("\n"))) === "reference" ? "reference" : "transcript";
      if (chunks.length) calls++;
      for (const c of chunks) passages.push({ text: c.text, t: c.t, kind: "transcript", auth });
    }
  } catch { /* unreadable: keep the name, so it's still findable */ }
  return { passages, calls };
}

/** Published reference or the owner's personal writing, decided by the chat model from the name and opening text.
 *  Anything that fails or is unclear counts as personal: nothing is trusted as fact unless it looks published. */
async function classify(env, path, text) {
  try {
    const r = await env.AI.run(env.AI_CHAT_MODEL || CHAT, { messages: classifyMessages(path, String(text).slice(0, 3000)), max_tokens: 800, temperature: 0 });
    return parseAuth(typeof r?.response === "string" ? r.response : r?.choices?.[0]?.message?.content);
  } catch { return "personal"; }
}
