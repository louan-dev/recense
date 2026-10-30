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

// ---------- what a document is worth as evidence ----------
// "reference": published material (a textbook, the MPEP, a statute, an article): trusted like general knowledge, cited.
// "personal":  the owner's own writing or recordings (reflections, journals, venting, drafts, letters, notes): what the owner
//              thought or felt, possibly subjective or wrong; never evidence for a fact. The default when unsure.
// "name":      a file's name and folder only.
export const AUTH = ["reference", "personal"];

/** The question put to the model once per document, from its name and opening text. */
export function classifyMessages(path, sample) {
  return [
    { role: "system", content: [
      "Classify a document from a personal library. Reply with JSON only: {\"auth\":\"reference\"} or {\"auth\":\"personal\"}.",
      "reference = published material written for others: a textbook, a manual such as the MPEP, a statute or regulation, a court decision,",
      "a published article, paper or book chapter, official documentation. Signs: publisher, ISBN, DOI, copyright notice, edition, numbered sections,",
      "formal impersonal prose.",
      "personal = the owner's own writing or speech: reflections, journal or diary entries, venting, opinions, class reflections, drafts, notes,",
      "cover letters, CVs, messages, transcripts of the owner talking. Signs: first person, feelings, dates of the owner's life, informal tone.",
      "If unsure, answer personal.",
    ].join("\n") },
    { role: "user", content: `File: ${path}\n\nOpening text:\n${String(sample || "").slice(0, 3000)}` },
  ];
}

/** The model's reply to classifyMessages, as "reference" or "personal" (anything unclear is personal). */
export function parseAuth(reply) {
  const s = String(reply || "");
  const m = /"auth"\s*:\s*"(reference|personal)"/i.exec(s) || /\b(reference|personal)\b/i.exec(s);
  return m && m[1].toLowerCase() === "reference" ? "reference" : "personal";
}

const LABEL = { reference: "published reference", personal: "owner's personal writing", name: "file name only", transcript: "owner's recording" };

/** What the chat model is asked. Published references are trusted alongside general knowledge; the owner's personal
 *  writing tells what the owner thought or felt, never what is true. */
export function buildMessages(question, hits, history = [], memories = []) {
  const sources = hits.map((h, i) =>
    `[${i + 1}] (${LABEL[h.auth] || LABEL.personal}) ${h.root === "archive" ? "Archive" : "Main"} / ${h.path}${h.t != null ? " at " + fmtTime(h.t) : ""}\n${h.text}`).join("\n\n");
  const mem = (Array.isArray(memories) ? memories : []).slice(-MEMORY_IN_PROMPT).map((m) => `- ${m.text}`).join("\n");
  const system = [
    "You are the owner's personal assistant inside their private gallery of documents and recordings. You know them through their own",
    "notes and through what they have told you, and you help with both knowledge questions and their own life.",
    "",
    "Each numbered source below is labelled with what it is worth as evidence:",
    "- (published reference): published material such as a textbook, the MPEP, a statute or an article. Treat it as reliable knowledge,",
    "  on par with or above your general knowledge. Quote or closely paraphrase the wording that matters and cite it like [1].",
    "  For legal or regulatory material, cite section numbers exactly as they appear in the source.",
    "- (owner's personal writing) and (owner's recording): reflections, journals, venting, drafts, notes from therapy or coaching, the",
    "  owner talking. They mix opinions and feelings with factual statements. Sort them claim by claim:",
    "  * About the owner (habits, preferences, energy, how they manage time, goals, what they felt, what helps them, and a therapist's or",
    "    coach's observations of them): this is the best evidence about the owner's own life. A therapist's observation is a professional's",
    "    view of the owner; weigh it more than a passing mood. Use these to answer questions and give advice about the owner's own life.",
    "  * Opinions and judgements about the world: they tell what the owner thinks, not what is true.",
    "  * Factual claims about the world (e.g. a fact of science, law or history mentioned in a reflection): check each against the",
    "    published references and your general knowledge. If it checks out, use it as a fact and cite it like [2] alongside what confirms",
    "    it. If it is partly or wholly wrong, use only the correct part, state the correction plainly, and never let the note override",
    "    the facts. If it can't be checked, say it comes from the owner's notes and is unverified.",
    "- (file name only): the file exists; its content wasn't read.",
    "",
    "Advice about the owner's own life (e.g. \"should I meet a friend at 5 pm?\"): ground it in their notes and in what you remember about",
    "them, say what it rests on (\"Based on your reflections on evenings [3]…\", \"Your therapist observed… [4]\"), give a clear",
    "recommendation and a practical alternative (e.g. reschedule). If nothing in their notes bears on it, say so and answer generally.",
    "When the owner is upset or venting: acknowledge how they feel first, briefly and warmly, without lecturing; then draw on what their",
    "therapy notes and reflections say helps them, and name it. You support their therapy; you are not their therapist, and you don't",
    "diagnose. If anything suggests they might harm themselves or someone else, or are in danger, gently urge them to contact their",
    "therapist now or call or text 988 (Suicide & Crisis Lifeline, US), or emergency services.",
    "",
    "Where no source covers a factual question, answer from general knowledge and start that part with \"General knowledge:\".",
    "Never invent citations, section numbers, file names, quotes, memories or facts. If you are not sure, say what you don't know.",
    "Answer in the language of the question. Be concise unless asked for detail.",
    "",
    "What you remember about the owner from past conversations (their own words; preferences and facts about them, not about the world):",
    mem || "(nothing yet)",
    "",
    "Sources:",
    sources || "(none matched in the owner's files)",
  ].join("\n");
  return [{ role: "system", content: system }, ...cleanHistory(history), { role: "user", content: String(question).slice(0, 4000) }];
}

const cleanHistory = (history) => (Array.isArray(history) ? history : []).slice(-6)
  .filter((m) => m && (m.role === "user" || m.role === "assistant") && typeof m.content === "string")
  .map((m) => ({ role: m.role, content: m.content.slice(0, 4000) }));

// ---------- finding what bears on a question ----------

/** Asks a small model for up to three searches that would find what bears on the question, including the owner's own notes
 *  about themselves when the question is about their life ("meet a friend at 5 pm" → "my habits and energy in the evening"). */
export function planMessages(question, history = []) {
  return [
    { role: "system", content: [
      "You write search queries for a personal library of documents, reflections, therapy notes and transcripts.",
      "Given the owner's message, reply with JSON only: {\"queries\":[\"…\",\"…\"]} with 1 to 3 short queries in the message's language.",
      "Include the topic itself; when the message is about the owner's own life, decisions, plans or feelings, add queries for what their",
      "notes would say about it (habits, preferences, how they manage time or energy, what helps them, a therapist's observations).",
    ].join("\n") },
    ...cleanHistory(history).slice(-2),
    { role: "user", content: String(question).slice(0, 2000) },
  ];
}

/** The planner's reply as a list of queries, always starting with the question itself. */
export function parseQueries(reply, question) {
  let qs = [];
  try { const m = /\{[\s\S]*\}/.exec(String(reply || "")); qs = m ? JSON.parse(m[0]).queries : []; } catch { qs = []; }
  const out = [String(question).slice(0, 500)];
  for (const q of Array.isArray(qs) ? qs : []) {
    const t = String(q || "").trim().slice(0, 300);
    if (t && !out.some((x) => x.toLowerCase() === t.toLowerCase())) out.push(t);
    if (out.length >= 4) break;
  }
  return out;
}

// ---------- remembering the owner ----------

export const MEMORY_MAX = 300;              // memories kept (oldest go first)
export const MEMORY_IN_PROMPT = 80;         // most recent ones given to the model

/** After an exchange: what the owner said that is worth remembering about them, and which memories they asked to drop. */
export function memoryMessages(question, answer, memories = []) {
  const list = memories.map((m) => `${m.id}: ${m.text}`).join("\n") || "(none)";
  return [
    { role: "system", content: [
      "You keep a short memory of the owner for their personal assistant. Read the owner's message (and the assistant's reply for context).",
      "Reply with JSON only: {\"remember\":[\"…\"],\"forget\":[\"id\"]}.",
      "remember: durable facts about the owner that THEY stated or clearly confirmed: preferences, routines, how they like to work or manage",
      "time, goals, important people, constraints, things they asked you to remember. One short third-person sentence each",
      "(\"Prefers no social plans after 5 pm on weekdays.\"). Not passing moods, not facts about the world, not anything only the assistant",
      "said, not something already in the memory list. Usually nothing: reply {\"remember\":[],\"forget\":[]}.",
      "forget: ids from the list that the owner says are wrong, outdated, or asks you to forget.",
      "",
      "Memory list:",
      list,
    ].join("\n") },
    { role: "user", content: `Owner: ${String(question).slice(0, 3000)}\n\nAssistant: ${String(answer || "").slice(0, 1500)}` },
  ];
}

/** Applies the memory model's reply: new entries appended (deduplicated, capped), forgotten ids removed. */
export function applyMemory(memories, reply, now = new Date().toISOString(), newId = () => crypto.randomUUID().slice(0, 8)) {
  let o = {};
  try { const m = /\{[\s\S]*\}/.exec(String(reply || "")); o = m ? JSON.parse(m[0]) : {}; } catch { o = {}; }
  const forget = new Set((Array.isArray(o.forget) ? o.forget : []).map(String));
  let out = (Array.isArray(memories) ? memories : []).filter((m) => !forget.has(m.id));
  const have = new Set(out.map((m) => m.text.toLowerCase()));
  for (const r of Array.isArray(o.remember) ? o.remember : []) {
    const text = String(r || "").trim().slice(0, 300);
    if (!text || have.has(text.toLowerCase())) continue;
    have.add(text.toLowerCase());
    out.push({ id: newId(), text, at: now });
  }
  if (out.length > MEMORY_MAX) out = out.slice(out.length - MEMORY_MAX);
  return { memories: out, changed: forget.size > 0 || out.length !== memories.length || out.some((m, i) => m !== memories[i]) };
}

/** A vector id (Vectorize allows 64 bytes): a hash of root:path plus the passage number. */
export async function vectorId(root, path, n) {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(root + ":" + path)));
  return [...d.slice(0, 16)].map((b) => b.toString(16).padStart(2, "0")).join("") + "-" + n;
}
