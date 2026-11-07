# Recense Editor (`editor/`)

Offline-first Markdown editor core built on CodeMirror 6 (MIT) for the Mac strip (`WKWebView`), the iOS app (`WKWebView`), and standalone web use.

## Features (M1–M6)

- **Self-contained offline build:** `npm run build` bundles all JavaScript and CSS into one file at `editor/dist/editor.html` with zero runtime network requests.
- **Draftpad byte-for-byte format:** preserves `\n\n<!-- page -->\n\n` page separators, line endings (`\n`, `\r\n`, lone `\r`), and opening full-style date lines (`Friday, November 6, 2026`) without rewriting the underlying file. Renders each `<!-- page -->` line as a thin divider.
- **Find:** the **Search** button or `⌘F` opens one field that finds as you type, with a match count. `Enter` = next, `Shift-Enter` = previous, `Esc` = close. Replace hides behind `⇄` (Replace / All).
- **Pages (M6, on by default):** one page fills the view; the rest of the file is hidden, never removed. Page 0 is the top of the file. Two-finger horizontal swipes (one page per swipe) and `⌘]` / `⌘[` page through; the cursor pulls the page along (search, outline jumps). **Pages** in the toolbar switches to one long scroll.
- **Links (M6):** URLs are underlined; `⌘`-click opens them (through the host's `link` handler, else `window.open`). List markers `-` `*` `+` show as `•`; the file keeps the marker.
- **Embeds (M6):** a line holding only `![caption](target.pdf | .png | .jpg | .gif | .webp | .heic | .svg)` shows the PDF or image under it. Inside the host, targets load through `recense-file://vault/<path>` or `recense-file://remote/<url>` (cached by the host, so offline after the first open).
- **Outline & Folding:** hidden by default; it slides over the text and closes when you pick an entry. Lists Markdown headings (`#`–`######`) and legal section headings (`§ `) by page. Clicking a heading or page jumps there; headings fold in both the gutter and the outline panel without crossing page markers.
- **Newest first (view-only):** the **Newest first** toggle in the Outline header orders pages by their opening date line with the newest at the top, without reordering the underlying file.
- **Legal numbering:**
  - `Enter` continues a numbered item in the same style (`1.`, `1.1`, `(a)`, `(i)` / `(I)`).
  - `Tab` demotes and `Shift-Tab` promotes through `1.` → `1.1` → `(a)` → `(i)`.
  - Renumbers **only** the contiguous list holding the cursor after `Enter`, `Tab`, `Shift-Tab`, line move (`Alt-ArrowUp` / `Alt-ArrowDown`), or a line deletion in that list — never on load, `setText`, typing elsewhere, or paste.
  - Leaves prose numbers, years (`1990.`), decimals (`1.5 hours`), and prose cross-references (`(c) of the statute`, `(v) supra / (x) infra`) untouched; preserves Roman numeral case and disambiguates `(i)` from the item before it.
  - Lines starting with `§ ` are styled and indexed as section headings and start a fresh numbering scope.
- **Deletions record ("Farewell", D32):** a transaction filter records every user deletion with its timestamp, character range, and surrounding text (`before`, `after`, `context`), exposed via `window.recenseEditor.getRemoved()`.
- **Calm reading & writing:** 18 px default font size in a centered 66-character column (`66ch`), with calm dark (near-black glass, one calm blue, cyan accent) and light themes.

## Native Shell Bridge (`window.recenseEditor`)

- `window.recenseEditor.setText(s)` — flushes any pending debounced edit first so the last 300 ms of typing is never dropped, replaces the editor document with `s` without entering undo history (`Transaction.addToHistory.of(false)`), preserves cursor selection and scroll position where possible, and does **not** echo a change message back to the host.
- `window.recenseEditor.getText()` — synchronously returns the full document string (used by `EditorHost.flush` before merging remote edits).
- `window.recenseEditor.getRemoved()` — returns the array of recorded user deletions (`{ text, from, to, time, before, after, context }`) for the "Farewell" episode (D32).
- `window.recenseEditor.focus()` — focuses the CodeMirror view.
- `window.recenseEditor.step(delta)` — one page deeper (`1`) or toward the top (`-1`); returns `'ok'` or `'bounce'`. Also `showPage(i)`, `currentPage()`, `pageCount()`, `setPageMode(on)`, `isPageMode()`, `setCursor(offset)`, `insertBlock(text)` (a new line under the cursor line, saved like typing).
- **Page → Native, besides `editor`:** `link` gets a URL to open; `ui` gets `'bounce'` when a swipe passes either end.
- `window.recenseEditor.setTheme('dark' | 'light')` — switches between dark and light themes.
- `window.recenseEditor.setFontSize(px)` — sets the editor font size in pixels (clamped to `12`–`36`, default `18`).
- **Page → Native notifications:** user edits are debounced to `300 ms` and posted as the full plain string via `window.webkit.messageHandlers.editor.postMessage(fullText)` when that handler is present.

## Build & Test

```sh
cd editor
npm test
npm run build
```

Open `editor/dist/editor.html` directly in Safari or load it inside `WKWebView`.
