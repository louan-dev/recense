// Writing new cover art into an audio file's own tags, so the file itself carries it: the Gallery
// mount on the Mac, Finder, Music and any player see the same picture the page shows.
//
// Only the tag at the front of the file is rebuilt; the audio after it is passed through as it is.
// MP3 (ID3v2.3/2.4, or a new ID3v2.3 tag when there is none) and FLAC. Anything else (M4A, WAV,
// AIFF, ID3v2.2, an unsynchronised tag) is left alone and gets the picture beside it instead.
//
// newHead(bucket, key, size, pic) → { head: Uint8Array, rest: <byte offset where the audio starts> } or null
// pic === null strips the pictures instead (Delete cover); null back when the file has none to strip.

const MAX_TAG = 24 * 1024 * 1024;

const synchsafe = (b, o) => ((b[o] & 127) << 21) | ((b[o + 1] & 127) << 14) | ((b[o + 2] & 127) << 7) | (b[o + 3] & 127);
const u32 = (b, o) => ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) >>> 0;
const ascii = (s) => new TextEncoder().encode(s);

const ss = (n) => [(n >> 21) & 127, (n >> 14) & 127, (n >> 7) & 127, n & 127];
const be32 = (n) => [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255];

function concat(parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

async function bytes(bucket, key, offset, length) {
  const o = await bucket.get(key, { range: { offset, length } });
  return o ? new Uint8Array(await o.arrayBuffer()) : null;
}

// ID3v2.3/2.4: every frame but the old pictures, then the new one, then some padding
async function id3(bucket, key, size, pic) {
  const h = await bytes(bucket, key, 0, 10);
  if (!h) return null;

  if (!(h[0] === 0x49 && h[1] === 0x44 && h[2] === 0x33)) {
    if (!pic) return null; // no tag, so no picture to strip
    // no tag yet: a fresh ID3v2.3 one in front of the audio
    return { head: tag(3, [apic(3, pic)]), rest: 0 };
  }

  const ver = h[3];
  const flags = h[5];
  if (ver !== 3 && ver !== 4) return null;
  if (flags & 0xc0) return null; // unsynchronised, or an extended header: not ours to rewrite

  const len = synchsafe(h, 6);
  const rest = 10 + len + (flags & 0x10 ? 10 : 0);
  if (len > MAX_TAG || rest > size) return null;

  const b = await bytes(bucket, key, 10, len);
  if (!b) return null;

  const keep = [];
  let o = 0;
  let had = false;

  while (o + 10 <= b.length && b[o] !== 0) {
    const id = String.fromCharCode(b[o], b[o + 1], b[o + 2], b[o + 3]);
    const n = ver === 4 ? synchsafe(b, o + 4) : u32(b, o + 4);
    if (!/^[A-Z0-9]{4}$/.test(id) || o + 10 + n > b.length) break;
    if (id !== "APIC") keep.push(b.subarray(o, o + 10 + n));
    else had = true;
    o += 10 + n;
  }

  if (!pic && !had) return null;
  if (pic) keep.push(apic(ver, pic));
  return { head: tag(ver, keep), rest };
}

function apic(ver, pic) {
  const body = concat([new Uint8Array([0]), ascii(pic.mime), new Uint8Array([0, 3, 0]), pic.data]);
  const n = body.length;
  return concat([ascii("APIC"), new Uint8Array(ver === 4 ? ss(n) : be32(n)), new Uint8Array([0, 0]), body]);
}

function tag(ver, frames) {
  const body = concat([...frames, new Uint8Array(2048)]);
  return concat([new Uint8Array([0x49, 0x44, 0x33, ver, 0, 0, ...ss(body.length)]), body]);
}

// FLAC: the metadata blocks but the old pictures, then a new PICTURE block, then the audio frames
async function flac(bucket, key, size, pic) {
  if (pic && pic.data.length >= 1 << 24) return null;

  const blocks = [];
  let o = 4;
  let last = false;
  let had = false;

  while (!last) {
    const h = await bytes(bucket, key, o, 4);
    if (!h || h.length < 4) return null;

    last = !!(h[0] & 0x80);
    const type = h[0] & 0x7f;
    const n = (h[1] << 16) | (h[2] << 8) | h[3];
    if (o + 4 + n > size || o > MAX_TAG) return null;

    if (type !== 6) {
      const d = await bytes(bucket, key, o + 4, n);
      if (!d) return null;
      blocks.push({ type, d });
    } else {
      had = true;
    }

    o += 4 + n;
  }

  if (!blocks.length || blocks[0].type !== 0) return null; // STREAMINFO comes first, always
  if (!pic && !had) return null;

  const m = pic ? ascii(pic.mime) : null;
  const d = pic && concat([
    new Uint8Array(be32(3)),
    new Uint8Array(be32(m.length)),
    m,
    new Uint8Array(be32(0)),
    new Uint8Array(16), // width, height, depth, colours: unknown, which readers accept
    new Uint8Array(be32(pic.data.length)),
    pic.data,
  ]);

  // the picture goes after STREAMINFO; padding, if any, stays last
  const pad = blocks.filter((x) => x.type === 1);
  const list = [blocks[0], ...(pic ? [{ type: 6, d }] : []), ...blocks.slice(1).filter((x) => x.type !== 1), ...pad];

  const parts = [ascii("fLaC")];
  list.forEach((x, i) => {
    const n = x.d.length;
    parts.push(new Uint8Array([(i === list.length - 1 ? 0x80 : 0) | x.type, (n >> 16) & 255, (n >> 8) & 255, n & 255]), x.d);
  });

  return { head: concat(parts), rest: o };
}

export async function newHead(bucket, key, size, pic) {
  const h = await bytes(bucket, key, 0, 4);
  if (!h) return null;

  const name = key.toLowerCase();
  if (h[0] === 0x66 && h[1] === 0x4c && h[2] === 0x61 && h[3] === 0x43) return flac(bucket, key, size, pic);
  if (name.endsWith(".mp3")) return id3(bucket, key, size, pic);
  return null;
}

// What an uploaded picture really is (never trust the name or the header the browser sent).
export function picType(d) {
  if (d.length > 3 && d[0] === 0xff && d[1] === 0xd8 && d[2] === 0xff) return "image/jpeg";
  if (d.length > 8 && d[0] === 0x89 && d[1] === 0x50 && d[2] === 0x4e && d[3] === 0x47) return "image/png";
  return null;
}
