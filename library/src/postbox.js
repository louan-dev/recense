// Postbox: a mailbox the owner's Claude sessions (web, desktop, CLI; any account) read and write over plain HTTP.
// Outside Cloudflare Access on purpose: a Claude web session cannot sign in, so each account gets its own bearer token.
// Secret POSTBOX_TOKENS = JSON {"<name>": "<sha-256 hex of the token>"}; unset, every /postbox path is a 404.
// Store: one R2 object per message in the MAIN bucket (postbox/m/<ms>-<rand>), so two writers never overwrite each other.
// Rules for Claude web: postbox/rules.md in the same bucket, served token-gated at /postbox/rules (it holds personal notes, never in the repo).
const MAX_TEXT = 4000, PAGE = 200;
const PLAIN = { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" };
const text = (status, body, extra = {}) => new Response(body, { status, headers: { ...PLAIN, ...extra } });

async function sha256Hex(s) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function same(a, b) {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

// the token's name, or null. The token comes from `Authorization: Bearer` or, for a fetch-only web session, from ?t=
export async function postboxWho(req, env, url) {
  let table;
  try { table = JSON.parse(env.POSTBOX_TOKENS || ""); } catch (e) { return null; }
  if (!table || typeof table !== "object") return null;
  const m = (req.headers.get("authorization") || "").match(/^Bearer\s+(\S+)$/i);
  const given = m ? m[1] : url.searchParams.get("t");
  if (!given) return null;
  const h = await sha256Hex(given);
  let who = null;
  for (const [name, want] of Object.entries(table)) if (same(String(want).toLowerCase(), h)) who = name;
  return who;
}

export async function postboxAdd(env, from, body) {
  const t = String(body || "").trim().slice(0, MAX_TEXT);
  if (!t) return null;
  const ms = String(Date.now()).padStart(13, "0");
  const id = `${ms}-${crypto.randomUUID().slice(0, 4)}`;
  await env.MAIN.put(`postbox/m/${id}`, JSON.stringify({ at: new Date(Number(ms)).toISOString(), from, text: t }));
  return id;
}

export async function postboxRead(env, since) {
  const listed = await env.MAIN.list({ prefix: "postbox/m/", startAfter: since ? `postbox/m/${since}` : undefined, limit: PAGE });
  const out = [];
  let last = since || "";
  for (const o of listed.objects) {
    const rec = await (await env.MAIN.get(o.key))?.json().catch(() => null);
    last = o.key.slice("postbox/m/".length);
    if (rec) out.push(`#${last} · ${rec.at} · ${rec.from}\n${rec.text}\n`);
  }
  return { body: out.join("\n"), last, more: listed.truncated };
}

// path is /postbox or /postbox/send or /postbox/rules
export async function postbox(req, env, url, path) {
  if (!env.POSTBOX_TOKENS) return text(404, "Not found");
  const who = await postboxWho(req, env, url);
  if (!who) return text(401, "Unauthorized");
  const method = req.method;

  if (path === "/postbox/rules" && method === "GET") {
    const o = await env.MAIN.get("postbox/rules.md");
    return o ? text(200, await o.text()) : text(404, "No rules page stored yet");
  }
  if (path === "/postbox/send" && method === "GET") {
    const id = await postboxAdd(env, who, url.searchParams.get("text"));
    return id ? text(200, `posted #${id}\n`) : text(400, "Empty text");
  }
  if (path === "/postbox" && method === "POST") {
    const id = await postboxAdd(env, who, await req.text());
    return id ? text(200, `posted #${id}\n`) : text(400, "Empty text");
  }
  if (path === "/postbox" && method === "GET") {
    const r = await postboxRead(env, url.searchParams.get("since"));
    return text(200, r.body || "(nothing new)\n", { "x-postbox-last": r.last, "x-postbox-more": String(r.more) });
  }
  return text(404, "Not found");
}
