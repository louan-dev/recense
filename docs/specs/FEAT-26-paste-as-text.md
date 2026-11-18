# FEAT-26 · Paste as Text: any copied file becomes editable text

From: owner 2026-11-18 (reference: `clipboard-daemon-macos15.5.zip`, iCloud Drive) · Status: `[~]` P1 built (Mac), not yet tried in the installed app
Code: `shared/pastetext.swift` (logic + paste), `strip/app.swift` (menu item, ⌘⌥V hotkey id 2), reuses `shared/inkocr.swift`

## Goal
Copy a file in Finder, then choose **Paste as Text**.
The file's content arrives as editable text, not a file icon.
Works offline, English and other languages alike.

## What the reference package is (facts)
- 4 files: README, a 26-line report, a launchd plist, a 69-line Hammerspoon `init.lua`.
- The only working code is the Lua script. The plist points at a `main.swift` that is **not in the zip**.
- Flow: ⌘⌥V → read `public.file-url` → pick by extension → write text to the clipboard → wait 120 ms → send ⌘V.

## Strengths worth keeping
1. **One trigger, type dispatch.** One action; the file type decides the output. Simple to learn.
2. **Text/code → fenced block.** Reads the file, wraps it in ``` with the extension as language.
3. **PDF → its text.** Pastes the words, not the document.
4. **Fallback is a link.** Nothing fails silently; worst case you get `[name](file://…)`.
5. **Size guard.** Skips raw text over 50 KB so the target app doesn't freeze.
6. **Paste injection.** Sets the clipboard, then sends ⌘V, so it works in any app.

## Weaknesses to drop (evidence: `init.lua`)
- **Data loss:** `.zip` branch runs `unzip … && rm` on the source. Deleting the user's file is never acceptable here (§ nothing lost). **Dropped.**
- **Clipboard clobbered:** the original clipboard is overwritten and never restored.
- **Shell injection:** paths go into `popen`/`os.execute` inside quotes; a filename with `"` breaks out.
- **Only `%20` decoded:** other percent-escapes (accents, Vietnamese diacritics) stay broken. Fails our bilingual rule.
- **Images:** only a `file://` link; the report promises OCR, the code has none.
- **Outside dependencies:** Hammerspoon (third party) and `pdftotext` (Poppler via Homebrew).
- **Shortcut-only:** no menu or voice route. Breaks our "no action depends on a shortcut alone".

## Verified against the codebase: what synergizes
Each line: piece of the reference → what Recense already has (file:line) → verdict.

- **Paste injection (CGEvent ⌘V)** → `strip/app.swift:4740` `switchSpace` already posts key events with `CGEvent(... ).post(tap: .cghidEventTap)`; Accessibility is already granted to Recense.app for the scroll tap (`strip/app.swift:456`). → **Retrofit:** same 6-line pattern, key 9 (V) + `.maskCommand`. No new permission.
- **Clipboard write** → `strip/app.swift:3060` `copySecret` already uses `changeCount` to act only if the clipboard is unchanged. → **Retrofit:** same trick to restore the user's original clipboard after the paste.
- **Image → text** → `shared/inkocr.swift:29` `InkOCR.recognize(_ CGImage)` runs Apple Vision `VNRecognizeTextRequest`, on-device. → **Retrofit:** images get real OCR, not a link. Offline, multilingual (Vision's languages).
- **PDF → text** → none in Recense yet. → **Replace `pdftotext` with Apple PDFKit** (`PDFDocument(url:).string`), built into macOS. Scanned PDFs with no text layer: render each page to `CGImage`, then `InkOCR.recognize`. No Homebrew dependency.
- **Text/code → fenced block** → nothing to reuse; ~15 lines. → **Build.**
- **Hotkey** → Recense already has a global event tap and menus in `strip/app.swift`. → **Retrofit:** a menu item first, the hotkey second.
- **Voice route** → `shared/voiceappend.swift` handles spoken commands for notes. → **Assumed fit:** add "Paste as text" as a voice command; untested.
- **Hammerspoon / launchd plist** → Recense.app is already a resident Mac app. → **Not needed.** No second daemon.
- **Zip extract** → no synergy, and destructive. → **Not built.** At most: list the archive's file names (read-only).

## Design (Mac, P1)
1. Trigger: menu **Recense → Paste as Text**, the hotkey ⌘⌥V, or voice "paste as text".
2. Read `NSPasteboard.general` URLs (`readObjects(forClasses: [NSURL.self])`); proper URL decoding, no string hacks.
3. Dispatch by UTType (`UTType(filenameExtension:)` conforms-to), not a hard-coded extension list:
   - `.text` / `.sourceCode` ≤ 50 KB → fenced block. Larger → first 50 KB + "(truncated)" line.
   - `.pdf` → PDFKit text; empty → OCR pages (cap: 20 pages).
   - `.image` → `InkOCR.recognize`; empty → Markdown image link.
   - `.archive` → list of entries (read-only, `/usr/bin/zipinfo -1` via `Process` with argument array).
   - else → `[name](file://…)` link.
   - Several files copied → one section per file, joined.
4. Save the clipboard's items, write the text, post ⌘V, then restore the original after 0.5 s if `changeCount` is unchanged.
5. No file copied → plain ⌘V passthrough (same as reference).

## Later (P2, not this slice)
- iPhone/iPad: no global paste injection exists on iOS. Nearest version: a Share-sheet action
  "Copy as Text" (FEAT-03 share destination) that puts the text on `UIPasteboard`.

## Offline-first gate
- Outside services: **none.** Vision, PDFKit, UTType, CGEvent, zipinfo are all built into macOS.

## Done checks
1. Copy a `.md`, a text-layer PDF, a scanned PDF, a PNG with Vietnamese text, a `.zip` → each pastes the expected text into TextEdit; the `.zip` still exists afterwards.
2. After paste, the clipboard again holds the original file reference.
3. Filename with `"`, spaces and accents (`Bản án "mẫu".pdf`) works.
4. Menu item reachable with no hotkey.

## Risks
- Synthetic ⌘V fails in apps that block synthetic input (some secure fields) → text stays on clipboard; acceptable.
- Restore race: user copies something within 0.5 s → `changeCount` guard skips the restore (no overwrite).
- Vision accuracy on mixed scripts: assumed good for Latin + Vietnamese; untested here.
