// pieces.js: the share lane's one byte layer, browser side (X1). Twin of shared/pieces (Swift); both must make
// byte-identical output on shared/pieces/vectors/v1.json.
//
// An item is a file cut into pieces, each sealed with AES-256-GCM and named by the SHA-256 of its ciphertext, so
// any seed can check and serve a piece without being able to read it. The item key travels only in a link's
// #fragment, which browsers never send to a server.
//
// Keys:   itemKey     = HMAC-SHA256(group secret, "recense.pieces.v1.item" ‖ SHA-256(file))
//         manifestKey = HKDF-SHA256(itemKey, info "recense.pieces.v1.manifest")
//         pieceKey    = HKDF-SHA256(itemKey, info "recense.pieces.v1.piece")
// Piece:  AES-256-GCM(pieceKey, nonce = 4 zero bytes ‖ index as UInt64 big-endian), output ciphertext ‖ tag.
// Safety: GCM breaks if one key seals two different plaintexts under one nonce. The key comes from the file's
//         hash, so an edited file gets a new key; and a piece is only ever re-sealed when its ciphertext hash equals
//         the one in the manifest (servePiece), so a changed file can never emit a second plaintext under the old key.
// Manifest: canonical JSON (sorted keys, minimal escapes, see canon) sealed with manifestKey and a random 12-byte
//         nonce stored in front (the same file can get a different name, so the manifest needs its own nonce);
//         item id = SHA-256 of that blob.
// A link can never be revoked: once fetched, its key is out. Deleting pieces from the seeds only stops later fetches.
(function () {
  "use strict";
  const enc = new TextEncoder();
  const subtle = () => globalThis.crypto.subtle;
  const V = "recense.pieces.v1.";
  const KiB = 1024, GiB = 1024 * 1024 * 1024;

  const hex = b => Array.from(b, x => x.toString(16).padStart(2, "0")).join("");
  const unhex = s => Uint8Array.from(s.match(/../g) || [], h => parseInt(h, 16));
  const b64url = b => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const unb64url = s => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), c => c.charCodeAt(0));
  const cat = (...a) => { const o = new Uint8Array(a.reduce((n, x) => n + x.length, 0)); let i = 0; for (const x of a) { o.set(x, i); i += x.length; } return o; };

  const sha256 = async b => new Uint8Array(await subtle().digest("SHA-256", b));
  const pieceSize = size => (size < GiB ? 256 * KiB : 1024 * KiB);
  const pieceCount = size => Math.ceil(size / pieceSize(size));
  function nonce(i) { const n = new Uint8Array(12); new DataView(n.buffer).setBigUint64(4, BigInt(i)); return n; }

  async function itemKey(groupSecret, fileHash) {
    const k = await subtle().importKey("raw", groupSecret, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    return new Uint8Array(await subtle().sign("HMAC", k, cat(enc.encode(V + "item"), fileHash)));
  }
  async function hkdf(ikm, label) {
    const k = await subtle().importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
    return new Uint8Array(await subtle().deriveBits({ name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: enc.encode(V + label) }, k, 256));
  }
  async function keys(item) {
    return { item, manifest: await hkdf(item, "manifest"), piece: await hkdf(item, "piece") };
  }
  const aes = (raw, use) => subtle().importKey("raw", raw, "AES-GCM", false, [use]);

  async function sealPiece(pieceKey, index, plain) {
    return new Uint8Array(await subtle().encrypt({ name: "AES-GCM", iv: nonce(index) }, await aes(pieceKey, "encrypt"), plain));
  }
  // Checks the name first (any seed could have sent it), then GCM; either failing throws.
  async function openPiece(pieceKey, index, cipher, expectedHash) {
    if (hex(await sha256(cipher)) !== expectedHash) throw new Error("piece " + index + ": hash mismatch");
    return new Uint8Array(await subtle().decrypt({ name: "AES-GCM", iv: nonce(index) }, await aes(pieceKey, "decrypt"), cipher));
  }

  // Canonical JSON, the same bytes Swift writes: keys sorted, strings escape only " \ and U+0000–U+001F (\u00xx).
  function canon(v) {
    if (v === null) return "null";
    if (typeof v === "number") { if (!Number.isSafeInteger(v)) throw new Error("manifest numbers are integers"); return String(v); }
    if (typeof v === "string") return '"' + v.replace(/["\\\u0000-\u001f]/g, c => c === '"' ? '\\"' : c === "\\" ? "\\\\" : "\\u" + c.charCodeAt(0).toString(16).padStart(4, "0")) + '"';
    if (Array.isArray(v)) return "[" + v.map(canon).join(",") + "]";
    return "{" + Object.keys(v).sort().map(k => canon(k) + ":" + canon(v[k])).join(",") + "}";
  }

  // make: seal a whole file held in memory (the page and the tests; the Swift side streams from disk).
  // meta: { name, type, origin, created }; manifestNonce only for test vectors (else random).
  async function make(file, groupSecret, meta, manifestNonce) {
    const fileHash = await sha256(file);
    const k = await keys(await itemKey(groupSecret, fileHash));
    const size = file.length, ps = pieceSize(size), pieces = [];
    for (let i = 0; i < pieceCount(size); i++) pieces.push(hex(await sha256(await sealPiece(k.piece, i, file.subarray(i * ps, (i + 1) * ps)))));
    const manifest = { created: meta.created, file: hex(fileHash), name: meta.name, origin: meta.origin, piece: ps, pieces, size, type: meta.type, v: 1 };
    const mn = manifestNonce || globalThis.crypto.getRandomValues(new Uint8Array(12));
    const sealed = new Uint8Array(await subtle().encrypt({ name: "AES-GCM", iv: mn }, await aes(k.manifest, "encrypt"), enc.encode(canon(manifest))));
    const blob = cat(mn, sealed);
    return { manifest, blob, id: hex(await sha256(blob)), keys: k };
  }
  async function openManifest(item, blob, expectedId) {
    if (expectedId && hex(await sha256(blob)) !== expectedId) throw new Error("manifest: id mismatch");
    const k = await keys(item);
    const plain = await subtle().decrypt({ name: "AES-GCM", iv: blob.subarray(0, 12) }, await aes(k.manifest, "decrypt"), blob.subarray(12));
    return { manifest: JSON.parse(new TextDecoder().decode(plain)), keys: k };
  }
  // servePiece: re-seal piece i from the plain file and refuse unless it is the piece the manifest named; this is the
  // check that stops one key from ever sealing two different plaintexts (an edited file throws "file changed").
  async function servePiece(file, manifest, k, i) {
    const ps = manifest.piece, c = await sealPiece(k.piece, i, file.subarray(i * ps, (i + 1) * ps));
    if (hex(await sha256(c)) !== manifest.pieces[i]) throw new Error("file changed: piece " + i + " no longer matches its manifest");
    return c;
  }

  const link = (host, id, item) => "https://" + host + "/x/" + id + "#" + b64url(item);
  function parseLink(url) {
    const m = String(url).match(/^https:\/\/([^/]+)\/x\/([0-9a-f]{64})#([A-Za-z0-9_-]{43})$/);
    if (!m) throw new Error("not a Recense piece link");
    return { host: m[1], id: m[2], item: unb64url(m[3]) };
  }

  // Download: what is still missing after any drop. have is the set of verified indexes (kept on disk by the caller).
  function download(manifest, k, have) {
    const got = new Map();
    const done = new Set(have || []);
    return {
      missing: () => manifest.pieces.map((_, i) => i).filter(i => !done.has(i)),
      async accept(i, cipher) { const p = await openPiece(k.piece, i, cipher, manifest.pieces[i]); done.add(i); got.set(i, p); return p; },
      have: () => [...done].sort((a, b) => a - b),
      piece: i => got.get(i),
      complete: () => done.size === manifest.pieces.length,
    };
  }

  globalThis.RecensePieces = Object.freeze({ hex, unhex, b64url, unb64url, sha256, pieceSize, pieceCount, nonce, itemKey, keys, sealPiece, openPiece, canon, make, openManifest, servePiece, link, parseLink, download });
})();
