// The assistant, the pure part (ai.js does the I/O): what gets indexed, how it is cut into passages, how a question's
// matches are filtered to what is open, and what the model is asked. No bindings here, so test/ai.test.mjs checks it in Node.

export const DOC_EXT = new Set(["pdf", "docx", "doc", "rtf", "txt", "md", "markdown", "html", "htm", "odt", "xlsx", "csv"]);
export const MEDIA_EXT = new Set(["mp3", "m4a", "wav", "flac", "aac", "ogg", "opus", "aif", "aiff", "mp4", "mov", "m4v", "webm", "mkv"]);

export const extOf = (p) => { const m = /\.([a-z0-9]+)$/i.exec(p); return m ? m[1].toLowerCase() : ""; };
export const kindOf = (p) => (DOC_EXT.has(extOf(p)) ? "doc" : MEDIA_EXT.has(extOf(p)) ? "media" : "file");

/** Cuts text into passages of about `size` characters, on paragraph then sentence boundaries, overlapping a little
 *  so an answer that straddles two passages is still found. */
export function chunkText(text, size = 1200, overlap = 150) {
  const clean = String(text || "").replace(/\r/g, "").replace(/[ \t\f\v]+/g, " ").replace(/\n{3,}/g, "\n\n").trim();
  if (!clean) return [];
  const pieces = clean.split(/(?<=\n\n)|(?<=[.!?…])\s+/).filter((s) => s.trim());
  const out = [];
  let cur = "";
  for (const p of pieces) {
    if (p.length > size) {                          // one enormous sentence or table: hard cut
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

/** A transcript (transcriptFor: { lines: [{ text?, words: [{ t, s, e }] }] }) as passages of a few lines, each with
 *  the time it starts at, so an answer can point to the moment. */
export function chunkTranscript(lines, size = 900) {
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

/** Whether a passage is inside what the person has open: a root and a folder (or file) path under it; "all" is everything. */
export function inScope(hit, scope) {
  if (!scope || scope.root === "all" || !scope.root) return true;
  if (hit.root !== scope.root) return false;
  const p = String(scope.path || "").replace(/^\/+|\/+$/g, "");
  return !p || hit.path === p || hit.path.startsWith(p + "/");
}

/** Matches (best first) kept to what is open, at most `perFile` from one file so one long book can't crowd out the rest. */
export function pick(matches, scope, k = 8, perFile = 4) {
  const per = new Map(), out = [];
  for (const h of matches) {
    if (!inScope(h, scope)) continue;
    const key = h.root + ":" + h.path, n = per.get(key) || 0;
    if (n >= perFile) continue;
    per.set(key, n + 1);
    out.push(h);
    if (out.length >= k) break;
  }
  return out;
}

const fmtTime = (t) => { const s = Math.max(0, Math.floor(t)); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`; };

/** What the chat model is asked. The owner's documents are the authority; general knowledge fills in only where they
 *  are silent, and is labelled as such. */
export function buildMessages(question, hits, history = []) {
  const sources = hits.map((h, i) =>
    `[${i + 1}] ${h.root === "archive" ? "Archive" : "Main"} / ${h.path}${h.t != null ? " at " + fmtTime(h.t) : ""}\n${h.text}`).join("\n\n");
  const system = [
    "You are the assistant in the owner's private gallery of documents and recordings (textbooks, the MPEP, notes, transcripts).",
    "Rules, in order of priority:",
    "1. The numbered sources below are the owner's own documents and are the authority. When they address the question, answer from them,",
    "   quote or closely paraphrase the wording that matters, and cite inline like [1] or [2][3]. If a source conflicts with your general",
    "   knowledge, the source wins; you may note the difference.",
    "2. Where the sources are silent, you may answer from general knowledge, but say so plainly (start that part with \"General knowledge:\")",
    "   and never present it as coming from the owner's files.",
    "3. Never invent citations, section numbers, file names, quotes or facts. If you are not sure, say what you don't know.",
    "4. For legal or regulatory material (e.g. MPEP sections, rules, statutes), cite the section number exactly as it appears in the source.",
    "Answer in the language of the question. Be concise unless asked for detail.",
    "",
    "Sources:",
    sources || "(none matched in the owner's files)",
  ].join("\n");
  const past = (Array.isArray(history) ? history : []).slice(-6)
    .filter((m) => m && (m.role === "user" || m.role === "assistant") && typeof m.content === "string")
    .map((m) => ({ role: m.role, content: m.content.slice(0, 4000) }));
  return [{ role: "system", content: system }, ...past, { role: "user", content: String(question).slice(0, 4000) }];
}

/** A vector id (Vectorize allows 64 bytes): a hash of root:path plus the passage number. */
export async function vectorId(root, path, n) {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(root + ":" + path)));
  return [...d.slice(0, 16)].map((b) => b.toString(16).padStart(2, "0")).join("") + "-" + n;
}
