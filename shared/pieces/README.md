# Pieces · one byte layer for sharing and for moving files between our devices

`shared/pieces/` is a Swift package (Foundation + CryptoKit only).
Recense Mac and Recense mobile will both use it.
Its browser twin is `library/src/client/pieces.js`.
Both must make the same bytes from `vectors/v1.json`.

Status: X1 (core only).
No app calls it yet.
Next:
- X2: the page a recipient opens, and the seed that stores pieces;
- X3: transfer between paired devices, on the listen lane's S7a pairing;
- X4: the Share action.

## What it does
- A file is cut into pieces:
  - 256 KiB each below 1 GiB;
  - 1 MiB each at or above it.
- Each piece is encrypted with AES-256-GCM.
- Each piece is named by the SHA-256 of its encrypted bytes.
  - Any seed or peer can check a piece and serve it, but cannot read it.
- A manifest lists the pieces.
  - It is encrypted too.
  - The item id is the SHA-256 of the encrypted manifest.
- A link looks like `https://<seed>/x/<item id>#<key>`.
  - The key is only after `#`.
  - Browsers never send that part to a server (RFC 3986 §3.5).

## Keys
- `itemKey = HMAC-SHA256(group secret, "recense.pieces.v1.item" ‖ SHA-256(file))`
  - The group secret is shared by our paired devices.
  - So the same file added on two devices becomes one item.
  - Outsiders can't test "do you have this file" without the secret.
- `manifestKey`, `pieceKey` = HKDF-SHA256(itemKey), with info `recense.pieces.v1.manifest` / `.piece`.
- Piece nonce = 4 zero bytes ‖ the piece index (UInt64, big-endian).
- Manifest nonce = 12 random bytes, stored in front of the sealed manifest.
  - The same file can carry a different name or time, so the manifest needs its own nonce.

## The one safety rule
- **The rule:** AES-GCM breaks if one key encrypts two different plaintexts under one nonce.
- **How it holds here:**
  - The key comes from the file's hash, so an edited file always gets a new key.
  - A device hands out a piece of its own file only through `servePiece`. That re-encrypts the piece and refuses (`fileChanged`) unless the result is exactly the piece the manifest names.
  - So the old key never encrypts a second plaintext.
- **Tests:** `testAnEditedFileGetsANewKey`, `testAChangedFileIsRefusedUnderItsOldKey`.

## What a shared link can never undo
- **A link is the key.** Anyone holding it can read the item.
- **Once someone has fetched a link, its key is out.**
  - It can't be taken back.
  - Nor can any copy they saved.
- **Deleting the pieces from the seeds stops only future fetches.**
- **The share sheet (X4) must say this** before anything leaves.

## Test
- Swift: `swift test` in this folder (Xcode's toolchain).
  - 8 tests: the vectors byte for byte, the manifest opened from the link, the key only after `#`, a flipped byte caught by the hash and by GCM, the key rule, resume after a drop, piece sizes.
- JS: `node test/pieces.test.mjs` in `library/` (part of `npm test`), on the same vectors.
- `vectors/v1.json` was made once by the JS twin.
  - Never regenerate it to make a failing side pass.
  - A change to the format is a new file (`v2.json`) and a new label (`recense.pieces.v2.`).
