// Derived from Spec: FEAT-19 P4 · a recording embedded in a note (`![caption](file.m4a)`) plays in the note, with the
// Lock Screen's title and a scrubber that seeks, and keeps playing when its line scrolls far out of view.
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { parseEmbedLine, formatDroppedEmbed } from '../src/embeds.js';

const html = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'dist', 'editor.html');
let playwright = null;
try { playwright = await import('playwright'); } catch {
  try { playwright = createRequire(import.meta.url)('playwright'); } catch { /* no browser here */ }
}

// a silent mono 16-bit WAV of `secs` seconds
function wav(secs) {
  const rate = 8000, n = rate * secs, b = Buffer.alloc(44 + n * 2);
  b.write('RIFF', 0); b.writeUInt32LE(36 + n * 2, 4); b.write('WAVEfmt ', 8); b.writeUInt32LE(16, 16);
  b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22); b.writeUInt32LE(rate, 24); b.writeUInt32LE(rate * 2, 28);
  b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(n * 2, 40);
  return b;
}

test('FEAT-19 P4: recordings and videos embed; other files stay links', () => {
  assert.deepEqual(parseEmbedLine('![Interview](Recordings/a b.m4a)'), null, 'a space needs <…>, as for any embed');
  assert.deepEqual(parseEmbedLine('![Interview](<Recordings/a b.m4a>)'), { kind: 'audio', target: 'Recordings/a b.m4a', caption: 'Interview' });
  assert.equal(parseEmbedLine('![](x.MP3)').kind, 'audio');
  assert.equal(parseEmbedLine('![](clip.mov)').kind, 'video');
  assert.equal(parseEmbedLine('![](notes.txt)'), null);
  assert.equal(formatDroppedEmbed('/Users/x/Voice Memo.m4a'), '![Voice Memo](</Users/x/Voice Memo.m4a>)');
});

test('FEAT-19 P4: an embedded recording has Now Playing and a scrubber that seeks, and plays on when scrolled away',
  { skip: !playwright || !fs.existsSync(html) }, async () => {
    const server = http.createServer((req, res) => {
      if (req.url.startsWith('/song.wav')) {
        const b = wav(3);
        res.writeHead(200, { 'content-type': 'audio/wav', 'content-length': b.length, 'accept-ranges': 'bytes' });
        return res.end(b);
      }
      res.writeHead(200, { 'content-type': 'text/html' });
      res.end(fs.readFileSync(html));
    });
    await new Promise(r => server.listen(0, '127.0.0.1', r));
    const url = `http://127.0.0.1:${server.address().port}/`;
    const exe = process.env.CHROMIUM || (fs.existsSync('/opt/pw-browsers/chromium') ? '/opt/pw-browsers/chromium' : undefined);
    const browser = await playwright.chromium.launch(exe ? { executablePath: exe } : {});
    try {
      const page = await browser.newPage({ viewport: { width: 800, height: 600 } });
      await page.addInitScript(() => {
        const ms = navigator.mediaSession;
        window.__h = {};
        window.__pos = [];
        const set = ms.setActionHandler.bind(ms);
        ms.setActionHandler = (a, h) => { if (h) window.__h[a] = h; else delete window.__h[a]; try { set(a, h); } catch {} };
        const sp = ms.setPositionState.bind(ms);
        ms.setPositionState = s => { window.__pos.push(s || null); try { sp(s); } catch {} };
      });
      await page.goto(url);
      await page.waitForFunction(() => window.recenseEditor);
      const filler = Array.from({ length: 400 }, (_, i) => 'line ' + i).join('\n');
      await page.evaluate(t => window.recenseEditor.setText(t), '![Interview](song.wav)\n' + filler);
      await page.waitForSelector('.cm-embed-audio audio', { state: 'attached' });
      assert.equal(await page.textContent('.cm-embed-audio .cm-embed-caption'), 'Interview');
      await page.$eval('.cm-embed-audio audio', a => a.play());
      await page.waitForFunction(() => navigator.mediaSession.metadata && navigator.mediaSession.metadata.title === 'Interview');
      await page.waitForFunction(() => window.__pos.some(s => s && Math.abs(s.duration - 3) < 0.1 && s.playbackRate > 0));
      assert.deepEqual(await page.evaluate(() => Object.keys(window.__h).sort()), ['pause', 'play', 'seekto'], 'no ±10 s, no ⏮/⏭ without a queue');
      await page.evaluate(() => window.__h.pause({ action: 'pause' }));
      await page.evaluate(() => window.__h.seekto({ action: 'seekto', seekTime: 2 }));
      assert.ok(Math.abs(await page.$eval('audio', a => a.currentTime) - 2) < 0.1, 'seekto moved the element');
      await page.waitForFunction(() => { const s = window.__pos[window.__pos.length - 1]; return s && Math.abs(s.position - 2) < 0.1; });

      // scrolled far away while it plays: CodeMirror drops the line's widget, the recording plays on
      await page.evaluate(() => { const a = document.querySelector('audio'); a.currentTime = 0; a.loop = true; return a.play(); });
      await page.focus('.cm-content');
      await page.keyboard.press('Control+End'); // the cursor leaves the line (CodeMirror keeps the cursor's line drawn)
      await page.evaluate(() => { const s = document.querySelector('.cm-scroller'); s.scrollTop = s.scrollHeight; });
      await page.waitForFunction(() => !document.querySelector('.cm-embed-audio'));
      await page.waitForTimeout(300);
      assert.equal(await page.evaluate(() => { const a = document.querySelector('audio'); return !!a && !a.paused; }), true, 'still playing');
      assert.equal(await page.evaluate(() => navigator.mediaSession.metadata?.title), 'Interview');
      // back in view: the same element, still playing
      await page.keyboard.press('Control+Home');
      await page.evaluate(() => { document.querySelector('.cm-scroller').scrollTop = 0; });
      await page.waitForSelector('.cm-embed-audio audio', { state: 'attached' });
      assert.equal(await page.evaluate(() => document.querySelectorAll('audio').length), 1, 'one element, not a second player');
      assert.equal(await page.$eval('.cm-embed-audio audio', a => !a.paused), true);

      // the line deleted while paused: the Lock Screen is given back
      await page.$eval('audio', a => a.pause());
      await page.evaluate(t => window.recenseEditor.setText(t), 'no recording');
      await page.waitForFunction(() => navigator.mediaSession.metadata === null && !window.__h.play);
    } finally { await browser.close(); server.close(); }
  });
