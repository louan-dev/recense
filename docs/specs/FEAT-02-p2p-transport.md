# FEAT-02 · P2P transport (Bluetooth + Wi-Fi, no network required)

From: T-0035 (scope note, 2026-11-12) · owner 2026-11-12 (disaster-messenger triage note, no T-#### assigned) ·
FEAT-09 (2026-11-14, Link layer) · Status: `[~]` (P1–P3 built; real-device check owed)

A shared peer-to-peer transport primitive. Three features need it: FEAT-03 (Share, Bluetooth input), FEAT-09
(carry: pairing and the op log travel over this link), and the disaster-ready messenger idea (triage note under
`docs/specs/triage.md`, "disaster ready messenger", not yet its own spec). Built once here; all three consume it.
Writing one feature's transport twice is the bug the parity rule exists to catch.

## Built `[x]`
- `shared/p2ptransport.swift`: P1 discovery (advertise/browse), P2 session and typed message send, P3 the one
  shared module. `onReceive` decodes `PairMessage` (FEAT-09 P1) and generic named messages by a type tag.
- Carried over it, not yet wired: FEAT-09's `PairMessage` (`shared/carrypair.swift`) and `CarryOp` log lines
  (`shared/carrysync.swift`) — both pure Codable types, so they serialize the same way any message here does.

## Planned `[ ]`

### P1 · Peer discovery
Apple's `MultipeerConnectivity` framework (`MCNearbyServiceAdvertiser` + `MCNearbyServiceBrowser`). Picks
Bluetooth, peer-to-peer Wi-Fi, or infrastructure Wi-Fi automatically — whichever the OS judges best.
- Service type: `recense-p2p` (lowercase ASCII, digits, hyphens; 1–15 characters — the limit Apple's docs state).
- Discovery timeout: $T_{discover} = 10\text{s}$ before giving up and surfacing "no peer found" to the UI.
- `NSLocalNetworkUsageDescription` and `NSBonjourServices` (`_recense-p2p._tcp`, `_recense-p2p._udp`) in Info.plist
  (iOS 14+ local-network privacy prompt).
- Only a peer in FEAT-09's `peers.json` is auto-accepted; an unpaired peer surfaces the owner's own choice (so a
  stranger nearby can never join silently — FEAT-09 P1's invariant, enforced here at the one place invitations arrive).

### P2 · Session and transfer
`MCSession` for the connected pair.
- Small messages (pairing, carry ops) go via `session.send(_:toPeers:with:.reliable)`, each wrapped
  `{type: String, payload: Data}` so one wire format serves every caller.
- Files (carry's pieces, Share's incoming file) go via `sendResource(at:withName:toPeer:)`, streamed, not loaded
  fully into memory — matters for large files.
- Progress callback surfaced to the caller (Share's UI, carry's "Devices" screen, the messenger's).
- Transfer timeout: $T_{transfer} = 60\text{s}$ of no progress before the session is torn down and the caller is
  told it failed.

### P3 · One shared module, three callers
`shared/p2ptransport.swift` — plain Swift file, same pattern as `shared/notesync.swift` and
`shared/mediadownload.swift` (not a SwiftPM package; symlinked into `strip/Sources/recense/` on the Mac, joins the
iOS app automatically as a `shared/` file, per that folder's existing convention).
- Public surface: `advertise(as: MCPeerID)`, `browse()`, `send(_: Codable, type: String, to: MCPeerID)`,
  `send(fileAt: URL, named: String, to: MCPeerID)`, `onMessage: (String, Data, MCPeerID) -> Void`,
  `onReceive: (URL, MCPeerID) -> Void`, `onPeerFound/onPeerLost: (MCPeerID) -> Void`.
- FEAT-03 wires `onReceive` to the Share landing folder (P2 of FEAT-03).
- FEAT-09 wires `onMessage` to carry's pairing exchange and op-log settling (`type: "pair"`, `type: "carryop"`).
- The messenger spec (when written) wires `onReceive` to its own inbox.

## Invariants
- A transfer between two real devices completes with Wi-Fi off and Bluetooth on, airplane mode on (zero internet,
  zero cellular) — the literal proof this is offline-first, not "offline unless something else is reachable."
- `shared/p2ptransport.swift` has exactly one definition of peer discovery; grep for a second
  `MCNearbyServiceAdvertiser` anywhere else in the repo should return only this file.
- Only a device in FEAT-09's `peers.json` is auto-accepted; everyone else needs the owner's own tap.

## Planned code layout
- `shared/p2ptransport.swift` — the module (P1–P3).
- No unit test file: `MCSession` needs two real radios: per `~/.claude/CLAUDE.md` rule 2, the real-path check is
  Done checks below, not a simulator test.

## Done checks
- `zsh strip/build.sh` compiles with the new file linked in; `strip/recense selftest` passes.
- iOS compile (`.claude/CLAUDE.md` Checks table, `shared/` row): GalleryFiles + RecenseGuest.
- Real-device check (owner, iPhone Mirroring + iPad or two owned devices): Wi-Fi off, Bluetooth on, airplane mode
  on; send a small file from one device, confirm it lands on the other within $T_{transfer}$; pair once (FEAT-09
  P1), confirm the six-digit code matches on both screens.

## Offline-first gate
- Outside services touched: **none.** Bluetooth and peer-to-peer Wi-Fi are on-device radios, not a network
  service — no Apple account, no internet, no Cloudflare. This is the transport that makes FEAT-03's Bluetooth
  input, FEAT-09's carry, and the future messenger genuinely work with zero connectivity.
