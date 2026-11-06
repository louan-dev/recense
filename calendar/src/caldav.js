// caldav.js: G1 Phase 0 CalDAV server (docs/specs/sync.md §7). One user, R2 only, no D1 yet.
// R2 layout (bucket `sync`, protocol first):
//   caldav/users/<user>/<cal>/.calendar.json    displayname, color, order, description, deleted
//   caldav/users/<user>/<cal>/<resource>.ics    event, byte for byte as the client sent it
//   caldav/trash/<user>/<cal>/<resource>.<unix>.ics   copy kept on every DELETE or overwrite
// CTag = sha256 over the sorted (name, etag) list, so it changes on every write without a counter.
// Not yet: sync-collection, time-range filtering (calendar-query returns every event), scheduling, D1.

const D = "DAV:", C = "urn:ietf:params:xml:ns:caldav", CS = "http://calendarserver.org/ns/", IC = "http://apple.com/ns/ical/";
const PREFIX = { [D]: "d", [C]: "c", [CS]: "cs", [IC]: "ic" };
const META = ".calendar.json";
const MAX_ICS = 1024 * 1024;
const NAME = /^[A-Za-z0-9][A-Za-z0-9._@+=-]{0,200}$/;

const xesc = s => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const xunesc = s => String(s).replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, "&");
const hex = buf => [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, "0")).join("");
const sha = async s => hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));

// ---- tiny XML reader: enough for PROPFIND/REPORT/PROPPATCH/MKCALENDAR bodies
export function parseXml(src) {
  const root = { name: "#root", ns: "", kids: [], text: "" }, stack = [root], scopes = [{ "": "" }];
  const re = /<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<!\[CDATA\[([\s\S]*?)\]\]>|<(\/?)([A-Za-z_][\w.:-]*)((?:\s+[\w.:-]+\s*=\s*(?:"[^"]*"|'[^']*'))*)\s*(\/?)>|([^<]+)/g;
  let m;
  while ((m = re.exec(src))) {
    const top = stack.at(-1);
    if (m[1] !== undefined) { top.text += m[1]; continue; }
    if (m[6] !== undefined) { top.text += xunesc(m[6]); continue; }
    if (!m[3]) continue;
    if (m[2]) { stack.length > 1 && stack.pop(); scopes.length > 1 && scopes.pop(); continue; }
    const scope = { ...scopes.at(-1) }, attrs = {};
    for (const a of m[4].matchAll(/([\w.:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)) {
      const v = xunesc(a[2] ?? a[3]);
      if (a[1] === "xmlns") scope[""] = v; else if (a[1].startsWith("xmlns:")) scope[a[1].slice(6)] = v; else attrs[a[1]] = v;
    }
    const [p, local] = m[3].includes(":") ? m[3].split(":", 2) : ["", m[3]];
    const el = { name: local, ns: scope[p] ?? "", attrs, kids: [], text: "" };
    top.kids.push(el);
    if (!m[5]) { stack.push(el); scopes.push(scope); }
  }
  return root;
}
const kid = (el, ns, name) => el?.kids.find(k => k.ns === ns && k.name === name);
const find = (el, ns, name) => { if (!el) return; if (el.ns === ns && el.name === name) return el; for (const k of el.kids) { const f = find(k, ns, name); if (f) return f; } };
const innerXml = el => el.text.trim() ? xesc(el.text.trim()) : el.kids.map(k => `<${k.name} xmlns="${xesc(k.ns)}">${innerXml(k)}</${k.name}>`).join("");

// ---- responses
const xml = (status, body, extra = {}) => new Response(`<?xml version="1.0" encoding="utf-8"?>\n${body}`, { status, headers: { "Content-Type": "application/xml; charset=utf-8", ...extra } });
const text = (status, s, extra = {}) => new Response(s, { status, headers: { "Content-Type": "text/plain; charset=utf-8", ...extra } });
const tag = (ns, name, inner) => { const p = PREFIX[ns]; const open = p ? `${p}:${name}` : `x:${name} xmlns:x="${xesc(ns)}"`; const close = p ? `${p}:${name}` : `x:${name}`; return inner === undefined || inner === "" ? `<${open}/>` : `<${open}>${inner}</${close}>`; };
const multistatus = rs => `<d:multistatus xmlns:d="${D}" xmlns:c="${C}" xmlns:cs="${CS}" xmlns:ic="${IC}">${rs.join("")}</d:multistatus>`;
function response(href, want, values) {
  const ok = [], missing = [];
  for (const [ns, name] of want) { const v = values(ns, name); v === undefined ? missing.push(tag(ns, name)) : ok.push(tag(ns, name, v)); }
  let s = `<d:response><d:href>${xesc(href)}</d:href>`;
  if (ok.length) s += `<d:propstat><d:prop>${ok.join("")}</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>`;
  if (missing.length) s += `<d:propstat><d:prop>${missing.join("")}</d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>`;
  return s + "</d:response>";
}

const PRIVS = ["all", "read", "write", "write-content", "write-properties", "bind", "unbind", "read-current-user-privilege-set"].map(p => `<d:privilege><d:${p}/></d:privilege>`).join("");

// ---- storage helpers
const base = user => `caldav/users/${user}/`;
async function listAll(env, prefix, delimiter) {
  const objects = [], prefixes = []; let cursor;
  do { const r = await env.STORE.list({ prefix, delimiter, cursor, include: ["customMetadata"] }); objects.push(...r.objects); prefixes.push(...(r.delimitedPrefixes || [])); cursor = r.truncated ? r.cursor : undefined; } while (cursor);
  return { objects, prefixes };
}
async function readMeta(env, user, cal) { const o = await env.STORE.get(base(user) + cal + "/" + META); return o ? await o.json() : null; }
const writeMeta = (env, user, cal, m) => env.STORE.put(base(user) + cal + "/" + META, JSON.stringify(m), { httpMetadata: { contentType: "application/json" } });
async function calendars(env, user) {
  const { prefixes } = await listAll(env, base(user), "/"), out = [];
  for (const p of prefixes) { const cal = p.slice(base(user).length, -1); const m = await readMeta(env, user, cal); if (m && !m.deleted) out.push({ cal, meta: m }); }
  if (!out.length) { const meta = { displayname: env.CALDAV_DEFAULT_NAME || "Calendar", created: new Date().toISOString() }; await writeMeta(env, user, "main", meta); out.push({ cal: "main", meta }); }
  return out;
}
async function events(env, user, cal) {
  const { objects } = await listAll(env, base(user) + cal + "/");
  return objects.filter(o => o.key.endsWith(".ics")).map(o => ({ name: o.key.slice(base(user).length + cal.length + 1), etag: o.httpEtag, size: o.size, key: o.key }));
}
const ctag = async evs => '"' + (await sha(evs.map(e => e.name + " " + e.etag).sort().join("\n"))).slice(0, 32) + '"';

// ---- request props
function wanted(body, fallback) {
  const prop = find(body, D, "prop");
  if (!prop || find(body, D, "allprop")) return fallback;
  return prop.kids.map(k => [k.ns, k.name]);
}
const CAL_DEFAULT = [[D, "resourcetype"], [D, "displayname"], [CS, "getctag"], [IC, "calendar-color"], [C, "supported-calendar-component-set"], [D, "current-user-privilege-set"]];
const EV_DEFAULT = [[D, "getetag"], [D, "getcontenttype"], [D, "resourcetype"]];

export async function caldav(req, env, url) {
  const user = env.CALDAV_USER || "chau";
  const auth = await authorize(req, env, user);
  if (auth) return auth;
  const path = decodeURIComponent(url.pathname);
  const m = HOST.exec(path);
  if (!m) return text(404, "Not found");
  const sub = m[1] || m[2], cal = m[4], res = m[5];
  if (sub === "calendars" && m[3] !== user) return text(403, "Forbidden");
  const method = req.method;
  const DAVH = { DAV: "1, 3, calendar-access, extended-mkcol", "MS-Author-Via": "DAV" };
  if (method === "OPTIONS") return new Response(null, { status: 200, headers: { ...DAVH, Allow: "OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, REPORT, MKCALENDAR, MKCOL" } });

  const body = ["PROPFIND", "REPORT", "PROPPATCH", "MKCALENDAR", "MKCOL"].includes(method) ? parseXml(await req.text()) : null;
  const principal = `/dav/principals/${user}/`, home = `/dav/calendars/${user}/`;
  const hrefCal = c => `${home}${encodeURIComponent(c)}/`;
  const principalProps = (ns, name) => {
    if (ns === D && name === "current-user-principal") return `<d:href>${principal}</d:href>`;
    if (ns === D && name === "principal-URL") return `<d:href>${principal}</d:href>`;
    if (ns === D && name === "displayname") return xesc(user);
    if (ns === C && name === "calendar-home-set") return `<d:href>${home}</d:href>`;
    if (ns === C && name === "calendar-user-address-set") return (env.OWNER_EMAIL ? `<d:href>mailto:${xesc(env.OWNER_EMAIL)}</d:href>` : "") + `<d:href>${principal}</d:href>`;
    if (ns === D && name === "principal-collection-set") return `<d:href>/dav/principals/</d:href>`;
    if (ns === D && name === "current-user-privilege-set") return PRIVS;
    if (ns === D && name === "supported-report-set") return "";
  };

  // ---- discovery: /, /dav/, principals
  if (!sub || sub === "principals") {
    if (method !== "PROPFIND") return text(405, "Method not allowed");
    const want = wanted(body, [[D, "current-user-principal"], [D, "resourcetype"]]);
    const href = sub === "principals" ? principal : path.endsWith("/") ? path : path + "/";
    return xml(207, multistatus([response(href, want, (ns, name) => ns === D && name === "resourcetype" ? (sub ? "<d:collection/><d:principal/>" : "<d:collection/>") : principalProps(ns, name))]), DAVH);
  }

  // ---- calendar home
  if (!cal) {
    if (method !== "PROPFIND") return text(405, "Method not allowed");
    const want = wanted(body, [[D, "resourcetype"], [D, "displayname"]]);
    const depth = req.headers.get("Depth") ?? "1";
    const out = [response(home, want, (ns, name) => ns === D && name === "resourcetype" ? "<d:collection/>" : ns === D && name === "displayname" ? "Calendars" : principalProps(ns, name))];
    if (depth !== "0") for (const c of await calendars(env, user)) out.push(response(hrefCal(c.cal), want, await calProps(env, user, c.cal, c.meta)));
    return xml(207, multistatus(out), DAVH);
  }
  if (!NAME.test(cal)) return text(400, "Bad calendar name");

  // ---- calendar collection
  if (!res) {
    if (method === "MKCALENDAR" || method === "MKCOL") {
      const old = await readMeta(env, user, cal);
      if (old && !old.deleted) return text(405, "Already exists");
      const meta = { created: new Date().toISOString() };
      applyProps(meta, find(body, D, "set"));
      await writeMeta(env, user, cal, meta);
      return new Response(null, { status: 201 });
    }
    const meta = await readMeta(env, user, cal);
    if (!meta || meta.deleted) return text(404, "No such calendar");
    if (method === "PROPPATCH") {
      const set = find(body, D, "set"), names = [];
      applyProps(meta, set, names);
      await writeMeta(env, user, cal, meta);
      return xml(207, multistatus([`<d:response><d:href>${xesc(hrefCal(cal))}</d:href><d:propstat><d:prop>${names.map(([ns, n]) => tag(ns, n)).join("")}</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>`]));
    }
    if (method === "DELETE") { meta.deleted = new Date().toISOString(); await writeMeta(env, user, cal, meta); return new Response(null, { status: 204 }); } // soft: events stay in R2
    if (method === "PROPFIND") {
      const want = wanted(body, CAL_DEFAULT);
      const evs = await events(env, user, cal);
      const out = [response(hrefCal(cal), want, await calProps(env, user, cal, meta, evs))];
      if ((req.headers.get("Depth") ?? "0") !== "0") for (const e of evs) out.push(response(hrefCal(cal) + encodeURIComponent(e.name), want, evProps(e)));
      return xml(207, multistatus(out), DAVH);
    }
    if (method === "REPORT") return report(env, user, cal, body, hrefCal(cal));
    return text(405, "Method not allowed");
  }

  // ---- event resource
  if (!NAME.test(res) || !res.endsWith(".ics")) return text(400, "Bad resource name");
  const key = base(user) + cal + "/" + res;
  if (method === "GET" || method === "HEAD") {
    const o = method === "HEAD" ? await env.STORE.head(key) : await env.STORE.get(key);
    if (!o) return text(404, "Not found");
    return new Response(method === "HEAD" ? null : o.body, { headers: { "Content-Type": "text/calendar; charset=utf-8", ETag: o.httpEtag } });
  }
  const meta = await readMeta(env, user, cal);
  if (!meta || meta.deleted) return text(409, "No such calendar");
  const head = await env.STORE.head(key);
  const ifMatch = req.headers.get("If-Match"), ifNone = req.headers.get("If-None-Match");
  if (ifNone === "*" && head) return text(412, "Exists");
  if (ifMatch && (!head || (ifMatch !== "*" && ifMatch !== head.httpEtag))) return text(412, "Changed");
  if (method === "PUT") {
    const ics = await req.text();
    if (ics.length > MAX_ICS) return text(413, "Too large");
    if (!/^BEGIN:VCALENDAR/m.test(ics) || !/^END:VCALENDAR/m.test(ics)) return text(415, "Not iCalendar");
    const uid = (/^UID[;:](?:[^:\r\n]*:)?(.*)$/m.exec(ics)?.[1] || "").trim();
    if (head) await trash(env, user, cal, res, key);
    const put = await env.STORE.put(key, ics, { httpMetadata: { contentType: "text/calendar; charset=utf-8" }, customMetadata: { uid }, onlyIf: head ? { etagMatches: head.etag } : { etagDoesNotMatch: "*" } });
    if (!put) return text(412, "Changed");
    return new Response(null, { status: head ? 204 : 201, headers: { ETag: put.httpEtag } });
  }
  if (method === "DELETE") {
    if (!head) return text(404, "Not found");
    await trash(env, user, cal, res, key);
    await env.STORE.delete(key);
    return new Response(null, { status: 204 });
  }
  return text(405, "Method not allowed");
}
// /, /dav/, /dav/principals/<u>/, /dav/calendars/<u>/<cal>/<res>
const HOST = /^(?:\/|\/dav\/?|\/dav\/(principals)(?:\/[^/]*)?\/?|\/dav\/(calendars)\/([^/]+)\/?(?:([^/]+)\/?([^/]+)?)?)$/;

async function trash(env, user, cal, res, key) {
  const o = await env.STORE.get(key); if (!o) return;
  await env.STORE.put(`caldav/trash/${user}/${cal}/${res.replace(/\.ics$/, "")}.${Math.floor(Date.now() / 1000)}.ics`, await o.text(), { httpMetadata: { contentType: "text/calendar; charset=utf-8" } });
}

function applyProps(meta, set, names = []) {
  const prop = set && kid(set, D, "prop"); if (!prop) return;
  for (const k of prop.kids) {
    names.push([k.ns, k.name]);
    if (k.ns === D && k.name === "displayname") meta.displayname = k.text.trim();
    else if (k.ns === IC && k.name === "calendar-color") meta.color = k.text.trim();
    else if (k.ns === IC && k.name === "calendar-order") meta.order = k.text.trim();
    else if (k.ns === C && k.name === "calendar-description") meta.description = k.text.trim();
    else if (k.ns === C && k.name === "calendar-timezone") meta.timezone = k.text.trim();
  }
}

async function calProps(env, user, cal, meta, evs) {
  evs ??= await events(env, user, cal);
  const tagv = await ctag(evs);
  return (ns, name) => {
    if (ns === D && name === "resourcetype") return "<d:collection/><c:calendar/>";
    if (ns === D && name === "displayname") return xesc(meta.displayname || cal);
    if (ns === CS && name === "getctag") return xesc(tagv);
    if (ns === D && name === "getetag") return xesc(tagv);
    if (ns === IC && name === "calendar-color") return meta.color ? xesc(meta.color) : undefined;
    if (ns === IC && name === "calendar-order") return meta.order ? xesc(meta.order) : undefined;
    if (ns === C && name === "calendar-description") return meta.description ? xesc(meta.description) : undefined;
    if (ns === C && name === "calendar-timezone") return meta.timezone ? xesc(meta.timezone) : undefined;
    if (ns === C && name === "supported-calendar-component-set") return `<c:comp name="VEVENT"/>`;
    if (ns === C && name === "supported-calendar-data") return `<c:calendar-data content-type="text/calendar" version="2.0"/>`;
    if (ns === C && name === "max-resource-size") return String(MAX_ICS);
    if (ns === D && name === "current-user-privilege-set") return PRIVS;
    if (ns === D && name === "owner") return `<d:href>/dav/principals/${user}/</d:href>`;
    if (ns === D && name === "supported-report-set") return ["calendar-multiget", "calendar-query"].map(r => `<d:supported-report><d:report><c:${r}/></d:report></d:supported-report>`).join("");
  };
}
const evProps = (e, data) => (ns, name) => {
  if (ns === D && name === "getetag") return xesc(e.etag);
  if (ns === D && name === "getcontenttype") return "text/calendar; charset=utf-8; component=vevent";
  if (ns === D && name === "resourcetype") return "";
  if (ns === D && name === "getcontentlength") return String(e.size);
  if (ns === C && name === "calendar-data") return data === undefined ? undefined : xesc(data);
};

async function report(env, user, cal, body, href) {
  const root = body.kids[0];
  if (!root || root.ns !== C || !["calendar-multiget", "calendar-query"].includes(root.name)) return text(403, "Unsupported report");
  const want = wanted(body, EV_DEFAULT), withData = want.some(([ns, n]) => ns === C && n === "calendar-data");
  let list;
  if (root.name === "calendar-multiget") {
    list = root.kids.filter(k => k.ns === D && k.name === "href").map(k => decodeURIComponent(k.text.trim())).map(h => ({ href: h, name: h.startsWith(href) ? h.slice(href.length) : null }));
  } else {
    list = (await events(env, user, cal)).map(e => ({ href: href + encodeURIComponent(e.name), name: e.name }));
  }
  const out = [];
  for (const it of list) {
    const o = it.name && NAME.test(it.name) ? (withData ? await env.STORE.get(base(user) + cal + "/" + it.name) : await env.STORE.head(base(user) + cal + "/" + it.name)) : null;
    if (!o) { out.push(`<d:response><d:href>${xesc(it.href)}</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>`); continue; }
    const data = withData ? await o.text() : undefined;
    out.push(response(it.href, want, evProps({ etag: o.httpEtag, size: o.size }, data)));
  }
  return xml(207, multistatus(out));
}

// ---- auth: HTTP Basic, one user, password stored only as a sha256 hex secret (CALDAV_PASS_HASH)
async function authorize(req, env, user) {
  const want = String(env.CALDAV_PASS_HASH || "").trim().toLowerCase();
  const deny = () => new Response("Authentication required", { status: 401, headers: { "WWW-Authenticate": 'Basic realm="sync", charset="UTF-8"' } });
  if (!/^[0-9a-f]{64}$/.test(want)) return text(503, "Not configured");
  const h = req.headers.get("Authorization") || "";
  if (!h.startsWith("Basic ")) return deny();
  let dec; try { dec = atob(h.slice(6)); } catch { return deny(); }
  const i = dec.indexOf(":"); if (i < 0) return deny();
  const got = await sha(dec.slice(i + 1));
  let diff = dec.slice(0, i) === user ? 0 : 1;
  for (let k = 0; k < 64; k++) diff |= got.charCodeAt(k) ^ want.charCodeAt(k);
  return diff ? deny() : null;
}
