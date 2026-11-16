# BUG-20 · Guests can't add media to a share link: the Main-only "hide the old Upload pill" CSS swallowed the guest's "Add" button too

From: T-0130 (owner, 2026-11-16: "being able to upload media to share link, somehow that disappeared") ·
Guards: notes 20261029 item 16 (Shared Albums: "people with a link post files") ·
Status: `[x]`

## What the owner sees
- Open a plain upload share link (`/s/<id>`) as a guest whose link allows posting (`perms.upload: true`, the
  default for a link not made from the archive): no "Add" button anywhere, so there is no way to post a file,
  though the server has always allowed it.

## Red (what the code shows)
- `src/client/gallery.js` `guestPost()` is true for exactly the right guests, and its only visible effect is:
  `up.textContent = "Add"; up.hidden = false;` — the `hidden` attribute is correctly removed.
- But `src/client/gallery.css` carries, since `ed646e1` (2026-10-24..27, before Shared Albums existed):
  `#up{display:none!important}` — added to retire the owner's old "Upload" pill on Main once `#addtile` (the
  blue "+" tile) replaced it ("the old Upload pill goes away … kept in the DOM so your upload code still
  works"). The rule has no scope: it hides `#up` for *everyone*, `!important` and all.
- `b552647`/`6dca0ef`/`380f2b7` (Shared Albums, notes item 16) later reused the very same `#up` element as the
  guest's visible "Add" pill, removing its `hidden` attribute — which the CSS override ignores. The feature was
  wired correctly end to end (reserve → part → complete, perms, Activity) and every server-side test for it
  passes; only the pixel the guest would click never appeared. No UI test exercised a guest's own `#up` (the
  only existing `#up` assertion, `ui.test.mjs` "public link: visitors see Download only", checks a **folder**
  link, which never takes uploads, so it never caught this).

## Green (the fix)
- `src/client/gallery.js`: when `guestPost()` shows the pill, also tag it `up.classList.add("guestup")`.
- `src/client/gallery.css`: narrow the override to `#up:not(.guestup){display:none!important}` — Main's retired
  pill stays hidden exactly as before; the guest's reused pill is no longer caught by it.

## Invariant (tested: `library/test/ui.test.mjs` "T-0130: a guest can add a file to a plain upload link (item 16)")
- A guest on an upload link with `perms.upload: true` sees `#up` visible with the text "Add", and a file chosen
  through it lands in the link (`links/<id>/001` in `PUBLIC`).
- Unchanged: the owner on Main never sees `#up` (it has no `.guestup` class there); a folder link, which never
  takes uploads, still hides `#up` for its guest() case too (`guestPost()` is false off `G.perms.upload`, unset
  by `linkPerms` for folder links).

## Check
- `grep -n 'guestup' library/src/client/gallery.js library/src/client/gallery.css` prints the class add and the
  narrowed selector.
- `npm test` in `library/` (ui.test.mjs's new T-0130 case, plus the existing routes.test.mjs coverage for
  `guestUploadApi`/`linkPerms`, which was already green — this bug was purely a CSS/DOM mismatch, never a
  server-side permission bug).
