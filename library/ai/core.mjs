// Gallery AI, the pure part: what gets indexed, how it is cut into passages, how a question finds them, and what the
// model is asked. No I/O here, so test/ai.test.mjs can check all of it without Ollama, R2 or the network.

export const DOC_EXT = new Set(["pdf", "docx", "doc", "rtf", "txt", "md", "markdown", "html", "htm", "odt", "webarchive"]);
export const MEDIA_EXT = new Set(["mp3", "m4a", "wav", "flac", "aac", "ogg", "opus", "aif", "aiff", "mp4", "mov", "m4v", "webm", "mkv"]);
export const ROOTS = ["main", "archive"];

export const extOf = (p) => { const m = /\.([a-z0-9]+)$/i.exec(p); return m ? m[1].toLowerCase() : ""; };
export const kindOf = (p) => (DOC_EXT.has(extOf(p)) ? "doc" : MEDIA_EXT.has(extOf(p)) ? "media" : "file");

/** Cuts text into passages of about `size` characters, on paragraph then sentence boundaries, overlapping a little
 *  so an answer that straddles two passages is still found. */
export function chunkText(text, size = 900, overlap = 120) {
  const clean = String(text || "").replace(/\r/g, "").replace(/[ \t\f\v]+/g, " ").replace(/\n{3,}/g, "\n\n").trim();
  if (!clean) return [];
  const pieces = clean.split(/(?<=\n\n)|(?<=[.!?…])\s+/).filter((s) => s.trim());
  const out = [];
  let cur = "";
  for (const p of pieces) {
    if (p.length > size) {                          // one enormous sentence: hard cut
      if (cur.trim()) { out.push(cur.trim()); cur = ""; }
      for (let i = 0; i < p.length; i += size - overlap) out.push(p.slice(i, i + size).trim());
      continue;
    }
    if (cur.length + p.length + 1 > size && cur.trim()) {
      out.push(cur.trim());
      cur = cur.slice(Math.max(0, cur.length - overlap)) + " ";
    }
    cur += p + " ";
  }
  if (cur.trim()) out.push(cur.trim());
  return out.filter((c) => c.length >= 20 || out.length === 1);
}

/** A transcript (Worker /main/api/transcript: { lines: [{ text?, words: [{ t, s, e }] }] }) as passages of a few lines,
 *  each with the time it starts at, so an answer can point to the moment. */
export function chunkTranscript(lines, size = 700) {
  const out = [];
  let cur = "", t = null;
  for (const l of Array.isArray(lines) ? lines : []) {
    const words = Array.isArray(l.words) ? l.words : [];
    const text = String(l.text || words.map((w) => w.t).join(" ")).trim();
    if (!text) continue;
    const at = words.length && typeof words[0].s === "number" ? words[0].s : typeof l.start === "number" ? l.start : null;
    if (cur && cur.length + text.length + 1 > size) { out.push({ text: cur.trim(), t }); cur = ""; t = null; }
    if (t == null) t = at;
    cur += text + " ";
  }
  if (cur.trim()) out.push({ text: cur.trim(), t });
  return out;
}

/** The passage every file gets, whatever it holds: its name and folder, so "the video from Raven" finds it. */
export function nameText(root, path) {
  const parts = path.split("/"), name = parts.pop();
  return `${name.replace(/\.[^.]+$/, "").replace(/[_-]+/g, " ")} (${root === "archive" ? "Archive" : "Main"}${parts.length ? " / " + parts.join(" / ") : ""}, ${kindOf(path)})`;
}

export const dot = (a, b) => { let s = 0; for (let i = 0; i < a.length; i++) s += a[i] * b[i]; return s; };
export function normalize(v) {
  let n = 0; for (const x of v) n += x * x; n = Math.sqrt(n) || 1;
  return Float32Array.from(v, (x) => x / n);
}

/** Whether a passage is inside what the person has open: a root and a folder (or file) path under it; "all" is everything. */
export function inScope(chunk, scope) {
  if (!scope || scope.root === "all" || !scope.root) return true;
  if (chunk.root !== scope.root) return false;
  const p = String(scope.path || "").replace(/^\/+|\/+$/g, "");
  return !p || chunk.path === p || chunk.path.startsWith(p + "/");
}

/** The best `k` passages for a query vector, at most `perFile` from one file so one long PDF can't crowd out the rest. */
export function search(chunks, vectors, q, scope, k = 6, perFile = 3) {
  const scored = [];
  for (let i = 0; i < chunks.length; i++) {
    if (!vectors[i] || !inScope(chunks[i], scope)) continue;
    scored.push([dot(q, vectors[i]), i]);
  }
  scored.sort((a, b) => b[0] - a[0]);
  const per = new Map(), out = [];
  for (const [score, i] of scored) {
    const c = chunks[i], key = c.root + ":" + c.path, n = per.get(key) || 0;
    if (n >= perFile) continue;
    per.set(key, n + 1);
    out.push({ ...c, score: Math.round(score * 1000) / 1000 });
    if (out.length >= k) break;
  }
  return out;
}

const fmtTime = (t) => { const s = Math.max(0, Math.floor(t)); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`; };

/** What the chat model is asked: the sources, numbered, then the question. It answers from them only. */
export function buildMessages(question, hits, history = []) {
  const sources = hits.map((h, i) =>
    `[${i + 1}] ${h.root === "archive" ? "Archive" : "Main"} / ${h.path}${h.t != null ? " at " + fmtTime(h.t) : ""}\n${h.text}`).join("\n\n");
  const system = [
    "You are the assistant in the owner's private media gallery. Answer using only the numbered sources below,",
    "which are passages from the owner's documents, transcripts of their recordings, and file names.",
    "Cite sources inline like [1] or [2][3]. When summarizing a file, cover its main points briefly.",
    "If the sources don't contain the answer, say you couldn't find it in the gallery; never invent files or facts.",
    "Answer in the language of the question. Be concise.",
    "",
    "Sources:",
    sources || "(none matched)",
  ].join("\n");
  const past = (Array.isArray(history) ? history : []).slice(-6)
    .filter((m) => m && (m.role === "user" || m.role === "assistant") && typeof m.content === "string")
    .map((m) => ({ role: m.role, content: m.content.slice(0, 2000) }));
  return [{ role: "system", content: system }, ...past, { role: "user", content: String(question).slice(0, 2000) }];
}

/** CORS and DNS-rebinding guard: requests must name this helper's own host, and a browser request must come from the
 *  gallery's origin. Returns null when allowed, else the reason. */
export function guard({ origin, host, method }, { allowedOrigin, port }) {
  const hosts = new Set([`127.0.0.1:${port}`, `localhost:${port}`]);
  if (!hosts.has(String(host || ""))) return "bad host";
  if (origin && origin !== allowedOrigin) return "bad origin";
  if (!origin && method !== "GET") return "no origin";        // a page must say where it is; curl may only read status
  return null;
}
