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
import { listEvents, createEvent, updateEvent, addInvitee, dateFacts, TZ_DEFAULT } from "./calendar.js";

const CHAT = "@cf/openai/gpt-oss-120b";       // env.AI_CHAT_MODEL overrides (a var in wrangler.toml)
const FAST = "@cf/openai/gpt-oss-20b";      // env.AI_FAST_MODEL: planning searches and noting memories
const EMBED = "@cf/baai/bge-m3";              // changing it means re-indexing everything (different vectors)
const STATE = "ai/index.json";
const AUTHORITY = "ai/authority.json";
const MEMORY = "ai/memory.json";
const TEXT = "ai/text/";
const ROOTS = { main: { bucket: "MAIN", prefix: "files/" }, archive: { bucket: "ARCHIVE", prefix: "archive/" } };
const MAX_DOC = 24 * 1024 * 1024;              // larger documents are indexed by name only (a step has 128 MB of memory)
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
        messages[0].content += calendarGuide(dateFacts(tz), tz);
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
// Runs in Cloudflare: a one-minute cron calls indexStep(), which does a small, bounded piece of work and remembers where
// it got to in ai/index.json (MAIN). A step never lists everything or reads a whole book:
//   · listing goes one R2 page (≤1000 files) at a time, with the cursor kept in the state;
//   · a document or Main recording is "extracted" once (toMarkdown / transcript, classified, cut into passages) and its
//     passages are stored in slices of SLICE_FILE (ai/text/<id>/<n>.json), then embedded a few batches per step;
//   · everything else (photos, archive recordings, too-large files) is indexed by name, NAMES at a time;
//   · after a full pass, files not seen in it are removed from the index, and the next pass starts 30 minutes later.
const SLICE_FILE = 960;                        // passages per stored slice (ten embedding batches)
const NAMES = 96;                              // name-only files embedded per batch
const BUDGET = 36;                             // subrequests (R2, AI, Vectorize) one step may spend
const REST = 30 * 60 * 1000;                   // pause between full passes
const hostOf = (root) => ROOTS[root];

async function readState(env) {
  const o = await env.MAIN.get(STATE);
  const s = o ? await o.json().catch(() => null) : null;
  return s && s.v === 2 ? s : { v: 2, gen: 1, root: "main", cursor: null, listed: false, todo: [], names: [], active: null, sweep: null, files: {}, passEnded: null, updated: null };
}
const writeState = (env, s) => env.MAIN.put(STATE, JSON.stringify({ ...s, updated: new Date().toISOString() }), { httpMetadata: { contentType: "application/json" } });
const baseId = async (root, rel) => (await vectorId(root, rel, 0)).replace(/-0$/, "");
const wantsText = (root, rel, size) => (kindOf(rel) === "doc" && size <= MAX_DOC) || (kindOf(rel) === "media" && root === "main");

async function status(env) {
  const s = await readState(env), files = Object.values(s.files);
  return jsonResponse({
    ok: true, ready: ready(env), chat: env.AI_CHAT_MODEL || CHAT, embed: env.AI_EMBED_MODEL || EMBED,
    files: files.length, passages: files.reduce((a, f) => a + (f[1] || 0), 0),
    pending: s.todo.length + s.names.length + (s.active ? 1 : 0), listing: s.listed ? "done" : s.root, pass: s.gen,
    passEnded: s.passEnded, updated: s.updated,
  });
}

/** One bounded step of indexing. Returns { ok, done } where done means a full pass has finished with nothing pending. */
export async function indexStep(env) {
  const s = await readState(env);
  if (s.passEnded && !s.active && !s.todo.length && !s.names.length && !s.sweep && Date.now() - Date.parse(s.passEnded) < REST) {
    return { ok: true, done: true, files: Object.keys(s.files).length };
  }
  if (s.passEnded && s.listed && !s.sweep && !s.active && !s.todo.length && !s.names.length) {   // rest is over: a new pass
    s.gen++; s.root = "main"; s.cursor = null; s.listed = false; s.passEnded = null;
  }
  let calls = 1, extracted = false;
  while (calls < BUDGET) {
    if (s.active) { calls += await embedActive(env, s, BUDGET - calls); if (s.active) break; continue; }
    if (s.names.length >= NAMES || (s.listed && s.names.length)) { calls += await embedNames(env, s); continue; }
    if (s.todo.length && !extracted) { calls += await extract(env, s, s.todo.shift()); extracted = true; continue; }
    if (s.todo.length) break;                                       // one extraction per step: it is the heavy part
    if (!s.listed) { calls += await listPage(env, s); continue; }
    if (!s.sweep) s.sweep = Object.entries(s.files).filter(([, f]) => f[2] < s.gen).map(([k]) => k);
    if (s.sweep.length) { calls += await sweepSome(env, s, BUDGET - calls); continue; }
    s.sweep = null; s.passEnded = new Date().toISOString();
    break;
  }
  await writeState(env, s);
  const done = !!s.passEnded && !s.active && !s.todo.length && !s.names.length;
  return { ok: true, done, files: Object.keys(s.files).length, pending: s.todo.length + s.names.length + (s.active ? 1 : 0), listing: s.listed ? "done" : s.root };
}

/** The one-minute cron's work: steps until the pass is done, about 45 s have passed (so runs never overlap), or the
 *  run's subrequest allowance (1,000) is nearly spent. */
// daily: the most steps per UTC day (the per-minute cron passes one). Workers AI's free plan is 10,000 neurons a day for
// everything, so unbounded indexing left nothing for questions (error 4006); hitting 4006 also stops it until tomorrow.
const INDEX_BUDGET = "ai/index-budget.json";
export async function indexRun(env, wallMs = 45000, maxSteps = 24, daily = 0) {
  const t0 = Date.now(), day = new Date().toISOString().slice(0, 10);
  let b = null;
  if (daily) {
    b = (await env.MAIN.get(INDEX_BUDGET).then((o) => o && o.json()).catch(() => null)) || {};
    if (b.day !== day) b = { day, steps: 0 };
    if (b.out || b.steps >= daily) return { ok: true, done: false, resting: true };
  }
  try {
    for (let i = 0; i < maxSteps && Date.now() - t0 < wallMs && !(b && b.steps >= daily); i++) {
      if (b) b.steps++;
      const r = await indexStep(env);
      if (r.done) return r;
    }
  } catch (e) {
    if (b && /4006|neurons/.test(String(e?.message || e))) b.out = true; else throw e;
  } finally {
    if (b) await env.MAIN.put(INDEX_BUDGET, JSON.stringify(b));
  }
  return { ok: true, done: false };
}

/** Lists the next page of the current root; new or changed files go to the queues, unchanged ones are marked seen. */
async function listPage(env, s) {
  const { bucket, prefix } = hostOf(s.root), b = env[bucket];
  const r = b ? await b.list({ prefix, cursor: s.cursor || undefined, limit: 1000 }) : { objects: [], truncated: false };
  for (const o of r.objects) {
    const rel = o.key.slice(prefix.length);
    if (!rel || rel.endsWith("/") || rel.split("/").some((x) => x.startsWith("."))) continue;   // folders, hidden, trash
    const key = s.root + ":" + rel, f = s.files[key];
    if (f && f[0] === o.etag) { f[2] = s.gen; continue; }
    if (wantsText(s.root, rel, o.size)) s.todo.push([key, o.etag]); else s.names.push([key, o.etag]);
  }
  if (r.truncated) s.cursor = r.cursor;
  else { s.cursor = null; const roots = Object.keys(ROOTS), i = roots.indexOf(s.root); if (i + 1 < roots.length) s.root = roots[i + 1]; else s.listed = true; }
  return 1;
}

/** Name-only files, a batch at a time: one passage each. */
async function embedNames(env, s) {
  const batch = s.names.splice(0, NAMES);
  const rows = [];
  for (const [key, etag] of batch) {
    const i = key.indexOf(":"), root = key.slice(0, i), rel = key.slice(i + 1);
    rows.push({ key, etag, root, rel, text: nameText(root, rel) });
  }
  const vecs = await embed(env, rows.map((r) => r.text));
  await env.VECTORS.upsert(await Promise.all(rows.map(async (r, n) => ({
    id: (await baseId(r.root, r.rel)) + "-0", values: vecs[n], metadata: { root: r.root, path: r.rel, kind: "name", auth: "name", text: r.text },
  }))));
  for (const r of rows) s.files[r.key] = [r.etag, 1, s.gen, 0];
  return 2;
}

/** A document or recording: read once, classified, cut into passages, stored in slices; embedding follows. */
async function extract(env, s, [key, etag]) {
  const i = key.indexOf(":"), root = key.slice(0, i), rel = key.slice(i + 1), id = await baseId(root, rel);
  const { passages, calls } = await sourceText(env, root, rel);
  let n = 0, puts = 0;
  for (let k = 0; k < passages.length; k += SLICE_FILE, n++) {
    await env.MAIN.put(`${TEXT}${id}/${n}.json`, JSON.stringify(passages.slice(k, k + SLICE_FILE))); puts++;
  }
  const old = s.files[key];
  s.active = { key, etag, id, slices: n, slice: 0, at: 0, total: passages.length, had: old ? old[1] : 0 };
  return calls + puts;
}

/** Embeds the active file's passages, a batch of SLICE at a time, within the step's budget. */
async function embedActive(env, s, budget) {
  const a = s.active, i = a.key.indexOf(":"), root = a.key.slice(0, i), rel = a.key.slice(i + 1);
  let used = 0;
  if (a.slice >= a.slices) return finishActive(env, s);
  const o = await env.MAIN.get(`${TEXT}${a.id}/${a.slice}.json`); used++;
  const passages = o ? await o.json() : [];
  while (a.at < passages.length && used + 2 <= budget) {
    const batch = passages.slice(a.at, a.at + SLICE), base = a.slice * SLICE_FILE + a.at;
    const vecs = await embed(env, batch.map((p) => p.text));
    await env.VECTORS.upsert(batch.map((p, k) => ({
      id: `${a.id}-${base + k}`, values: vecs[k],
      metadata: { root, path: rel, kind: p.kind, auth: p.auth, text: p.text.slice(0, 1500), ...(p.t != null ? { t: p.t } : {}) },
    })));
    used += 2; a.at += batch.length;
  }
  if (a.at >= passages.length) { a.slice++; a.at = 0; }
  if (a.slice >= a.slices) used += await finishActive(env, s);
  return used;
}

/** The active file is done: record it, and drop vectors left over from a longer earlier version. */
async function finishActive(env, s) {
  const a = s.active;
  let used = 0;
  if (a.had > a.total) {
    const ids = Array.from({ length: Math.min(a.had - a.total, 5000) }, (_, k) => `${a.id}-${a.total + k}`);
    for (let k = 0; k < ids.length; k += 1000) { await env.VECTORS.deleteByIds(ids.slice(k, k + 1000)); used++; }
  }
  s.files[a.key] = [a.etag, a.total, s.gen, a.slices];
  s.active = null;
  return used;
}

/** Files gone since the last pass: their vectors and stored text go. */
async function sweepSome(env, s, budget) {
  let used = 0;
  while (s.sweep.length && used + 2 <= budget) {
    const key = s.sweep.shift(), f = s.files[key];
    if (!f) continue;
    const i = key.indexOf(":"), id = await baseId(key.slice(0, i), key.slice(i + 1));
    const ids = Array.from({ length: Math.min(f[1], 5000) }, (_, k) => `${id}-${k}`);
    for (let k = 0; k < ids.length; k += 1000) { await env.VECTORS.deleteByIds(ids.slice(k, k + 1000)); used++; }
    for (let n = 0; n < (f[3] || 0); n++) { await env.MAIN.delete(`${TEXT}${id}/${n}.json`); used++; }
    delete s.files[key];
  }
  return used;
}

/** A file's passages: its name always; a document's text (Workers AI toMarkdown); a Main recording's transcript. */
async function sourceText(env, root, rel) {
  const passages = [{ text: nameText(root, rel), kind: "name", auth: "name" }];
  const kind = kindOf(rel), { bucket, prefix } = hostOf(root);
  let calls = 0;
  try {
    if (kind === "doc") {
      const o = await env[bucket].get(prefix + rel); calls++;
      if (o) {
        const [r] = await env.AI.toMarkdown([{ name: rel.split("/").pop(), blob: await o.blob() }]); calls++;
        const md = r && r.format !== "error" ? String(r.data || "") : "";
        const chunks = chunkText(md);
        const auth = chunks.length ? await classify(env, rel, md) : "personal";
        if (chunks.length) calls++;
        for (const c of chunks) passages.push({ text: c, kind: "doc", auth });
      }
    } else if (kind === "media" && root === "main") {
      const t = await transcriptFor(env, rel); calls += 3;
      const chunks = chunkTranscript(t && t.lines);
      const auth = chunks.length && (await classify(env, rel, chunks.map((c) => c.text).join("\n"))) === "reference" ? "reference" : "transcript";
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
    const r = await env.AI.run(env.AI_FAST_MODEL || FAST, { messages: classifyMessages(path, String(text).slice(0, 3000)), max_tokens: 800, temperature: 0 });
    return parseAuth(typeof r?.response === "string" ? r.response : r?.choices?.[0]?.message?.content);
  } catch { return "personal"; }
}
