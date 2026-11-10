// pieces.js (share lane X1): the browser twin of shared/pieces (Swift). Both must reproduce shared/pieces/vectors/v1.json
// byte for byte; the Swift side checks the same file in `swift test`. Also: the key invariant (an edited file gets a new
// key; a changed file is refused under its old key), a flipped byte caught twice, resume after a drop, link parsing.
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const ctx = { crypto: globalThis.crypto, TextEncoder, TextDecoder, atob, btoa };
ctx.globalThis = ctx;
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(new URL("../src/client/pieces.js", import.meta.url), "utf8"), ctx);
const P = ctx.RecensePieces;
const V = JSON.parse(fs.readFileSync(new URL("../../shared/pieces/vectors/v1.json", import.meta.url), "utf8"));
const plain = n => Uint8Array.from({ length: n }, (_, i) => (i * 31 + 7) & 255);
const group = P.unhex(V.groupSecret);
const make = (c, file) => P.make(file, group, c, P.unhex(c.manifestNonce));
let n = 0;
const ok = (name) => { n++; console.log("ok  ", name); };

assert.ok(Object.isFrozen(P));
assert.equal(V.cases.length, 2);

// 1. the vectors, field by field
for (const c of V.cases) {
  const r = await make(c, plain(c.size));
  assert.equal(r.manifest.file, c.fileHash, c.label);
  assert.equal(P.hex(r.keys.item), c.itemKey, c.label);
  assert.equal(P.hex(r.keys.manifest), c.manifestKey, c.label);
  assert.equal(P.hex(r.keys.piece), c.pieceKey, c.label);
  assert.equal(r.manifest.piece, c.pieceSize, c.label);
  assert.deepEqual([...r.manifest.pieces], c.pieces, c.label);
  assert.equal(P.canon(r.manifest), c.manifest, c.label);
  assert.equal(P.hex(r.blob), c.blob, c.label);
  assert.equal(r.id, c.id, c.label);
  assert.equal(P.link("seed.example", r.id, r.keys.item), c.link, c.label);
}
ok("vectors: every field byte-identical (Swift checks the same file)");

// 2. a recipient opens the manifest from the link alone; a blob under the wrong id is refused
for (const c of V.cases) {
  const l = P.parseLink(c.link);
  const { manifest } = await P.openManifest(l.item, P.unhex(c.blob), l.id);
  assert.equal(manifest.name, c.name);
  assert.deepEqual([...manifest.pieces], c.pieces);
}
await assert.rejects(P.openManifest(P.unhex(V.cases[0].itemKey), P.unhex(V.cases[0].blob), V.cases[1].id), /id mismatch/);
ok("manifest opens from the link; wrong id refused");

// 3. the key is only ever after "#"
{
  const c = V.cases[0], before = c.link.split("#")[0];
  assert.ok(!before.includes(P.b64url(P.unhex(c.itemKey))));
  assert.throws(() => P.parseLink(before));
  assert.throws(() => P.parseLink(before + "#short"));
}
ok("the key never appears before the fragment");

// 4. a flipped byte: the name fails, and GCM fails even if a seed renames it
{
  const t = V.tamper, c = V.cases[t.case], file = plain(c.size);
  const r = await make(c, file);
  const bad = Uint8Array.from(await P.servePiece(file, r.manifest, r.keys, t.piece));
  bad[t.byte] ^= t.xor;
  await assert.rejects(P.openPiece(r.keys.piece, t.piece, bad, c.pieces[t.piece]), /hash mismatch/);
  await assert.rejects(P.openPiece(r.keys.piece, t.piece, bad, P.hex(await P.sha256(bad))));
}
ok("a flipped byte is caught by the hash and by GCM");

// 5. the key invariant: an edited file gets a new key; a changed file is refused under the old one
{
  const e = V.edited, c = V.cases[e.case], file = plain(c.size);
  const edited = Uint8Array.from(file); edited[e.byte] ^= e.xor;
  assert.equal(P.hex((await make(c, edited)).keys.item), e.itemKey);
  assert.notEqual(e.itemKey, c.itemKey);
  const r = await make(c, file);
  const changed = Uint8Array.from(file); changed[c.pieceSize + 5] = 0xff;   // edited after sealing, in piece 1
  await assert.rejects(P.servePiece(changed, r.manifest, r.keys, 1), /file changed: piece 1/);
  for (const i of [0, 2]) assert.equal(P.hex(await P.sha256(await P.servePiece(changed, r.manifest, r.keys, i))), c.pieces[i]);
}
ok("edited file → new key; changed file refused under its old key");

// 6. resume: after a drop only `have` survives, and only the rest is fetched
{
  const c = V.cases[0], file = plain(c.size);
  const r = await make(c, file);
  const got = new Map();
  const first = P.download(r.manifest, r.keys);
  got.set(0, await first.accept(0, await P.servePiece(file, r.manifest, r.keys, 0)));
  const again = P.download(r.manifest, r.keys, first.have());
  assert.deepEqual([...again.missing()], [1, 2]);
  for (const i of again.missing()) got.set(i, await again.accept(i, await P.servePiece(file, r.manifest, r.keys, i)));
  assert.ok(again.complete());
  const out = new Uint8Array(c.size); let o = 0;
  for (let i = 0; i < 3; i++) { out.set(got.get(i), o); o += got.get(i).length; }
  assert.deepEqual(out, file);
}
ok("resume after a drop fetches only the missing pieces");

assert.equal(P.pieceSize(0), 262144);
assert.equal(P.pieceCount(0), 0);
assert.equal(P.pieceCount(262145), 2);
assert.equal(P.pieceSize(2 ** 30), 1048576);
ok("piece sizes");
console.log(`pieces.test: ${n} groups ok`);
