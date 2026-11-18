// Regression guard: BUG-30 (a Listen episode save is conditional on the ETag: a concurrent newer save is never overwritten)
import assert from "node:assert/strict";
import { listenApi, listenKey } from "../src/listen.js";

function bucket() {
  const m = new Map(); let n = 0;
  const b = {
    m, beforePut: null,
    async get(k) { const o = m.get(k); return o ? { etag: o.etag, json: async () => JSON.parse(o.text) } : null; },
    async put(k, text, opts = {}) {
      if (b.beforePut && k.startsWith("keep/listen/") && !k.endsWith("index.json")) { const h = b.beforePut; b.beforePut = null; await h(); }
      const o = m.get(k), c = opts.onlyIf;
      if (c?.etagMatches && (!o || o.etag !== c.etagMatches)) return null;
      if (c?.etagDoesNotMatch === "*" && o) return null;
      m.set(k, { text, etag: "e" + ++n });
      return { etag: "e" + n };
    },
  };
  return b;
}
const put = (env, key, ep) => listenApi(new Request("https://g.test/x", { method: "PUT", body: JSON.stringify(ep) }), env, `/main/api/listen/${key}`, "PUT");
const title = "Episode One", key = await listenKey(title);
const ep = (updated, said) => ({ title, updated, heard: "en", sentences: [{ id: "0", heard: "hi", said, at: 0 }] });
const stored = (env) => JSON.parse(env.KEEP.m.get(`keep/listen/${key}.json`).text);
const theirs = (env, updated) => async () => { await env.KEEP.put(`keep/listen/${key}.json`, JSON.stringify({ ...ep(updated, "theirs"), key })); };

{ // a concurrent newer writer lands between our read and our put: ours must lose, theirs must stay
  const env = { KEEP: bucket() };
  assert.equal((await put(env, key, ep(1, "a"))).status, 200);
  env.KEEP.beforePut = theirs(env, 9);
  assert.equal((await put(env, key, ep(5, "ours"))).status, 409);
  assert.equal(stored(env).updated, 9, "the concurrent newer save survives");
}
{ // a concurrent OLDER writer: ours is newer, so after one re-read it still lands
  const env = { KEEP: bucket() };
  assert.equal((await put(env, key, ep(1, "a"))).status, 200);
  env.KEEP.beforePut = theirs(env, 2);
  assert.equal((await put(env, key, ep(5, "ours"))).status, 200);
  assert.equal(stored(env).updated, 5);
}
{ // first save of an episode that someone else creates at the same moment
  const env = { KEEP: bucket() };
  env.KEEP.beforePut = theirs(env, 9);
  assert.equal((await put(env, key, ep(5, "ours"))).status, 409);
  assert.equal(stored(env).updated, 9);
}
console.log("ok listen: conditional episode save");
