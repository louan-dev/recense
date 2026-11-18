# SEC-03 · Our own password manager: KDBX 4 vault, carried like any file

From: owner 2026-11-18 (PLAN-1118 §5h, §12e) · Status: `[ ]` written (design only; nothing is built until the threat model below is reviewed)
Guards: SEC-02 (carry peer auth), FEAT-09 (carry), FEAT-22 (where it lives) ·
Rule: **never built without its own threat model and a non-author review** (owner, PLAN-1118 §5h).

## Verdict (owner's idea, weighed)
- **Affirm owning it. Object to writing our own cipher or vault format.** A home-made format is the one place where "build first" can lose every secret at once.
- **Format: KDBX 4** (the KeePass database, open and documented since 2003): a key derived with Argon2, the body sealed with AES-256 or ChaCha20, read by many free apps. That gives an exit by design (rule: every outside service replaceable; plain open formats, 10-year test).
- **What is ours:** the sync (the file is already encrypted, so carry can move it between devices with no trust in the transport), the Recense screens, and later an iOS AutoFill extension.
- **Usable on day one, no code:** KeePassXC on the Mac and KeePassium on iOS, both open source, reading the same carried file. (**checked** that both read KDBX 4: from memory, verify before relying.)
- **Assumed, untested:** KeePassXC imports a Bitwarden export. Check on a copy before moving anything. The owner has a `local.sill.bitwarden` Keychain item, so Bitwarden is the likely source today.

## 1 · Threat model (what we defend against, in order)
| Threat | Defence | Status |
|---|---|---|
| A thief with the unlocked laptop or phone | the vault stays sealed until the master key or biometrics release it; auto-lock; clipboard cleared after 20 s | design |
| A thief with the file only (a stolen backup, the carry folder, R2) | KDBX 4 with Argon2id: the file alone gives nothing; parameters fixed so a guess costs about one second per try on a phone (**assumed**: tune on the real devices) | design |
| A neighbour on the radio link | the file is ciphertext already; carry's own peer auth (SEC-02) protects the channel on top | built (SEC-02) |
| A compromised sync server | there is none required: R2 and the hub hold ciphertext only | design |
| Our own bug | **we do not implement the cipher or the container.** We link a maintained, audited KDBX reader and writer, or use the apps above, so a Recense bug cannot weaken the format | rule |
| Lost master key | no recovery by design; a printed recovery sheet kept by the owner is the only way back | open question 1 |
| Two devices edit at once | the merge unit is one entry (uuid) with its modified time; the loser is kept in the entry's History, never dropped (KDBX has History for this) | design |

## 2 · Rules
1. The vault is **one file** (`keep/vault.kdbx`, a home that carry moves; never synced by the hub in plaintext). It is **excluded from text merge** (it is binary): a conflict keeps both files as siblings (the carry rule for non-text), then an entry-level merge runs inside a trusted reader, never by byte merge.
2. **Keys stay on the device:** the master key is never written to disk or Cloudflare. A key file may sit in the Keychain, guarded by biometrics.
3. **No outside service at the moment of use.** Reading, filling and generating run on the device. Sync is catch-up only.
4. **Visible controls:** Lock, Copy, Show, Generate each have a button; gestures only speed them up.
5. **Never logs a secret.** The debug channel carries counts and ids only (`vault.open`, `vault.unlock failed`, `vault.sync`), never an entry title or a value.
6. **Exit:** a `Export…` action writes the same KDBX file to a chosen folder; because the format is open, leaving needs no migration code.

## 3 · Planned `[ ]` (in this order; each needs the threat model reviewed first)
- **P0 · No code: use KeePassXC + KeePassium** on a copy of the vault carried through Recense. Check: the same entry opens on Mac and iPhone; change on each, carry, both converge by the History rule. (Needs the owner; no code.)
- **P1 · Import check.** Bitwarden export → KeePassXC on a throwaway vault; count entries both sides. Check: a written count and a sample of 5 entries compared by hand.
- **P2 · Carry the file.** Add `keep/vault.kdbx` to carry as a non-text key. Check (`carrysync` test): a changed vault on two devices keeps both siblings, nothing lost.
- **P3 · The Recense screens** over a vetted KDBX library. **Open question 2:** which library (build vs adopt), decided after P0.
- **P4 · iOS AutoFill extension.** Later; a separate review.

## 4 · Open questions for the owner
1. Recovery: a printed recovery sheet, or no recovery at all? (Recommended: a printed sheet kept off the devices.)
2. P3: adopt a maintained KDBX library (recommended, smaller attack surface) or write a reader ourselves (not recommended)?
3. Move off Bitwarden at all, or keep it and use SEC-03 only for new items? (Recommended: P1 first; decide on the evidence.)

## 5 · Embodiments, debug channel, device checks
- **Home:** `shared/vault/` (planned; empty until P3). **Embodiments:** Mac `[ ]` · iPhone `[ ]` · iPad `[ ]` · web `n/a` (never in a browser).
- **Events:** `vault.open` · `vault.lock` · `vault.sync` · `vault.conflict` · `vault.error` (`~/Recense/logs/vault.jsonl`). No secret, no title.
- **Device checks:** P0 steps on Mac and iPhone, Wi-Fi off during a carry-by-radio, screen-recorded.

## 6 · Outside services (offline-first gate)
None at the moment of use. Setup once: the chosen KDBX app or library (source, size, checksum recorded). Catch-up: carry; R2 and the hub hold ciphertext only; any company is optional with `rclone` as the exit.
