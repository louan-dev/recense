# Recense Editor (`editor/`)

Offline-first Markdown editor core built on CodeMirror 6 (MIT) for the Mac strip (`WKWebView`), the iOS app (`WKWebView`), and standalone web use.

## Features (M1)

- **Self-contained offline build:** `npm run build` bundles all JavaScript and CSS into one file at `editor/dist/editor.html` with zero runtime network requests.
- **Draftpad byte-for-byte format:** preserves `\n\n<!-- page -->\n\n` page separators and opening full-style date lines (`Friday, November 6, 2026`) without rewriting the underlying file. Renders each `<!-- page -->` line as a thin divider.
- **Calm reading & writing:** 18 px default font size in a centered 66-character column (`66ch`), with calm dark (near-black glass, one calm blue, cyan accent) and light themes.

## Build & Test

```sh
cd editor
npm test
npm run build
```

Open `editor/dist/editor.html` directly in Safari or load it inside `WKWebView`.
