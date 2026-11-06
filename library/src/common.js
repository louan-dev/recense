// Pieces every route uses: page and JSON responses, file serving, types, names and paths.

export const OWNER = "Chau Phan";
export const VERSION = "1.1.0";
export const ID_RE = /^[A-Za-z0-9]{8,32}$/;

// most files one folder view will list
export const FOLDER_MAX = 5000;

// macOS and Windows litter removable drives with these; never show them
export const JUNK = /^(\.|Thumbs\.db$|desktop\.ini$|Icon\r$)/i;

export function page(body, status = 200) {
  return new Response(body, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "x-robots-tag": "noindex",
      "cache-control": "no-store",
      "x-version": VERSION,
    },
  });
}

export function notice(title, status) {
  return page(
    '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="dark"><meta name="darkreader-lock"><title>' +
      esc(title) +
      '</title><style>body{margin:0;display:grid;place-items:center;min-height:100vh;background:#1c1c1e;color:#fff;font:600 20px -apple-system,BlinkMacSystemFont,sans-serif}</style><p>' +
      esc(title) +
      "</p>",
    status
  );
}

export function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body).replace(/</g, "\\u003c"), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-robots-tag": "noindex",
      "x-version": VERSION,
    },
  });
}

// Bytes of one stored object: range requests, and inline display only for
// types that are safe to show. Used by every file route, public and Main.
export function serveObject(req, url, obj, name, fallbackType) {
  const h = new Headers();

  obj.writeHttpMetadata(h);

  h.set("etag", obj.httpEtag);
  h.set("accept-ranges", "bytes");
  h.set(
    "cache-control",
    "private, max-age=3600"
  );
  h.set(
    "x-content-type-options",
    "nosniff"
  );

  if (
    fallbackType &&
    /^(|application\/octet-stream|binary\/octet-stream)$/.test(h.get("content-type") || "")
  ) {
    h.set("content-type", fallbackType);
  }

  const type =
    h.get("content-type") || "";

  const safeInline =
    /^(image\/(?!svg)|video\/|audio\/|application\/pdf)/.test(
      type
    );

  if (
    url.searchParams.has("dl") ||
    !safeInline
  ) {
    h.set(
      "content-disposition",
      "attachment; filename*=UTF-8''" +
        encodeURIComponent(name)
    );
  }

  let status = 200;

  if (
    obj.range &&
    req.headers.has("range")
  ) {
    const r = obj.range;

    const start =
      r.suffix != null
        ? Math.max(
            0,
            obj.size - r.suffix
          )
        : r.offset || 0;

    const len =
      r.suffix != null
        ? obj.size - start
        : r.length != null
        ? r.length
        : obj.size - start;

    status = 206;

    h.set(
      "content-range",
      "bytes " +
        start +
        "-" +
        (start + len - 1) +
        "/" +
        obj.size
    );
  }

  return new Response(
    obj.body,
    {
      status,
      headers: h,
    }
  );
}

// ---------- file types ----------

export const AUDIO_RE = /\.(mp3|m4a|m4b|aac|flac|wav|wave|aif|aiff|ogg|oga|opus)$/i;

export const MIME_BY_EXT = {
  mp3: "audio/mpeg",
  m4a: "audio/mp4",
  m4b: "audio/mp4",
  aac: "audio/aac",
  flac: "audio/flac",
  wav: "audio/wav",
  wave: "audio/wav",
  aif: "audio/aiff",
  aiff: "audio/aiff",
  ogg: "audio/ogg",
  oga: "audio/ogg",
  opus: "audio/ogg",
  mp4: "video/mp4",
  m4v: "video/mp4",
  mov: "video/quicktime",
  webm: "video/webm",
  pdf: "application/pdf",
};

export const isAudioish = (type, name) =>
  /^audio\//i.test(type || "") || AUDIO_RE.test(name || "");


export const IMG_BY_EXT = {
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  png: "image/png",
  gif: "image/gif",
  webp: "image/webp",
  avif: "image/avif",
  heic: "image/heic",
  heif: "image/heif",
};

export const esc = (s) =>
  String(s).replace(/[&<>"']/g, (c) => "&#" + c.charCodeAt(0) + ";");

// A relative path ("" is the top), or null if it isn't a safe one.
export function cleanPath(s, encoded = false) {
  let p = s || "";

  if (encoded) {
    try {
      p = decodeURIComponent(p);
    } catch {
      return null;
    }
  }

  p = p.replace(/^\/+|\/+$/g, "");

  if (p.length > 900 || [...p].some((ch) => ch.charCodeAt(0) < 32)) return null;
  if (p && p.split("/").some((x) => !x || x === "." || x === "..")) return null;

  return p;
}

export const urlPath = (rel) => rel.split("/").map(encodeURIComponent).join("/");
// How a share link shows its media, chosen by the owner when it was made and stored with it (the
// trailing language, en | vi | fr, and the Key caption's notation, 0–9): every device that opens the
// link sees the same, whatever that browser has kept. null if nothing valid was sent.
export function viewOf(b) {
  const lang = b && /^(en|vi|fr)$/.test(b.lang) ? b.lang : null;
  const n = b ? Number(b.notation) : NaN;
  const notation = Number.isInteger(n) && n >= 0 && n <= 9 ? n : null;
  if (lang === null && notation === null) return null;
  return { ...(lang ? { lang } : {}), ...(notation !== null ? { notation } : {}) };
}
