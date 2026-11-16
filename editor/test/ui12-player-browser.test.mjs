// Derived from Spec: UI-12 P6 (E2). The built dist/editor.html, in a browser with no native host, plays a recording,
// seeks, sets Media Session metadata and a position state; offline, a recording the device holds still plays and one it
// does not hold gets the plain line. Needs Chromium (CHROMIUM=/opt/pw-browsers/chromium) and ffmpeg; skips otherwise.
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const dist = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'dist', 'editor.html');
let playwright = null;
try { playwright = await import('playwright'); } catch {
  try { playwright = createRequire(import.meta.url)('playwright'); } catch { /* no browser here */ }
}
let tone = null;
try {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ui12-'));
  tone = path.join(dir, 'tone.wav');
  execFileSync('ffmpeg', ['-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=4', '-ac', '1', '-ar', '16000', tone]);
} catch { tone = null; }

// Regression guard: UI-12
test('UI-12 P6 E2: editor.html with no host plays, seeks and sets Media Session; offline it says so plainly', { skip: !playwright || !tone || !fs.existsSync(dist) }, async () => {
  const server = http.createServer((req, res) => {
    if (req.url === '/') { res.writeHead(200, { 'content-type': 'text/html' }); return res.end(fs.readFileSync(dist)); }
    if (req.url === '/tone.wav') { res.writeHead(200, { 'content-type': 'audio/wav' }); return res.end(fs.readFileSync(tone)); }
    res.writeHead(404); res.end();
  });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  const url = `http://127.0.0.1:${server.address().port}/`;
  const exe = process.env.CHROMIUM || (fs.existsSync('/opt/pw-browsers/chromium') ? '/opt/pw-browsers/chromium' : undefined);
  let browser;
  try {
    browser = await playwright.chromium.launch(exe && fs.statSync(exe).isFile() ? { executablePath: exe } : {});
  } catch {
    browser = await playwright.chromium.launch();
  }
  try {
    const ctx = await browser.newContext();
    await ctx.addInitScript(() => {
      window.__pos = [];
      const ms = navigator.mediaSession;
      if (ms && ms.setPositionState) {
        const orig = ms.setPositionState.bind(ms);
        ms.setPositionState = s => { if (s) window.__pos.push(s); return orig(s); };
      }
    });
    const page = await ctx.newPage();
    const errors = [];
    page.on('pageerror', e => errors.push(String(e)));
    await page.goto(url);
    await page.waitForFunction(() => window.recenseEditor && window.recenseEditor.loadAudio);
    assert.equal(await page.evaluate(() => Boolean(window.webkit?.messageHandlers?.audio)), false, 'no native host');

    // The page holds the recording (a blob, as a picked file is), then the network goes away.
    await page.evaluate(async () => {
      const b = await (await fetch('/tone.wav')).blob();
      window.__blob = URL.createObjectURL(b);
    });
    await ctx.setOffline(true);
    assert.equal(await page.evaluate(() => navigator.onLine), false);

    const where = await page.evaluate(() => window.recenseEditor.loadAudio(window.__blob, 'Test tone'));
    assert.equal(where, 'device');
    assert.equal(await page.evaluate(() => window.recenseEditor.audioState().backend), 'web');
    await page.locator('.rc-player-play').click(); // a real gesture, as on a phone
    await page.waitForFunction(() => window.recenseEditor.audioState().currentTime > 0.3, null, { timeout: 8000 });
    assert.equal(await page.locator('.rc-player-play').textContent(), 'Pause');

    const title = await page.evaluate(() => navigator.mediaSession.metadata && navigator.mediaSession.metadata.title);
    assert.equal(title, 'Test tone');
    assert.equal(await page.evaluate(() => navigator.mediaSession.playbackState), 'playing');

    await page.evaluate(() => window.recenseEditor.seekAudio(2.5));
    await page.waitForFunction(() => window.recenseEditor.audioState().currentTime >= 2.5, null, { timeout: 4000 });
    const pos = await page.evaluate(() => window.__pos.at(-1));
    assert.ok(pos && Math.abs(pos.duration - 4) < 0.2, `duration in position state: ${JSON.stringify(pos)}`);
    assert.ok(pos.position >= 2.4 && pos.playbackRate > 0, `position after seek: ${JSON.stringify(pos)}`);

    await page.evaluate(() => window.recenseEditor.setAudioRate(1.5));
    assert.equal(await page.evaluate(() => window.recenseEditor.audioState().rate), 1.5);
    await page.evaluate(() => window.recenseEditor.pauseAudio());
    await page.waitForFunction(() => navigator.mediaSession.playbackState === 'paused');

    // Offline, a recording this device does not hold: refused with the plain line, no spinner, nothing plays.
    const far = await page.evaluate(() => window.recenseEditor.loadAudio('https://gallery.example/f/far.m4a', 'Far'));
    assert.equal(far, 'unavailable');
    const status = page.locator('.rc-player-status');
    assert.equal(await status.isVisible(), true);
    assert.equal(await status.textContent(), "This recording isn't on this device. It needs a connection.");
    assert.equal(await page.evaluate(() => window.recenseEditor.playAudio()), false);
    assert.equal(await page.locator('[class*="spinner"], [aria-busy="true"]').count(), 0);
    assert.deepEqual(errors, []);
  } finally {
    await browser.close();
    server.close();
  }
});
