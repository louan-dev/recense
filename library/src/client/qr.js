// Offline QR code encoder (byte mode, error-correction level L, versions 1–10, URLs up to ~210 bytes).
// Pure functions, no DOM, no network: the page loads this before gallery.js and test/qr.test.mjs runs it in node.
// GalleryQR.matrix(text) -> array of rows of booleans (true = dark); GalleryQR.svg(text) -> an <svg> string.
// Method after the public QR Code model 2 standard (ISO/IEC 18004): data + Reed-Solomon over GF(256), 8 masks scored.
globalThis.GalleryQR = (() => {
  "use strict";
  const ECC_PER_BLOCK = [7, 10, 15, 20, 26, 18, 20, 24, 30, 18]; // level L, versions 1..10
  const BLOCKS = [1, 1, 1, 1, 1, 2, 2, 2, 2, 4];
  const ALIGN = [[], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50]];

  const rawModules = (v) => {
    let r = (16 * v + 128) * v + 64;
    if (v >= 2) {
      const n = Math.floor(v / 7) + 2;
      r -= (25 * n - 10) * n - 55;
      if (v >= 7) r -= 36;
    }
    return r;
  };
  const dataCodewords = (v) => Math.floor(rawModules(v) / 8) - ECC_PER_BLOCK[v - 1] * BLOCKS[v - 1];

  const mul = (x, y) => {
    let z = 0;
    for (let i = 7; i >= 0; i--) {
      z = (z << 1) ^ ((z >>> 7) * 0x11d);
      z ^= ((y >>> i) & 1) * x;
    }
    return z;
  };
  const rsDivisor = (deg) => {
    const res = new Array(deg).fill(0);
    res[deg - 1] = 1;
    let root = 1;
    for (let i = 0; i < deg; i++) {
      for (let j = 0; j < deg; j++) {
        res[j] = mul(res[j], root);
        if (j + 1 < deg) res[j] ^= res[j + 1];
      }
      root = mul(root, 2);
    }
    return res;
  };
  const rsRemainder = (data, div) => {
    const res = new Array(div.length).fill(0);
    for (const b of data) {
      const f = b ^ res.shift();
      res.push(0);
      div.forEach((c, i) => (res[i] ^= mul(c, f)));
    }
    return res;
  };

  const utf8 = (s) => Array.from(new TextEncoder().encode(s));

  const encode = (text) => {
    const bytes = utf8(text);
    let v = 1;
    for (; v <= 10; v++) {
      const need = 4 + (v < 10 ? 8 : 16) + bytes.length * 8;
      if (need <= dataCodewords(v) * 8) break;
    }
    if (v > 10) throw new Error("Link too long for a QR code");
    const bits = [];
    const put = (val, n) => { for (let i = n - 1; i >= 0; i--) bits.push((val >>> i) & 1); };
    put(0b0100, 4);
    put(bytes.length, v < 10 ? 8 : 16);
    bytes.forEach((b) => put(b, 8));
    const cap = dataCodewords(v) * 8;
    put(0, Math.min(4, cap - bits.length));
    while (bits.length % 8) bits.push(0);
    for (let pad = 0xec; bits.length < cap; pad ^= 0xec ^ 0x11) put(pad, 8);
    const data = [];
    for (let i = 0; i < bits.length; i += 8) data.push(parseInt(bits.slice(i, i + 8).join(""), 2));

    const nb = BLOCKS[v - 1], ec = ECC_PER_BLOCK[v - 1];
    const total = Math.floor(rawModules(v) / 8);
    const shortLen = Math.floor(total / nb) - ec, numShort = nb - (total % nb);
    const div = rsDivisor(ec);
    const blocks = [];
    for (let i = 0, k = 0; i < nb; i++) {
      const len = shortLen + (i < numShort ? 0 : 1);
      const d = data.slice(k, k + len);
      k += len;
      const e = rsRemainder(d, div);
      if (i < numShort) d.push(0); // placeholder so data columns line up; skipped on interleave
      blocks.push({ d, e, short: i < numShort });
    }
    const out = [];
    for (let i = 0; i < shortLen + 1; i++) blocks.forEach((b) => { if (!(b.short && i === shortLen)) out.push(b.d[i]); });
    for (let i = 0; i < ec; i++) blocks.forEach((b) => out.push(b.e[i]));
    return { v, codewords: out };
  };

  const build = (v, codewords, mask) => {
    const n = v * 4 + 17;
    const m = Array.from({ length: n }, () => new Array(n).fill(false));
    const fn = Array.from({ length: n }, () => new Array(n).fill(false));
    const set = (x, y, dark) => { m[y][x] = dark; fn[y][x] = true; };

    for (let i = 0; i < n; i++) { set(6, i, i % 2 === 0); set(i, 6, i % 2 === 0); }
    const finder = (cx, cy) => {
      for (let dy = -4; dy <= 4; dy++) for (let dx = -4; dx <= 4; dx++) {
        const x = cx + dx, y = cy + dy;
        if (x < 0 || y < 0 || x >= n || y >= n) continue;
        const d = Math.max(Math.abs(dx), Math.abs(dy));
        set(x, y, d !== 2 && d !== 4);
      }
    };
    finder(3, 3); finder(n - 4, 3); finder(3, n - 4);
    const al = ALIGN[v - 1];
    for (let i = 0; i < al.length; i++) for (let j = 0; j < al.length; j++) {
      if ((i === 0 && j === 0) || (i === 0 && j === al.length - 1) || (i === al.length - 1 && j === 0)) continue;
      for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) set(al[i] + dx, al[j] + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
    }

    const drawFormat = (msk) => {
      const dat = (1 << 3) | msk; // level L = 01
      let r = dat;
      for (let i = 0; i < 10; i++) r = (r << 1) ^ ((r >>> 9) * 0x537);
      const bitsF = ((dat << 10) | r) ^ 0x5412;
      const b = (i) => ((bitsF >>> i) & 1) !== 0;
      for (let i = 0; i <= 5; i++) set(8, i, b(i));
      set(8, 7, b(6)); set(8, 8, b(7)); set(7, 8, b(8));
      for (let i = 9; i < 15; i++) set(14 - i, 8, b(i));
      for (let i = 0; i < 8; i++) set(n - 1 - i, 8, b(i));
      for (let i = 8; i < 15; i++) set(8, n - 15 + i, b(i));
      set(8, n - 8, true);
    };
    drawFormat(mask);
    if (v >= 7) {
      let r = v;
      for (let i = 0; i < 12; i++) r = (r << 1) ^ ((r >>> 11) * 0x1f25);
      const bitsV = (v << 12) | r;
      for (let i = 0; i < 18; i++) {
        const a = n - 11 + (i % 3), b = Math.floor(i / 3), dark = ((bitsV >>> i) & 1) !== 0;
        set(a, b, dark); set(b, a, dark);
      }
    }

    let i = 0;
    for (let right = n - 1; right >= 1; right -= 2) {
      if (right === 6) right = 5;
      for (let vert = 0; vert < n; vert++) for (let j = 0; j < 2; j++) {
        const x = right - j, upward = ((right + 1) & 2) === 0, y = upward ? n - 1 - vert : vert;
        if (!fn[y][x] && i < codewords.length * 8) {
          m[y][x] = ((codewords[i >>> 3] >>> (7 - (i & 7))) & 1) !== 0;
          i++;
        }
      }
    }
    const inv = [
      (x, y) => (x + y) % 2 === 0, (x, y) => y % 2 === 0, (x) => x % 3 === 0, (x, y) => (x + y) % 3 === 0,
      (x, y) => (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0, (x, y) => ((x * y) % 2) + ((x * y) % 3) === 0,
      (x, y) => (((x * y) % 2) + ((x * y) % 3)) % 2 === 0, (x, y) => (((x + y) % 2) + ((x * y) % 3)) % 2 === 0,
    ][mask];
    for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) if (!fn[y][x] && inv(x, y)) m[y][x] = !m[y][x];
    return m;
  };

  const penalty = (m) => {
    const n = m.length;
    let p = 0;
    const runs = (get) => {
      for (let a = 0; a < n; a++) {
        let run = 1;
        for (let b = 1; b < n; b++) {
          if (get(a, b) === get(a, b - 1)) { run++; if (run === 5) p += 3; else if (run > 5) p++; } else run = 1;
        }
      }
    };
    runs((a, b) => m[a][b]); runs((a, b) => m[b][a]);
    for (let y = 0; y < n - 1; y++) for (let x = 0; x < n - 1; x++) if (m[y][x] === m[y][x + 1] && m[y][x] === m[y + 1][x] && m[y][x] === m[y + 1][x + 1]) p += 3;
    let dark = 0;
    m.forEach((r) => r.forEach((c) => { if (c) dark++; }));
    p += (Math.ceil(Math.abs(dark * 20 - n * n * 10) / (n * n)) - 1) * 10;
    return p;
  };

  const matrix = (text) => {
    const { v, codewords } = encode(text);
    let best = null, bp = Infinity;
    for (let mask = 0; mask < 8; mask++) {
      const m = build(v, codewords, mask), p = penalty(m);
      if (p < bp) { bp = p; best = m; }
    }
    return best;
  };

  const svg = (text, px = 224) => {
    const m = matrix(text), q = 4, n = m.length + q * 2;
    let d = "";
    m.forEach((r, y) => r.forEach((c, x) => { if (c) d += `M${x + q} ${y + q}h1v1h-1z`; }));
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${n} ${n}" width="${px}" height="${px}" shape-rendering="crispEdges" role="img" aria-label="QR code"><rect width="${n}" height="${n}" fill="#fff"/><path d="${d}" fill="#000"/></svg>`;
  };

  return { matrix, svg };
})();
