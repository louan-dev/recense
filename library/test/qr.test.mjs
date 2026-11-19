// QR encoder (src/client/qr.js), run in node: size by version, finder patterns, deterministic, rejects overlong input.
// Decoding was proven separately with macOS CoreImage (see the commit). Run with `npm test`.
import { readFileSync } from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";
const ctx = vm.createContext({ TextEncoder });
vm.runInContext(readFileSync(new URL("../src/client/qr.js", import.meta.url), "utf8"), ctx);
const Q = ctx.GalleryQR;
const url = "https://gallery.example.workers.dev/m/AbCdEfGhIjKlMnOpQrStUvWx/auth/0123456789abcdef0123456789abcdef";
const m = Q.matrix(url);
assert.equal((m.length - 17) % 4, 0, "size is 17 + 4v");
const ring = (x, y) => [0,1,2,3,4,5,6].every((i) => m[y][x+i] && m[y+6][x+i] && m[y+i][x] && m[y+i][x+6]) && !m[y+1][x+1] && m[y+3][x+3];
assert.ok(ring(0, 0) && ring(m.length - 7, 0) && ring(0, m.length - 7), "three finder patterns");
assert.deepEqual(Q.matrix(url), m, "deterministic");
assert.ok(Q.svg(url).startsWith("<svg"));
assert.throws(() => Q.matrix("x".repeat(400)), /too long/);
console.log("qr: 5 passed");
