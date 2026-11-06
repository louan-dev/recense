# Recense Editor (`editor/`)

Offline-first Markdown editor core built on CodeMirror 6 (MIT) for the Mac strip (`WKWebView`), the iOS app (`WKWebView`), and standalone web use.

## Features (M1–M3)

- **Self-contained offline build:** `npm run build` bundles all JavaScript and CSS into one file at `editor/dist/editor.html` with zero runtime network requests.
- **Draftpad byte-for-byte format:** preserves `\n\n<!-- page -->\n\n` page separators and opening full-style date lines (`Friday, November 6, 2026`) without rewriting the underlying file. Renders each `<!-- page -->` line as a thin divider.
- **Search & Replace:** visible **Search** button in the toolbar and `⌘F` (`Mod-f`) both open find and replace.
- **Outline & Folding:** lists Markdown headings (`#`–`######`) and legal section headings (`§ `) by page. Clicking a heading or page jumps there; headings fold in both the gutter and the outline panel without crossing page markers.
- **Newest first (view-only):** the **Newest first** toggle in the Outline header orders pages by their opening date line with the newest at the top, without reordering the underlying file.
- **Legal numbering:**
  - `Enter` continues a numbered item in the same style (`1.`, `1.1`, `(a)`, `(i)`).
  - `Tab` demotes and `Shift-Tab` promotes through `1.` → `1.1` → `(a)` → `(i)`.
  - Items automatically renumber after a move (`Alt-ArrowUp` / `Alt-ArrowDown`) or deletion.
  - Lines starting with `§ ` are styled and indexed as section headings and start a fresh numbering scope.
- **Calm reading & writing:** 18 px default font size in a centered 66-character column (`66ch`), with calm dark (near-black glass, one calm blue, cyan accent) and light themes.

## Build & Test

```sh
cd editor
npm test
npm run build
```

Open `editor/dist/editor.html` directly in Safari or load it inside `WKWebView`.
