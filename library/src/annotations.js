// Annotations: notes pinned to a moment (t, ms) or a spot (x, y in 0..1) of a Main file.
//
// The owner reads and writes them at /main/api/annotations; an invited person at
// /m/<token>/api/annotations, only with the annotate permission, only in their folder, and
// deleting only their own (matched by the invitation's id, never by a display name).
// Stored per item under annotations/<path>.json in MAIN: { items: [{ id, by, inv, at, text, t?, x?, y? }] }.

import { OWNER, cleanPath, jsonResponse } from "./common.js";
import { hasDB, annotationsGet, annotationsSave, annotationsMove } from "./d1.js";

const PREFIX = "annotations/";
const TEXT_MAX = 2000;
const ITEMS_MAX = 500;

const keyOf = (rel) => PREFIX + rel + ".json";

export async function readAnnotations(env, rel) {
  if (hasDB(env)) return annotationsGet(env, rel);
  try {
    const o = await env.MAIN.get(keyOf(rel));
    const j = o ? await o.json() : null;
    return Array.isArray(j && j.items) ? j.items : [];
  } catch (e) {
    return [];
  }
}

const save = (env, rel, items) =>
  hasDB(env)
    ? annotationsSave(env, rel, items)
    : items.length
    ? env.MAIN.put(keyOf(rel), JSON.stringify({ items }), { httpMetadata: { contentType: "application/json" } })
    : env.MAIN.delete(keyOf(rel));

const num = (v, lo, hi) => (typeof v === "number" && Number.isFinite(v) && v >= lo && v <= hi ? v : undefined);

// One change to an item's annotations. who = { by, inv } (inv null = the owner).
//   { op: "add", text, t?, x?, y? }   { op: "del", aid }
// -> Response
export async function annotationChange(env, rel, b, who) {
  const items = await readAnnotations(env, rel);

  if (b.op === "add") {
    const text = String(b.text || "").trim().slice(0, TEXT_MAX);
    if (!text) return new Response("Empty", { status: 400 });
    if (items.length >= ITEMS_MAX) return new Response("Too many", { status: 413 });
    const a = { id: crypto.randomUUID().slice(0, 8), by: who.by, inv: who.inv, at: Date.now(), text };
    for (const k of ["t", "x", "y"]) {
      const v = num(b[k], 0, k === "t" ? 864e5 : 1);
      if (v !== undefined) a[k] = v;
    }
    items.push(a);
  } else if (b.op === "del") {
    const i = items.findIndex((a) => a.id === b.aid);
    if (i < 0) return new Response("Not found", { status: 404 });
    // a participant removes only what their own invitation wrote; the owner removes anything
    if (who.inv && items[i].inv !== who.inv) return new Response("Not found", { status: 404 });
    items.splice(i, 1);
  } else {
    return new Response("Bad request", { status: 400 });
  }

  await save(env, rel, items);
  return jsonResponse({ ok: true, items: items.map((a) => pubOf(a, who.inv)) });
}

// what a reader sees: never the invitation id, only whether it is theirs
export const pubOf = (a, inv = null) => ({ id: a.id, by: a.by, at: a.at, text: a.text, t: a.t, x: a.x, y: a.y, mine: inv ? a.inv === inv : !a.inv });

// GET /main/api/annotations?path=<rel>    PUT /main/api/annotations  { path, op, … }
export async function ownerAnnotationApi(req, env, url) {
  if (req.method === "GET") {
    const rel = cleanPath(url.searchParams.get("path") || "");
    if (!rel) return new Response("Bad path", { status: 400 });
    return jsonResponse({ items: (await readAnnotations(env, rel)).map((a) => pubOf(a)) });
  }
  if (req.method !== "PUT") return new Response("Method not allowed", { status: 405 });
  let b;
  try {
    b = await req.json();
  } catch (e) {
    return new Response("Bad request", { status: 400 });
  }
  const rel = cleanPath(String((b && b.path) || ""));
  if (!rel || !(await env.MAIN.head("files/" + rel))) return new Response("Not found", { status: 404 });
  return annotationChange(env, rel, b, { by: OWNER, inv: null });
}

// A file was renamed or deleted (to = null): its annotations follow it.
export async function moveAnnotations(env, from, to) {
  if (hasDB(env)) return annotationsMove(env, from, to);
  const items = await readAnnotations(env, from);
  if (!items.length) return;
  if (to) await save(env, to, items);
  await env.MAIN.delete(keyOf(from));
}
