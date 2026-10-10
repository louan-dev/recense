// Cover art inside audio files, read straight from R2.
//
// Only the tag bytes are fetched, with range reads, never the audio itself.
// Supports MP3 (ID3v2.2/2.3/2.4), FLAC, M4A/MP4, WAV and AIFF.

const MAX_TAG = 24 * 1024 * 1024; // biggest tag / moov box we will read

const u32 = (b, o) =>
  ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) >>> 0;

const u32le = (b, o) =>
  (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) >>> 0;

const synchsafe = (b, o) =>
  ((b[o] & 127) << 21) |
  ((b[o + 1] & 127) << 14) |
  ((b[o + 2] & 127) << 7) |
  (b[o + 3] & 127);

const ascii = (b, o, n) =>
  String.fromCharCode.apply(null, Array.from(b.subarray(o, o + n)));

// Only hand back bytes that really are a browser-safe image.
function mkPic(data, type) {
  if (!data || data.length < 32) return null;

  let mime = null;

  if (data[0] === 0xff && data[1] === 0xd8 && data[2] === 0xff) {
    mime = "image/jpeg";
  } else if (
    data[0] === 0x89 &&
    data[1] === 0x50 &&
    data[2] === 0x4e &&
    data[3] === 0x47
  ) {
    mime = "image/png";
  } else if (data[0] === 0x47 && data[1] === 0x49 && data[2] === 0x46) {
    mime = "image/gif";
  } else if (
    ascii(data, 0, 4) === "RIFF" &&
    ascii(data, 8, 4) === "WEBP"
  ) {
    mime = "image/webp";
  }

  return mime ? { data, mime, type } : null;
}

// Prefer the front cover (type 3), otherwise the first picture.
const bestPic = (pics) =>
  pics.find((p) => p.type === 3) || pics[0] || null;

// Range reads with the first 128 KB cached, so a typical tag is one R2 read.
function reader(bucket, key, size) {
  let head = null;

  const fetchRange = async (offset, length) => {
    if (offset < 0 || offset >= size) return new Uint8Array(0);

    try {
      const o = await bucket.get(key, {
        range: { offset, length: Math.min(length, size - offset) },
      });

      return o ? new Uint8Array(await o.arrayBuffer()) : new Uint8Array(0);
    } catch (e) {
      return new Uint8Array(0);
    }
  };

  return {
    size,
    async read(offset, length) {
      if (!head) head = await fetchRange(0, 131072);

      if (offset + length <= head.length) {
        return head.subarray(offset, offset + length);
      }

      return fetchRange(offset, length);
    },
  };
}

// ----- ID3v2 (MP3, and the id3 chunk inside WAV / AIFF) -----

function unsync(b) {
  const out = new Uint8Array(b.length);
  let n = 0;

  for (let i = 0; i < b.length; i++) {
    out[n++] = b[i];
    if (b[i] === 0xff && b[i + 1] === 0) i++;
  }

  return out.subarray(0, n);
}

function apic(d, v22) {
  if (d.length < 8) return null;

  const enc = d[0];
  let p;

  if (v22) {
    p = 4; // 3-letter image format ("JPG" / "PNG")
  } else {
    const z = d.indexOf(0, 1); // mime type, null-terminated
    if (z < 0) return null;
    p = z + 1;
  }

  const type = d[p++];

  if (enc === 1 || enc === 2) {
    // UTF-16 description ends with a 2-byte null
    while (p + 1 < d.length && (d[p] !== 0 || d[p + 1] !== 0)) p += 2;
    p += 2;
  } else {
    const z = d.indexOf(0, p);
    if (z < 0) return null;
    p = z + 1;
  }

  return mkPic(d.subarray(p), type);
}

function id3Pictures(b) {
  const pics = [];

  if (b.length < 10 || ascii(b, 0, 3) !== "ID3") return pics;

  const ver = b[3];
  if (ver < 2 || ver > 4) return pics;

  const flags = b[5];
  let body = b.subarray(10, Math.min(b.length, 10 + synchsafe(b, 6)));

  if (flags & 0x80 && ver < 4) body = unsync(body);

  let p = 0;

  if (flags & 0x40 && ver >= 3 && body.length >= 4) {
    p = ver === 4 ? synchsafe(body, 0) : u32(body, 0) + 4;
  }

  const idLen = ver === 2 ? 3 : 4;
  const hdr = ver === 2 ? 6 : 10;

  while (p + hdr <= body.length && body[p] !== 0) {
    const id = ascii(body, p, idLen);

    const sz =
      ver === 2
        ? (body[p + 3] << 16) | (body[p + 4] << 8) | body[p + 5]
        : ver === 4
        ? synchsafe(body, p + 4)
        : u32(body, p + 4);

    const s = p + hdr;
    const e = s + sz;

    if (sz <= 0 || e > body.length) break;

    if (id === "APIC" || id === "PIC") {
      let d = body.subarray(s, e);
      const f2 = ver === 4 ? body[p + 9] : 0;

      if (!(f2 & 0x0c)) {
        // skip compressed / encrypted frames
        if (f2 & 0x01) d = d.subarray(4); // data length indicator
        if (f2 & 0x02) d = unsync(d);

        const pic = apic(d, ver === 2);
        if (pic) pics.push(pic);
      }
    }

    p = e;
  }

  return pics;
}

// ----- FLAC -----

function flacPic(d) {
  let p = 0;
  if (d.length < 32) return null;

  const type = u32(d, p);
  p += 4;

  const ml = u32(d, p);
  p += 4 + ml;

  const dl = u32(d, p);
  p += 4 + dl + 16; // description, then width / height / depth / colours

  const n = u32(d, p);
  p += 4;

  if (p + n > d.length) return null;

  return mkPic(d.subarray(p, p + n), type);
}

async function flacPictures(rd, start) {
  const pics = [];
  let p = start + 4; // skip "fLaC"

  for (let i = 0; i < 128; i++) {
    const h = await rd.read(p, 4);
    if (h.length < 4) break;

    const last = h[0] & 0x80;
    const type = h[0] & 0x7f;
    const len = (h[1] << 16) | (h[2] << 8) | h[3];

    if (type === 6 && len <= MAX_TAG) {
      const d = await rd.read(p + 4, len);

      if (d.length === len) {
        const pic = flacPic(d);
        if (pic) pics.push(pic);
      }
    }

    p += 4 + len;
    if (last) break;
  }

  return pics;
}

// ----- MP4 / M4A (moov > udta > meta > ilst > covr > data) -----

function boxes(b, s, e, cb) {
  let p = s;

  while (p + 8 <= e) {
    let size = u32(b, p);
    if (size === 0) size = e - p;
    if (size < 8) break;

    const end = Math.min(e, p + size);
    if (cb(ascii(b, p + 4, 4), p + 8, end) === true) return true;

    p = end;
  }

  return false;
}

function covrPictures(m) {
  const pics = [];

  boxes(m, 0, m.length, (t1, s1, e1) => {
    if (t1 !== "udta") return false;

    boxes(m, s1, e1, (t2, s2, e2) => {
      if (t2 !== "meta") return false;

      // meta is a "full box": 4 bytes of version + flags come first
      boxes(m, s2 + 4, e2, (t3, s3, e3) => {
        if (t3 !== "ilst") return false;

        boxes(m, s3, e3, (t4, s4, e4) => {
          if (t4 !== "covr") return false;

          boxes(m, s4, e4, (t5, s5, e5) => {
            if (t5 === "data") {
              // 1 byte version + 3 bytes flags + 4 bytes locale
              const pic = mkPic(m.subarray(s5 + 8, e5), 3);
              if (pic) pics.push(pic);
            }

            return false;
          });

          return false;
        });

        return false;
      });

      return false;
    });

    return false;
  });

  return pics;
}

async function mp4Pictures(rd) {
  let p = 0;

  for (let i = 0; i < 64 && p + 8 <= rd.size; i++) {
    const h = await rd.read(p, 16);
    if (h.length < 8) break;

    let size = u32(h, 0);
    let hdr = 8;

    if (size === 1 && h.length >= 16) {
      size = u32(h, 8) * 4294967296 + u32(h, 12); // 64-bit box size
      hdr = 16;
    } else if (size === 0) {
      size = rd.size - p;
    }

    if (size < hdr) break;

    if (ascii(h, 4, 4) === "moov") {
      if (size - hdr > MAX_TAG) return [];

      const moov = await rd.read(p + hdr, size - hdr);
      return covrPictures(moov);
    }

    p += size;
  }

  return [];
}

// ----- WAV / AIFF chunk walk (the id3 chunk is often after the audio) -----

async function riffPictures(rd, bigEndian) {
  let p = 12;

  for (let i = 0; i < 256 && p + 8 <= rd.size; i++) {
    const h = await rd.read(p, 8);
    if (h.length < 8) break;

    const id = ascii(h, 0, 4).toLowerCase();
    const len = bigEndian ? u32(h, 4) : u32le(h, 4);

    if (id === "id3 ") {
      if (len > MAX_TAG) return [];

      const tag = await rd.read(p + 8, len);
      return id3Pictures(tag);
    }

    p += 8 + len + (len & 1);
  }

  return [];
}

// ----- dispatcher -----

export async function extractArt(bucket, key, size) {
  const rd = reader(bucket, key, size);
  const head = await rd.read(0, 16);

  if (head.length < 12) return null;

  if (ascii(head, 0, 3) === "ID3") {
    const tagLen = 10 + synchsafe(head, 6) + (head[5] & 0x10 ? 10 : 0);

    if (tagLen <= MAX_TAG) {
      const tag = await rd.read(0, tagLen);
      const pic = bestPic(id3Pictures(tag));
      if (pic) return pic;
    }

    // some FLAC files carry an ID3 tag in front of the fLaC marker
    const next = await rd.read(tagLen, 4);

    if (next.length === 4 && ascii(next, 0, 4) === "fLaC") {
      return bestPic(await flacPictures(rd, tagLen));
    }

    return null;
  }

  if (ascii(head, 0, 4) === "fLaC") {
    return bestPic(await flacPictures(rd, 0));
  }

  if (ascii(head, 4, 4) === "ftyp") {
    return bestPic(await mp4Pictures(rd));
  }

  if (ascii(head, 0, 4) === "RIFF" && ascii(head, 8, 4) === "WAVE") {
    return bestPic(await riffPictures(rd, false));
  }

  if (ascii(head, 0, 4) === "FORM" && /^AIF[FC]$/.test(ascii(head, 8, 4))) {
    return bestPic(await riffPictures(rd, true));
  }

  return null;
}

