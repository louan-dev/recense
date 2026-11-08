// W3 resizable cards: heights snap to 1-4 rows (S/M/L/XL) from the bottom grabber or the ··· menu; the Agenda shows as
// many events as its rows hold; sizes persist (state v3) and a v2 file loads unchanged with today's heights.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createDualWings } from '../src/wings.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function setup() {
  const messages = { wings: [], ui: [] };
  const globalObj = {
    webkit: { messageHandlers: {
      wings: { postMessage: m => messages.wings.push(m) },
      ui: { postMessage: m => messages.ui.push(m) }
    } },
    setTimeout: () => 0,
    clearTimeout: () => {}
  };
  return { wings: createDualWings(null, { globalObj, gestures: false }), messages };
}
const slot = (wings, side, id) => (side === 'left' ? wings.leftEl : wings.rightEl)
  .querySelectorAll('.rc-wing-slot').find(s => s.getAttribute('data-widget') === id);
const events = n => Array.from({ length: n }, (_, i) => ({
  id: `e${i}`, title: `Hearing ${i + 1}`, start: new Date(2026, 10, 20 + i, 9).toISOString(), lineNumber: i + 1, pageIndex: 0
}));

test('defaults keep today\'s look: Preview and Player L, Agenda M, the rest S', () => {
  const { wings } = setup();
  assert.equal(slot(wings, 'left', 'preview').getAttribute('data-rows'), '3');
  assert.equal(slot(wings, 'left', 'quicktime').getAttribute('data-rows'), '3');
  assert.equal(slot(wings, 'right', 'calendar').getAttribute('data-rows'), '2');
  assert.equal(slot(wings, 'right', 'recense').getAttribute('data-rows'), '1');
  wings.destroy();
});

test('the bottom grabber snaps to whole rows (1-4), a haptic per row, saved on release', () => {
  const { wings, messages } = setup();
  const s = slot(wings, 'right', 'recense');
  const grab = s.querySelectorAll('.rc-wing-resize')[0];
  assert.equal(grab.getAttribute('role'), 'slider');
  grab.dispatchEvent({ type: 'pointerdown', clientY: 100, pointerId: 1 });
  grab.dispatchEvent({ type: 'pointermove', clientY: 140, pointerId: 1 }); // under half a row: stays 1
  assert.equal(s.getAttribute('data-rows'), '1');
  grab.dispatchEvent({ type: 'pointermove', clientY: 100 + 122 + 20, pointerId: 1 }); // one row down
  assert.equal(s.getAttribute('data-rows'), '2');
  grab.dispatchEvent({ type: 'pointermove', clientY: 100 + 122 * 9, pointerId: 1 }); // far past: XL, no further
  assert.equal(s.getAttribute('data-rows'), '4');
  assert.equal(messages.ui.filter(m => m.haptic === 'snap').length, 2, 'one haptic per row crossed');
  assert.equal(wings.getSize('right', 'recense'), 1, 'not saved until release');
  grab.dispatchEvent({ type: 'pointerup', clientY: 100 + 122 * 9, pointerId: 1 });
  assert.equal(wings.getSize('right', 'recense'), 4);
  assert.equal(grab.getAttribute('aria-valuenow'), '4');
  // Up past the top: S, never 0.
  grab.dispatchEvent({ type: 'pointerdown', clientY: 500, pointerId: 1 });
  grab.dispatchEvent({ type: 'pointermove', clientY: -900, pointerId: 1 });
  grab.dispatchEvent({ type: 'pointerup', clientY: -900, pointerId: 1 });
  assert.equal(wings.getSize('right', 'recense'), 1);
  // Keyboard: ↓ grows, ↑ shrinks.
  grab.dispatchEvent({ type: 'keydown', key: 'ArrowDown' });
  assert.equal(wings.getSize('right', 'recense'), 2);
  grab.dispatchEvent({ type: 'keydown', key: 'ArrowUp' });
  assert.equal(wings.getSize('right', 'recense'), 1);
  wings.destroy();
});

test('"Size: S / M / L / XL" in the ··· menu, the current one checked', () => {
  const { wings } = setup();
  const s = slot(wings, 'right', 'calendar');
  s.querySelectorAll('.rc-wing-more')[0].dispatchEvent({ type: 'click' });
  const opts = s.querySelectorAll('.rc-wing-menu-size-opt');
  assert.deepEqual(opts.map(o => o.textContent), ['S', 'M', 'L', 'XL']);
  assert.deepEqual(opts.map(o => o.getAttribute('aria-checked')), ['false', 'true', 'false', 'false']);
  opts[3].dispatchEvent({ type: 'click' });
  assert.equal(wings.getSize('right', 'calendar'), 4);
  assert.equal(slot(wings, 'right', 'calendar').getAttribute('data-rows'), '4');
  wings.destroy();
});

test('more rows show more: the Agenda lists 1 / 2 / 3 / 4 events (one per row) and counts the rest', () => {
  const { wings } = setup();
  wings.setCalendarEvents(events(9));
  const shown = () => slot(wings, 'right', 'calendar').querySelectorAll('.rc-cal-item').length;
  const more = () => slot(wings, 'right', 'calendar').querySelectorAll('.rc-cal-more')[0]?.textContent || '';
  assert.equal(shown(), 2, 'M (the default)');
  assert.ok(more().startsWith('7 more'));
  for (const [rows, n] of [[1, 1], [3, 3], [4, 4]]) {
    wings.setSize('right', 'calendar', rows);
    assert.equal(shown(), n, `${rows} rows`);
  }
  wings.setCalendarEvents(events(2));
  assert.equal(shown(), 2);
  assert.equal(more(), '', 'nothing to count when all fit');
  wings.destroy();
});

test('sizes persist (state v3), travel with a card to the other wing, and swap with the wings', () => {
  const { wings } = setup();
  wings.setSize('left', 'preview', 2);
  wings.setSize('right', 'recense', 4);
  const st = wings.getState();
  assert.equal(st.version, 3);
  assert.deepEqual(st.sizes, { left: { preview: 2 }, right: { recense: 4 } });
  const again = setup().wings;
  again.setState(JSON.stringify(st));
  assert.equal(again.getSize('left', 'preview'), 2);
  assert.equal(slot(again, 'right', 'recense').getAttribute('data-rows'), '4');
  again.moveWidget('preview', 'right');
  assert.equal(again.getSize('right', 'preview'), 2, 'a card keeps its size on the other side');
  again.swapWings();
  assert.equal(again.getSize('left', 'recense'), 4);
  // Junk in the file is ignored, never a broken card.
  again.setState(JSON.stringify({ ...st, sizes: { left: { preview: 9, mail: 'L' }, right: null } }));
  assert.equal(again.getSize('left', 'preview'), 3);
  wings.destroy();
  again.destroy();
});

test('a v2 draftpad.wings.json loads unchanged, with today\'s heights', () => {
  const v2 = {
    version: 2,
    leftWidgets: ['quicktime', 'recense', 'preview'],
    rightWidgets: ['calendar', 'mail'],
    pinned: { left: ['quicktime'], right: [] },
    previewData: { src: 'exhibit-b.pdf', caption: 'Exhibit B' },
    qtData: { src: '', title: '', playbackRate: 1, loopRange: [0, 0], currentTime: 0 },
    findMyItems: [],
    mailMessages: []
  };
  const { wings } = setup();
  wings.setState(JSON.stringify(v2));
  assert.deepEqual(wings.getWingLayout().left, ['quicktime', 'recense', 'preview']);
  assert.deepEqual(wings.getWingLayout().right, ['calendar', 'mail'], 'v2 without Recense on the right stays without');
  assert.deepEqual(wings.getPinned().left, ['quicktime']);
  assert.equal(wings.getState().previewData.caption, 'Exhibit B');
  assert.equal(wings.getSize('left', 'quicktime'), 3);
  assert.equal(wings.getSize('right', 'calendar'), 2);
  assert.equal(wings.getSize('right', 'mail'), 1);
  assert.deepEqual(wings.getState().sizes, { left: {}, right: {} });
  wings.destroy();
});

test('rows are one unit in the CSS; the text never scales; overflow scrolls inside the card', () => {
  const css = fs.readFileSync(path.resolve(__dirname, '../src/styles.css'), 'utf8');
  assert.ok(css.includes('--rc-row: 112px'));
  for (const n of [1, 2, 3, 4]) assert.ok(css.includes(`.rc-wing-slot[data-rows='${n}']`), `rows ${n} defined`);
  const block = css.slice(css.indexOf('/* W3 rows'), css.indexOf('/* The bottom-edge grabber'));
  assert.ok(block.includes('overflow-y: auto'));
  assert.ok(!/font-size|zoom|scale\(/.test(block), 'sizes change height only, never the text');
});
