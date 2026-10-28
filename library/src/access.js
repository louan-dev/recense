// Who is asking: the owner, or nobody.
//
// Main and every write go through Cloudflare Access. The Worker never trusts the edge alone: it
// verifies the signed Access token itself (signature, audience, issuer, expiry) and then asks for
// one of two identities:
//   - the owner in a browser: the token's email equals OWNER_EMAIL
//   - the owner's Mac: a service token whose client id equals SERVICE_CLIENT_ID
// The token arrives as the Cf-Access-Jwt-Assertion header on paths Access protects, or as the
// CF_Authorization cookie anywhere on this host once the owner has signed in.

const b64url = (s) =>
  Uint8Array.from(
    atob(s.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(s.length / 4) * 4, "=")),
    (c) => c.charCodeAt(0)
  );

let accessCerts = { at: 0, keys: [] };

function token(req) {
  const header = req.headers.get("cf-access-jwt-assertion");
  if (header) return header;

  const cookie = req.headers.get("cookie") || "";
  const m = cookie.match(/(?:^|;\s*)CF_Authorization=([^;]+)/);
  return m ? m[1] : "";
}

// The claims of a valid Access token, or null.
async function accessClaims(req, env) {
  const team = String(env.ACCESS_TEAM_DOMAIN || "").toLowerCase();
  const aud = String(env.ACCESS_AUD || "");
  const jwt = token(req);

  if (!/^[a-z0-9-]+\.cloudflareaccess\.com$/.test(team) || !aud || !jwt) return null;

  const parts = jwt.split(".");
  if (parts.length !== 3) return null;

  let head, body;

  try {
    head = JSON.parse(new TextDecoder().decode(b64url(parts[0])));
    body = JSON.parse(new TextDecoder().decode(b64url(parts[1])));
  } catch (e) {
    return null;
  }

  const now = Date.now() / 1000;

  if (head.alg !== "RS256") return null;
  if (![].concat(body.aud || []).includes(aud)) return null;
  if (body.iss !== "https://" + team) return null;
  if (!(Number(body.exp) > now) || (body.nbf && Number(body.nbf) > now + 60)) return null;

  // fetch the keys at most once a minute, even if someone sends unknown key ids
  if (!accessCerts.keys.some((k) => k.kid === head.kid) && Date.now() - accessCerts.at > 60e3) {
    accessCerts.at = Date.now();

    const r = await fetch("https://" + team + "/cdn-cgi/access/certs");
    if (r.ok) accessCerts.keys = (await r.json()).keys || [];
  }

  const jwk = accessCerts.keys.find((k) => k.kid === head.kid);
  if (!jwk) return null;

  const key = await crypto.subtle.importKey(
    "jwk",
    jwk,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"]
  );

  const good = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    key,
    b64url(parts[2]),
    new TextEncoder().encode(parts[0] + "." + parts[1])
  );

  return good ? body : null;
}

// Someone Cloudflare Access let through who isn't the owner (signed in with another email, say on
// a phone): their email, so the page can say so and offer to switch accounts. Null for everyone
// else, who keep getting the plain 404.
export async function signedInAs(req, env) {
  try {
    const c = await accessClaims(req, env);
    return c && c.email ? String(c.email) : null;
  } catch (e) {
    return null;
  }
}

export async function isOwner(req, env) {
  // OWNER_EMAIL may list several addresses, comma-separated. Left unset, the Access policy decides:
  // any email it let through counts, since the token's audience is checked and Access only issues
  // one to emails the policy includes.
  const emails = String(env.OWNER_EMAIL || "").toLowerCase().split(",").map((e) => e.trim()).filter(Boolean);
  // one Access service token per device, comma-separated: a lost device is cut off by revoking just its token
  const clients = String(env.SERVICE_CLIENT_ID || "").split(",").map((c) => c.trim()).filter(Boolean);

  let claims = null;

  try {
    claims = await accessClaims(req, env);
  } catch (e) {
    return false;
  }

  if (!claims) return false;
  if (claims.email && !emails.length) return true;
  if (emails.includes(String(claims.email || "").trim().toLowerCase())) return true;
  if (!claims.email && clients.includes(String(claims.common_name || ""))) return true;

  return false;
}

// Every state-changing request must come from this site's own pages or the owner's Mac.
// Browsers always send Origin on these requests; the Mac sends the x-gallery header.
export function sameSite(req, url) {
  const origin = req.headers.get("origin");
  return origin ? origin === url.origin : req.headers.get("x-gallery") === "1";
}
