# Offline

The owner's "Offline-first gate" in `~/.claude/CLAUDE.md` is binding and is not repeated here.
This file adds what is specific to Recense.

## Assume no connection
- Every feature assumes no Wi-Fi and no cellular, even when one is present.
- Work lands on the device first, always. Writing, capture, transcription, read-aloud and translation never wait.
- Edits made offline are kept with their history and merged when devices meet. Nothing is lost in a merge.
- When a connection appears: catch up fast, then let it go. The network is an optimization, never a dependency.

## Sharing without your own connection
A share follows this ladder, top first. Each step runs only if the one above failed.
1. **Device to device:** AirDrop, Bluetooth / Wi-Fi peer-to-peer, or a QR code that pairs two devices
   (`docs/specs/FEAT-02-p2p-transport.md`, `FEAT-03-share-destination.md`).
2. **The other person's connection:** the link or file travels to their device offline,
   and their device sends it on when it is online (store-and-forward).
3. **Our own relay:** a server we own (the Mac mini, a VPS, a reverse proxy).
4. **Last:** open this device's own connection, send, close it again.

Status: the ladder is the owner's direction (2026-11-05). Step 1 is specced.
Steps 2 to 4 are untested; each needs a spec and a spike before code.

## Outside services
- **Cloudflare (Worker, R2):** storage and caching only. Replaceable by one command to the Mac mini.
- **iCloud:** never required. Recense's sync is its own (`docs/specs/sync.md`).
- **Any company:** may power a nice-to-have Recense can lose; never a vital.
- **DEVONthink:** a nice-to-have. **Open:** whether it should index everything (WISHES, 2026-11-14).
- Each outside service is named, with when it is needed, in the spec that uses it.

## One-time downloads
Language packs, voices, models and dictionaries may be downloaded once for setup.
Each is stored on the device with its source, size and checksum.

## Amendments
- 2026-11-14 · created from the 2026-11-05 note; replaces the "Direction" section of `.claude/CLAUDE.md`.
