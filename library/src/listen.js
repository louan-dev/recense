// What the iPhone and iPad heard with Listen (notes item 31), one transcript per episode, kept with Recense's in the
// KEEP bucket (recense-tmp) so the Mac can read them. Owner-only (/main is behind Access).
//   keep/listen/index.json   { episodes: { <key>: { title, heard, into, count, updated } } }
//   keep/listen/<key>.json   { key, title, heard, into, place, updated, sentences: [{ id, heard, said, at }] }
// key = 24 hex of sha-256("listen:" + the title lower-cased with spaces collapsed), the same in the app (Listen.swift)
// and in Recense, which looks a playing item's title up in index.json.
//   GET  /main/api/listen          the index
//   GET  /main/api/listen/<key>    one episode
//   PUT  /main/api/listen/<key>    save one episode (the newer `updated` wins) and its index entry
// One store for all three (row 31 unification): every save is also written in the layout Recense and Gallery share,
//   keep/<key>/asr.json (segments: id, start, end, text) and keep/<key>/tr/<into>.json (lines: { src, text }),
// so a transcript made on the iPhone, the iPad or the Mac is found in the same place. A timed transcript Recense or
// Gallery made there is never replaced (only one marked `from: "listen"` is).
import { jsonResponse } from "./common.js";

const KEY_RE = /^[0-9a-f]{24}$/;
const JSON_TYPE = { httpMetadata: { contentType: "application/json" } };

export async function listenKey(title) {
  const norm = "listen:" + String(title).toLowerCase().replace(/\s+/g, " ").trim();
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(norm));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 24);
}

async function read(env, name) {
  const o = await env.KEEP.get(name).catch(() => null);
  return o ? { body: await o.json().catch(() => null), etag: o.etag } : null;
}

export async function listenApi(req, env, path, method) {
  const key = path.slice("/main/api/listen".length).replace(/^\//, "");
  if (!key) {
    if (method !== "GET") return jsonResponse({ error: "Method not allowed" }, 405);
    return jsonResponse((await read(env, "keep/listen/index.json"))?.body || { episodes: {} });
  }
  if (!KEY_RE.test(key)) return jsonResponse({ error: "No such episode" }, 404);
  const name = `keep/listen/${key}.json`;
  if (method === "GET") {
    const got = await read(env, name);
    return got?.body ? jsonResponse(got.body) : jsonResponse({ error: "No such episode" }, 404);
  }
  if (method !== "PUT") return jsonResponse({ error: "Method not allowed" }, 405);
  let ep;
  try {
    ep = await req.json();
  } catch {
    return jsonResponse({ error: "Not JSON" }, 400);
  }
  if (!ep || typeof ep.title !== "string" || !Array.isArray(ep.sentences)) return jsonResponse({ error: "Needs title and sentences" }, 400);
  if ((await listenKey(ep.title)) !== key) return jsonResponse({ error: "Key doesn't match the title" }, 400);
  const have = (await read(env, name))?.body;
  if (have && (have.updated || 0) > (ep.updated || 0)) return jsonResponse(have, 409);  // someone saved newer: take it
  ep.key = key;
  await env.KEEP.put(name, JSON.stringify(ep), JSON_TYPE);
  // the index: read, change one entry, put on its etag; on a race, once more
  for (let i = 0; i < 3; i++) {
    const idx = (await read(env, "keep/listen/index.json")) || { body: null, etag: null };
    const body = idx.body || { episodes: {} };
    body.episodes[key] = { title: ep.title, heard: ep.heard, into: ep.into, count: ep.sentences.length, updated: ep.updated || Date.now() };
    const onlyIf = idx.etag ? { etagMatches: idx.etag } : { etagDoesNotMatch: "*" };
    if (await env.KEEP.put("keep/listen/index.json", JSON.stringify(body), { ...JSON_TYPE, onlyIf }).catch(() => null)) break;
  }
  await shareInKeep(env, key, ep).catch(() => null);
  return jsonResponse({ ok: true, key });
}

async function shareInKeep(env, key, ep) {
  const asrName = `keep/${key}/asr.json`;
  const have = await read(env, asrName);
  if (have?.body && have.body.from !== "listen") return;
  const ss = ep.sentences.filter((x) => x && typeof x.heard === "string");
  const segments = ss.map((x, i) => ({
    id: String(x.id ?? i),
    start: +x.at || 0,
    end: +(ss[i + 1]?.at ?? x.at) || 0,
    text: x.heard,
    ...(ep.heard ? { lang: ep.heard } : {}),
  }));
  const onlyIf = have ? { etagMatches: have.etag } : { etagDoesNotMatch: "*" };
  await env.KEEP.put(asrName, JSON.stringify({ from: "listen", title: ep.title, segments }), { ...JSON_TYPE, onlyIf });
  if (!ep.into || !/^[a-z]{2,3}(-[A-Za-z0-9]+)?$/.test(ep.into)) return;
  const lines = {};
  for (const [i, x] of ss.entries()) if (x.said) lines[String(x.id ?? i)] = { src: x.heard, text: x.said };
  await env.KEEP.put(`keep/${key}/tr/${ep.into}.json`, JSON.stringify({ from: "listen", lines }), JSON_TYPE);
}
