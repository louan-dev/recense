import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import * as esbuild from 'esbuild';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, '..');
const srcDir = path.join(rootDir, 'src');
const distDir = path.join(rootDir, 'dist');

const cssPath = path.join(srcDir, 'styles.css');
const entryPath = path.join(srcDir, 'index.js');
const outHtmlPath = path.join(distDir, 'editor.html');

const css = fs.readFileSync(cssPath, 'utf8');

const result = await esbuild.build({
  entryPoints: [entryPath],
  bundle: true,
  write: false,
  format: 'iife',
  platform: 'browser',
  target: ['es2022'],
  minify: false
});

const js = result.outputFiles[0].text.replace(/<\/script>/gi, '<\\/script>');

const html = `<!DOCTYPE html>
<html lang="en" data-theme="dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<title>Recense Editor</title>
<style>
${css}
</style>
</head>
<body>
<div id="app"></div>
<script>
${js}
</script>
</body>
</html>
`;

fs.mkdirSync(distDir, { recursive: true });
fs.writeFileSync(outHtmlPath, html, 'utf8');
console.log(`Built ${path.relative(rootDir, outHtmlPath)} (${Buffer.byteLength(html)} bytes)`);

// Derived from Spec: UI-12 (S1). The same editor as an installable web page: the page, a service worker that
// keeps it for offline use, a manifest, an icon, and the IndexedDB store that stands in for the app's host.
// Serve dist/pwa/ from any static host (or `python3 -m http.server -d dist/pwa`); nothing else is needed.
const pwaDir = path.join(distDir, 'pwa');
fs.mkdirSync(pwaDir, { recursive: true });
const store = await esbuild.build({ entryPoints: [path.join(srcDir, 'webstore.js')], bundle: true, write: false, format: 'iife', platform: 'browser', target: ['es2022'] });
const storeJs = store.outputFiles[0].text.replace(/<\/script>/gi, '<\\/script>');
const buildId = crypto.createHash('sha1').update(html).digest('hex').slice(0, 10);
const head = `<link rel="manifest" href="manifest.webmanifest">
<link rel="icon" href="icon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="icon.svg">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="theme-color" content="#1b1b1f">
<script>
${storeJs}
</script>`;
const reg = `<script>
if ('serviceWorker' in navigator && /^https?:$/.test(location.protocol)) {
  navigator.serviceWorker.register('sw.js').catch(function () { /* offline use needs it; editing still works */ });
}
</script>`;
const pwaHtml = html.replace('</head>', head + '\n</head>').replace('</body>', reg + '\n</body>');
fs.writeFileSync(path.join(pwaDir, 'index.html'), pwaHtml, 'utf8');
fs.writeFileSync(path.join(pwaDir, 'sw.js'), fs.readFileSync(path.join(srcDir, 'pwa', 'sw.js'), 'utf8').replace('__BUILD__', buildId), 'utf8');
for (const f of ['manifest.webmanifest', 'icon.svg']) fs.copyFileSync(path.join(srcDir, 'pwa', f), path.join(pwaDir, f));
console.log(`Built dist/pwa/ (${buildId})`);
