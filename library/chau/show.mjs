#!/usr/bin/env node
// Shows: a Markdown outline becomes a private podcast in Gallery (D16, D32, D34 G0).
//
//   node chau/show.mjs publish <outline.md> [--show <name>] [--lang en|vi|fr] [--voice <name>] [--dry-run]
//       one .m4a per "## " section, spoken by a macOS voice, plus .show.json (the episode list),
//       synced to Main's Shows/<show>/ over the rclone remote gallery-main (~/.config/rclone/jobs.conf).
//   node chau/show.mjs invite <show> --name <who> [--days 30] [--guest]
//       a view-only invitation to the show and its feed URL (Podcasts > Follow a Show by URL…);
//       --guest adds a second link for the web page, where they can also react and comment.
//   node chau/show.mjs revoke <id>
//       ends an invitation at once (its feed and file links become the same 404 as any unknown link).
//
// The invite and revoke calls sign in with the Access service token in the Keychain (chau/setup.sh).
// Client matters (A6) never leave the Mac: an outline under a Matters or Raven folder is refused.

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, realpathSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REMOTE = "gallery-main:gallery-main";
const RCLONE_CONFIG = process.env.RCLONE_CONFIG || join(homedir(), ".config/rclone/jobs.conf");
const BASE = (process.env.GALLERY_BASE || "https://gallery.improvdiplomat.workers.dev").replace(/\/$/, "");
const CACHE = join(homedir(), "Library/Caches/recense-shows");
export const MANIFEST = ".show.json"; // a dotfile: Gallery's folder view hides it, the feed reads it

// The first installed voice wins; --voice overrides.
export const VOICES = {
  en: ["Ava (Premium)", "Ava (Enhanced)", "Samantha"],
  vi: ["Linh"],
  fr: ["Thomas", "Amélie", "Audrey"],
};

// ---------- the outline ----------

// A path with a Matters or Raven folder in it is a client matter: never published.
export function refusePath(p) {
  return p.split(/[\\/]/).some((s) => /^(matters|raven)$/i.test(s));
}

// A front-matter block ("---" … "---" at the very top) and the text after it.
export function frontMatter(md) {
  const m = md.match(/^\uFEFF?---[ \t]*\n([\s\S]*?)\n---[ \t]*(?:\n|$)/);
  return m ? { fm: m[1], body: md.slice(m[0].length) } : { fm: "", body: md };
}

// Why this outline must not leave the Mac (A6), or null. A guard on names and tags, not a classifier:
// a client matter copied elsewhere, untagged and under another name, is not caught.
export function refusal(path, md, show) {
  if (refusePath(path)) return "it is under a Matters or Raven folder";
  if (/\b(matters|raven)\b/i.test(show || "")) return "the show's name says Matters or Raven";
  const { fm, body } = frontMatter(md.normalize("NFC"));
  if (/\b(matters|raven)\b/i.test(fm)) return "its front matter says matters or raven";
  if (/(^|\s)#(matters|raven)\b/i.test(body)) return "it is tagged #matters or #raven";
  return null;
}

// Markdown to plain speech: no marks, links read as their text, a pause at each line's end.
export function speakable(md) {
  return md
    .replace(/```[^\n]*\n([\s\S]*?)```/g, "$1")
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/<[^>]+>/g, "")
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
    .replace(/\[\^[^\]]+\]/g, "")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/\[\[([^\]|]+\|)?([^\]]+)\]\]/g, "$2")
    .split("\n")
    .map((l) =>
      l
        .replace(/^\s{0,3}#{1,6}\s+/, "")
        .replace(/^\s*(?:[-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?/, "")
        .replace(/^\s*>\s?/, "")
        .replace(/(\*\*|__|\*|_|~~|`)(?=\S)([^\n]*?\S)\1/g, "$2")
        .replace(/`/g, "")
        .trim()
    )
    .filter((l) => l && !/^[-*_=|: ]+$/.test(l))
    .map((l) => (/[.!?…:;,。]$/.test(l) ? l : l + "."))
    .join("\n");
}

// { title, description, episodes: [{ n, title, text }] }: one episode per "## " section, in order.
export function parseOutline(md, fallbackTitle = "Show") {
  // NFC, as rclone stores names: an NFD heading (pasted from a PDF) would name a file the feed can't find
  const lines = frontMatter(md.normalize("NFC").replace(/\r\n?/g, "\n")).body.split("\n");
  let title = "";
  const intro = [];
  const episodes = [];
  let cur = null;
  let fence = false;
  for (const l of lines) {
    if (/^\s*```/.test(l)) fence = !fence;
    const h1 = !fence && l.match(/^#\s+(.+?)\s*#*\s*$/);
    const h2 = !fence && l.match(/^##\s+(.+?)\s*#*\s*$/);
    if (h1 && !title && !cur) title = speakable(h1[1]).replace(/\.$/, "");
    else if (h2) episodes.push((cur = { title: speakable(h2[1]).replace(/\.$/, ""), body: [] }));
    else (cur ? cur.body : intro).push(l);
  }
  return {
    title: title || String(fallbackTitle).normalize("NFC"),
    description: speakable(intro.join("\n")).replace(/\n/g, " "),
    episodes: episodes.map((e, i) => {
      const body = speakable(e.body.join("\n"));
      return { n: i + 1, title: e.title, text: e.title + ".\n\n" + body, summary: body.replace(/\n/g, " ").slice(0, 400) };
    }),
  };
}

// "03 Offer and acceptance.m4a": the number keeps Gallery's name order the outline's order.
export function episodeFile(n, title, count) {
  const safe = title.replace(/[\/\\:\u0000-\u001f]+/g, "-").replace(/^\.+/, "").trim().slice(0, 80) || "Episode";
  return String(n).padStart(Math.max(2, String(count).length), "0") + " " + safe + ".m4a";
}

// A show's folder name: one segment, no dotfile.
export function showName(s) {
  const t = String(s || "").normalize("NFC").replace(/[\/\\:\u0000-\u001f]+/g, "-").replace(/^\.+/, "").trim().slice(0, 80);
  return t || null;
}

// Each episode's guid: show + heading, so it survives a reorder; a repeated heading adds its count.
export function episodeIds(show, titles) {
  const seen = new Map();
  return titles.map((t) => {
    const k = (seen.get(t) || 0) + 1;
    seen.set(t, k);
    return createHash("sha256").update(show + "\n" + t + (k > 1 ? "\n#" + k : "")).digest("hex").slice(0, 32);
  });
}

// ---------- rendering ----------

function installedVoices() {
  const r = spawnSync("say", ["-v", "?"], { encoding: "utf8" });
  return (r.stdout || "").split("\n").map((l) => (l.match(/^(.*?)\s+[a-z]{2,3}_[A-Za-z0-9]{2,4}\s+#/) || [])[1] || "").filter(Boolean);
}

export function pickVoice(lang, wanted, installed) {
  if (wanted) {
    if (!installed.some((v) => v === wanted || v.startsWith(wanted + " ("))) throw new Error(`voice not installed: ${wanted} (see: say -v '?')`);
    return wanted;
  }
  const list = VOICES[lang];
  if (!list) throw new Error(`no voices listed for --lang ${lang} (one of: ${Object.keys(VOICES).join(", ")})`);
  const v = list.find((w) => installed.some((i) => i === w || i.startsWith(w + " (")));
  if (!v) throw new Error(`no ${lang} voice installed; add one in System Settings > Accessibility > Spoken Content > System Voice > Manage Voices…`);
  return v;
}

function durationOf(file) {
  const r = spawnSync("afinfo", [file], { encoding: "utf8" });
  const m = (r.stdout || "").match(/estimated duration:\s*([\d.]+)/);
  return m ? Number(m[1]) : 0;
}

// The episode's audio, rendered once per (voice, text) and kept in ~/Library/Caches/recense-shows.
function render(text, voice) {
  const sha = createHash("sha256").update(voice + "\n" + text).digest("hex");
  const out = join(CACHE, sha + ".m4a");
  if (existsSync(out) && durationOf(out) > 0) return out;
  mkdirSync(CACHE, { recursive: true });
  const txt = join(CACHE, sha + ".txt");
  writeFileSync(txt, text);
  const r = spawnSync("say", ["-v", voice, "-o", out, "--file-format=m4af", "--data-format=aac", "-f", txt], { encoding: "utf8" });
  rmSync(txt, { force: true });
  if (r.status !== 0 || !(durationOf(out) > 0)) throw new Error("say failed: " + (r.stderr || r.status));
  return out;
}

function rclone(args) {
  const r = spawnSync("rclone", args, { encoding: "utf8", env: { ...process.env, RCLONE_CONFIG } });
  if (r.status !== 0) throw new Error("rclone " + args[0] + " failed: " + (r.stderr || "").trim().split("\n").slice(-3).join(" | "));
  return r.stdout;
}

async function publish(file, opts) {
  const src = realpathSync(resolve(file));
  const md = readFileSync(src, "utf8");
  const outline = parseOutline(md, basename(src).replace(/\.[^.]+$/, ""));
  if (!outline.episodes.length) throw new Error("no '## ' sections in " + src);
  const show = showName(opts.show || outline.title);
  if (!show) throw new Error("bad show name");
  const why = refusal(src, md, show);
  if (why) throw new Error(`refused: client matters never leave this Mac (A6): ${why}`);
  const lang = opts.lang || "en";
  const voice = pickVoice(lang, opts.voice, installedVoices());

  const stage = mkdtempSync(join(tmpdir(), "show-"));
  try {
    const manifest = { title: show, description: outline.description, lang, voice, updated: new Date().toISOString(), episodes: [] };
    const ids = episodeIds(show, outline.episodes.map((e) => e.title));
    for (const e of outline.episodes) {
      const name = episodeFile(e.n, e.title, outline.episodes.length);
      const audio = render(e.text, voice);
      copyFileSync(audio, join(stage, name));
      const duration = Math.round(durationOf(join(stage, name)));
      const id = ids[e.n - 1];
      manifest.episodes.push({ n: e.n, id, title: e.title, file: name, duration, summary: e.summary });
      console.log(`${name}  ${duration}s`);
    }
    writeFileSync(join(stage, MANIFEST), JSON.stringify(manifest, null, 2) + "\n");

    const dest = `${REMOTE}/files/Shows/${show}`;
    const backup = `${REMOTE}/trash/${new Date().toISOString().slice(0, 10)}/Shows/${show}`;
    if (opts["dry-run"]) {
      console.log(`dry run: would sync ${outline.episodes.length} episodes to ${dest}`);
      return;
    }
    // sync: a section removed from the outline leaves the show too, kept a day in trash/
    rclone(["sync", stage, dest, "--backup-dir", backup, "--local-unicode-normalization", "--stats", "0", "-q"]);
    console.log(`published ${outline.episodes.length} episodes to Main > Shows > ${show}`);
    console.log(`next: node chau/show.mjs invite "${show}" --name <who>`);
  } finally {
    rmSync(stage, { recursive: true, force: true });
  }
}

// ---------- invitations ----------

function keychain(account) {
  const r = spawnSync("/usr/bin/security", ["find-generic-password", "-s", "gallery-access", "-a", account, "-w"], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`Keychain item gallery-access/${account} missing: run chau/setup.sh`);
  return r.stdout.trim();
}

// The owner's API over the Access service token (the Mac's x-gallery header stands in for Origin).
function ownerCall() {
  const id = keychain("client-id");
  const secret = keychain("client-secret");
  return (path, init = {}) =>
    fetch(BASE + path, { ...init, headers: { "cf-access-client-id": id, "cf-access-client-secret": secret, "x-gallery": "1", "content-type": "application/json", ...(init.headers || {}) } });
}

// One view-only link for the feed (never claimed, so Podcasts can always fetch it) and, for a guest,
// one for the web page with react and comment. Returns [{ kind, id, url }].
export async function makeInvites(call, { show, name, days = 30, guest = false }) {
  const dir = "Shows/" + show;
  const ttl = Math.round(Number(days) * 86400);
  const post = async (body) => {
    const r = await call("/main/api/invites", { method: "POST", body: JSON.stringify(body) });
    if (!r.ok) throw new Error(`invite failed: ${r.status} ${await r.text()}`);
    return r.json();
  };
  const out = [];
  const feed = await post({ name: name + " · podcast", ttl, dir, viewOnly: true, perms: { download: true, upload: false, comment: false, react: false, annotate: false } });
  out.push({ kind: "feed", id: feed.id, url: feed.url + "/feed.xml" });
  if (guest) {
    let web;
    try {
      web = await post({ name, ttl, dir, perms: { view: true, download: true, upload: false, comment: true, react: true, annotate: false } });
    } catch (e) {
      throw new Error(`${e.message} (the feed link was made: ${feed.url}/feed.xml, revoke id ${feed.id})`);
    }
    out.push({ kind: "web", id: web.id, url: web.url });
  }
  return out;
}

// ---------- command line ----------

function args(argv) {
  const pos = [];
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--dry-run" || a === "--guest") o[a.slice(2)] = true;
    else if (a.startsWith("--")) o[a.slice(2)] = argv[++i];
    else pos.push(a);
  }
  return { pos, o };
}

async function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  const { pos, o } = args(rest);
  if (cmd === "publish" && pos[0]) return publish(pos[0], o);
  if (cmd === "invite" && pos[0] && o.name) {
    const show = showName(pos[0]);
    const links = await makeInvites(ownerCall(), { show, name: o.name, days: o.days || 30, guest: !!o.guest });
    for (const l of links) console.log(`${l.kind === "feed" ? "Podcasts feed" : "Web page    "}  ${l.url}\n  revoke: node chau/show.mjs revoke ${l.id}`);
    console.log(`expires in ${o.days || 30} days. On the iPhone: Podcasts > Library > ••• > Follow a Show by URL…`);
    return;
  }
  if (cmd === "revoke" && /^[0-9a-f]{16}$/.test(pos[0] || "")) {
    const r = await ownerCall()("/main/api/invites/" + pos[0], { method: "DELETE" });
    console.log(r.ok ? "revoked " + pos[0] : `revoke failed: ${r.status}`);
    if (!r.ok) process.exitCode = 1;
    return;
  }
  console.error("usage:\n  node chau/show.mjs publish <outline.md> [--show <name>] [--lang en|vi|fr] [--voice <name>] [--dry-run]\n  node chau/show.mjs invite <show> --name <who> [--days 30] [--guest]\n  node chau/show.mjs revoke <id>");
  process.exitCode = 2;
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((e) => {
    console.error(e.message);
    process.exitCode = 1;
  });
}
