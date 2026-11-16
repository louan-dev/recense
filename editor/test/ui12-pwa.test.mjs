// Derived from Spec: UI-12 (S1). After one online visit, the editor opens with the server gone, and text typed offline survives a reload.
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'dist', 'pwa');
const types = { html: 'text/html', js: 'text/javascript', svg: 'image/svg+xml', webmanifest: 'application/manifest+json' };
let playwright = null;
try { playwright = await import('playwright'); } catch { /* no browser here */ }

test('S1: offline after one visit; text persists across reload', { skip: !playwright || !fs.existsSync(dir) }, async () => {
  const server = http.createServer((req, res) => {
    const f = path.join(dir, req.url === '/' ? 'index.html' : req.url.split('?')[0]);
    if (!f.startsWith(dir) || !fs.existsSync(f)) { res.writeHead(404); return res.end(); }
    res.writeHead(200, { 'content-type': types[f.split('.').pop()] || 'text/plain' });
    res.end(fs.readFileSync(f));
  });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  const url = `http://127.0.0.1:${server.address().port}/`;
  const browser = await playwright.webkit.launch();
  try {
    const ctx = await browser.newContext({ serviceWorkers: 'allow' });
    const page = await ctx.newPage();
    await page.goto(url);
    await page.waitForFunction(() => window.recenseEditor);
    await page.evaluate(() => navigator.serviceWorker.ready);
    await page.evaluate(() => navigator.serviceWorker.controller || new Promise(r => navigator.serviceWorker.addEventListener('controllerchange', r)));
    await page.evaluate(() => window.recenseEditor.setText('offline hello'));
    await page.evaluate(() => window.webkit.messageHandlers.editor.postMessage('offline hello'));
    await page.waitForTimeout(300);
    await new Promise(r => server.close(r));          // the network is gone
    server.closeAllConnections?.();
    await page.reload();
    await page.waitForFunction(() => window.recenseEditor);
    await page.waitForFunction(() => window.recenseEditor.getText() === 'offline hello', null, { timeout: 5000 });
  } finally { await browser.close(); server.close(); }
});
