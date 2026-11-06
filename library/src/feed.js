// A show's podcast feed: GET /m/<token>/feed.xml for an invitation to a folder that holds .show.json
// (written by chau/show.mjs). RSS 2.0 with the iTunes namespace, a serial show in outline order;
// each enclosure is the invitation's own file route, so every download is checked like any other.
// A folder without a show, or a show with no episode this link may see, is the same 404 as a bad link.

import { OWNER, urlPath } from "./common.js";

const FILES = "files/";
const MANIFEST = ".show.json";

const xml = (s) =>
  String(s == null ? "" : s)
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f￾￿]/g, "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");

const hms = (sec) => {
  const s = Math.max(0, Math.round(Number(sec) || 0));
  return [Math.floor(s / 3600), Math.floor((s % 3600) / 60), s % 60].map((x) => String(x).padStart(2, "0")).join(":");
};

// The show's manifest, or null.
async function readShow(env, folder) {
  try {
    const o = await env.MAIN.get(FILES + (folder ? folder + "/" : "") + MANIFEST);
    const j = o ? await o.json() : null;
    return j && Array.isArray(j.episodes) ? j : null;
  } catch (e) {
    return null;
  }
}

// RSS text, or null when there is nothing this link may hear. allowed(name) is the invitation's view check.
export async function showFeed(env, folder, allowed, origin, base) {
  const show = await readShow(env, folder);
  if (!show) return null;

  // sizes from one listing, so an enclosure's length is the file's real one
  const prefix = FILES + (folder ? folder + "/" : "");
  const sizes = new Map();
  let cursor;
  do {
    const r = await env.MAIN.list({ prefix, delimiter: "/", cursor });
    for (const o of r.objects) sizes.set(o.key.slice(prefix.length).normalize("NFC"), o);
    cursor = r.truncated ? r.cursor : undefined;
  } while (cursor);

  const updated = Date.parse(show.updated) || Date.now();
  const eps = show.episodes
    .filter((e) => e && typeof e.file === "string" && !e.file.includes("/") && sizes.has(e.file.normalize("NFC")))
    .map((e) => ({ ...e, key: sizes.get(e.file.normalize("NFC")).key.slice(prefix.length) })) // the name as stored
    .filter((e) => allowed(e.key))
    .sort((a, b) => (a.n ?? 0) - (b.n ?? 0));
  if (!eps.length) return null;

  const title = show.title || folder.split("/").pop();
  const link = origin + base;
  const items = eps.map((e, i) => {
    const o = sizes.get(e.key.normalize("NFC"));
    // serial shows sort by episode number; dates a second apart keep apps that sort by date in order too
    const date = new Date(updated - (eps.length - 1 - i) * 1000).toUTCString();
    return `    <item>
      <title>${xml(e.title)}</title>
      <itunes:title>${xml(e.title)}</itunes:title>
      <itunes:episode>${i + 1}</itunes:episode>
      <itunes:episodeType>full</itunes:episodeType>
      <guid isPermaLink="false">${xml(e.id || e.file)}</guid>
      <pubDate>${date}</pubDate>
      <description>${xml(e.summary || "")}</description>
      <enclosure url="${xml(link + "/f/" + urlPath(e.key))}" length="${o.size}" type="audio/mp4"/>
      <itunes:duration>${hms(e.duration)}</itunes:duration>
      <itunes:explicit>false</itunes:explicit>
    </item>`;
  });

  return `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:atom="http://www.w3.org/2005/Atom">
  <channel>
    <title>${xml(title)}</title>
    <link>${xml(link)}</link>
    <atom:link href="${xml(link + "/feed.xml")}" rel="self" type="application/rss+xml"/>
    <description>${xml(show.description || title)}</description>
    <language>${xml(show.lang || "en")}</language>
    <lastBuildDate>${new Date(updated).toUTCString()}</lastBuildDate>
    <itunes:author>${xml(OWNER)}</itunes:author>
    <itunes:type>serial</itunes:type>
    <itunes:explicit>false</itunes:explicit>
    <itunes:block>Yes</itunes:block>
${items.join("\n")}
  </channel>
</rss>
`;
}
