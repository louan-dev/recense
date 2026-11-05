// A JPEG holding only an EXIF block (Make, DateTimeOriginal, pixel size, GPS): what meta.js reads, nothing more.
// Shared by routes.test.mjs and viewer.test.mjs.
export function jpegWithExif({ lat, lon, taken = "2024:05:06 07:08:09", make = "Apple" }) {
  const ents = (list) => list; // [tag, type, count, value(Buffer|number)]
  const build = (ifds) => {
    // lays out IFDs and their out-of-line data after an 8-byte TIFF header
    let off = 8;
    const pos = ifds.map((ifd) => {
      const at = off;
      off += 2 + ifd.length * 12 + 4;
      return at;
    });
    const data = [];
    const body = [];
    ifds.forEach((ifd, k) => {
      const b = Buffer.alloc(2 + ifd.length * 12 + 4);
      b.writeUInt16BE(ifd.length, 0);
      ifd.forEach(([tag, type, count, v], i) => {
        const e = 2 + i * 12;
        b.writeUInt16BE(tag, e);
        b.writeUInt16BE(type, e + 2);
        b.writeUInt32BE(count, e + 4);
        if (typeof v === "function") v = v(pos);
        if (Buffer.isBuffer(v) && v.length > 4) {
          b.writeUInt32BE(off, e + 8);
          data.push(v);
          off += v.length;
        } else if (Buffer.isBuffer(v)) v.copy(b, e + 8);
        else if (type === 3) b.writeUInt16BE(v, e + 8);
        else b.writeUInt32BE(v, e + 8);
      });
      body.push(b);
    });
    return Buffer.concat([Buffer.from("MM\x00\x2a\x00\x00\x00\x08", "latin1"), ...body, ...data]);
  };
  const rat = (...xs) => {
    const b = Buffer.alloc(8 * xs.length);
    xs.forEach(([n, d], i) => (b.writeUInt32BE(n, i * 8), b.writeUInt32BE(d, i * 8 + 4)));
    return b;
  };
  const dms = (x) => {
    const a = Math.abs(x);
    const d = Math.floor(a);
    const m = Math.floor((a - d) * 60);
    const sec = Math.round(((a - d) * 60 - m) * 60 * 1000);
    return rat([d, 1], [m, 1], [sec, 1000]);
  };
  const ascii = (s) => Buffer.from(s + "\0", "latin1");
  const tiffBuf = build([
    ents([[0x010f, 2, make.length + 1, ascii(make)], [0x8769, 4, 1, (p) => p[1]], [0x8825, 4, 1, (p) => p[2]]]),
    ents([[0x9003, 2, 20, ascii(taken)], [0xa002, 4, 1, 4032], [0xa003, 4, 1, 3024]]),
    ents([[1, 2, 2, Buffer.from(lat < 0 ? "S\0\0\0" : "N\0\0\0", "latin1")], [2, 5, 3, dms(lat)], [3, 2, 2, Buffer.from(lon < 0 ? "W\0\0\0" : "E\0\0\0", "latin1")], [4, 5, 3, dms(lon)]]),
  ]);
  const app1 = Buffer.concat([Buffer.from("Exif\0\0", "latin1"), tiffBuf]);
  const hdr = Buffer.alloc(4);
  hdr.writeUInt16BE(0xffe1, 0);
  hdr.writeUInt16BE(app1.length + 2, 2);
  return Buffer.concat([Buffer.from([0xff, 0xd8]), hdr, app1, Buffer.from([0xff, 0xda, 0, 2, 0xff, 0xd9])]);
}
