import fs from 'node:fs';
import path from 'node:path';
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
