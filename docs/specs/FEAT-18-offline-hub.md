# FEAT-18 · The offline Recense hub: one address any browser opens, served by our own Mac

From: owner 2026-11-16 · Status: `[~]` H1 building

## Rule
- One web address, `https://recense.local/`, opens Recense in any browser on the home network, with no internet.
- It is served by a Mac we own: the M1 now, the M4 Mac mini later. Each hub also answers at its own name
  (`mac.recense.local`, later `mini.recense.local`).
- **The hub is a helper, never the only copy.** Every device keeps its own copy and keeps writing with no hub.
  The library survives a dead Mac.
- The shell (the page and its code) comes from one origin, `https://recense.local`. Data may come from any peer (H2+).
- Certificates come from **our own root**, name-constrained to `recense.local` and `*.recense.local`. No paid domain.
- The Worker page `/main/editor/` (UI-12 S1) stays an optional install source only.

## Offline-first gate (outside services)
- At the moment of use: **none.** The LAN, mDNS (Bonjour) and the hub are all on hardware we own.
- Setup once: none (openssl and the root are local; the profile travels by AirDrop or a cable).
- Cloudflare R2: H2 only, as the library's second copy until the mini arrives. Never needed to write or read a note.

## H1 · Draftpad + sync (this phase)
Terms:
- **mDNS** = multicast DNS: devices on one network answer "who is recense.local?" themselves, with no DNS server.
- **PWA** = a web page that installs like an app, with a service worker that keeps it for offline use.
- **Name constraint** = a rule written into the root: it can only vouch for names under `recense.local`.
  A stolen root key can't impersonate any other site.

### H1a · The daemon (`hub/`, executable `recense-hub`)
- A Swift package of its own. It compiles `shared/notesync.swift` by symlink: the same merge as the apps, one source.
- Uses Foundation, Network and dnssd only. No AppKit, no window, no login session: it runs headless on the mini.
- It's started by a LaunchDaemon (`hub/launchd/local.recense.hub.plist`), with `UserName` set to the owner,
  so it runs from boot with no one logged in. `KeepAlive` restarts it.
- It serves HTTPS on all interfaces, port 443 by default (`--port`).
  The app's loopback server (127.0.0.1:47123) is untouched.
- It publishes A/AAAA records for `recense.local` and `mac.recense.local` (`--name`), plus an `_https._tcp` service.
  The records cover every LAN address it has, re-read when the network changes.

### H1b · The shell
- `GET /` and the files of `editor/dist/pwa/` (`--shell`). `no-store`: the service worker decides what is kept.
- Unknown paths → 404. Paths are resolved inside the shell folder only (no `..`).
- The service worker never caches `/api/`.

### H1c · Note sync
- `POST /api/note` with JSON `{ "base": string|null, "mine": string }` and header `Authorization: Bearer <token>`.
  - `base` = the text this browser last agreed with the hub.
  - The hub reads the note (theirs) and decides with `planNoteSave(base, mine, theirs)`:
    - `write(m)`: write m.
    - `adopt(t)`: write nothing.
    - `conflict`: mine stays in the note; theirs goes to a sibling (`freeSiblingPath`), as the apps do.
  - `base == null` (first contact) uses `planBlindSave(mine, now)`: the note, then what was typed. A browser scrap never replaces the note.
  - An unreadable note (iCloud placeholder, or no permission) → `503`, nothing written. The browser keeps its copy and retries.
  - Reply: `{ "text": string, "conflict": string|null }`. The browser stores `text` as its new base.
    If the editor hasn't changed since the send, the editor shows `text`.
- The browser (`editor/src/hubsync.js`) keeps IndexedDB as its own copy:
  - A send happens 1.5 s after the last keystroke, on load, and when the browser comes back online.
  - A send never blocks typing; a failed send just waits for the next trigger.
  - It does nothing unless the page's host is `recense.local` or one of its subdomains.
- Token: `~/.config/recense/hub/token` (0600), made on first start.
  - `recense-hub pair` prints `https://recense.local/#pair=<token>`.
  - The page stores the token in IndexedDB and removes it from the address bar.
  - No token → no sync; local writing goes on.
- `GET /api/health` → `{ "ok": true, "name": … }` (no token; nothing private).
- H1 syncs the text only. Ink stays on the device (H2).

### H1d · Storage guard
- Opening `editor.html` from a file (Safari, `file://`) must not throw when `localStorage` is blocked.
  On 2026-11-16 all seven uses in `editor/src` already sat in `try`.
  `test/feat18-hub.test.mjs` guards it: the module imports, and the reopen memo and the palette survive a throwing `localStorage`.

### H1e · Certificates (`hub/scripts/hub-ca.zsh`)
- Root: EC P-256, 10 years. `basicConstraints=critical,CA:TRUE,pathlen:0`.
  `nameConstraints=critical,permitted;DNS:recense.local` (which also covers every subdomain).
  Key in `~/.config/recense/hub-ca/` (0700 folder, 0600 key). Never printed, never in the repo.
- Hub certificate: EC P-256, 820 days (Apple refuses TLS certificates over 825 days).
  - SAN `recense.local`, `*.recense.local`, `<name>.recense.local`; EKU `serverAuth`.
  - Written as `~/.config/recense/hub/tls.p12`.
- `recense-hub-root.mobileconfig`: the root as a profile for iPhone and iPad (installed once, then trusted under
  Settings → General → About → Certificate Trust Settings). On a Mac, the root is added to the System keychain as trusted.

### Done checks (H1)
1. `npm test` and `npm run build` in `editor/` pass.
2. `swift build` in `hub/` and `recense-hub selftest` (the merge, the blind save, path safety, the token check) pass.
3. `curl --cacert root.pem https://mac.recense.local:<port>/` returns the shell; a `POST /api/note` round trip writes a temp note.
4. `zsh strip/build.sh` + `recense selftest` still pass (shared/ untouched, so no iOS compile).
5. On a device (owner): Safari opens `https://recense.local/` with no warning, adds it to the Home Screen,
   writes in airplane mode, and the text reaches `draftpad.md` once back on the Wi-Fi.

### Risks (H1)
- **iCloud Drive and privacy:** the default note lives in iCloud Drive. A launchd job may need Full Disk Access to read it,
  and with no one logged in, iCloud doesn't sync. The hub then answers 503 and the browser keeps its copy; nothing is lost.
- **Multi-label `.local` names** (`mac.recense.local`): Apple's resolvers send any `*.local` name over mDNS.
  Proven on this Mac with `dscacheutil`; untested on iPhone and iPad.
- **Safari storage eviction:** a site not on the Home Screen may lose its storage after about 7 days unused. Add it to the Home Screen.
- **Two hubs claiming `recense.local`:** mDNS renames the second one on conflict. Only one hub may claim it until H3.

## H2 · The library (sketch)
- Pictures, video and sound served from the hub, with the player from `library/src/client/` (one source).
- R2 is the second copy until the mini; then the mini is, with R2 as the off-site copy. The exit is a migration command.
- Ink sync. Data from any peer: CORS between `*.recense.local` hubs, with the shell still from `recense.local`.

## H3 · The standby takes over (sketch)
- The mini claims `recense.local`; the Mac answers only at `mac.recense.local`.
- When the claimant goes silent, the standby claims the name (mDNS probe + announce) and serves from its own copy.
- Merge on return uses the same three-way rule, so neither copy wins blindly.

## Deferred
- The LLM browser.

## Amendments
- 2026-11-16 · created (owner decisions of 2026-11-16, relayed by the coordinator).
