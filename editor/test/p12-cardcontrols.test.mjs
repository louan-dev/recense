// W2 card controls: swipe left removes (Undo restores), swipe right pins (pinned stays first), "Show in wing…"
// opens by itself when nothing plays, state v2 (pins) and v1 files load unchanged, no wing titles or × on the Mac.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createDualWings } from '../src/wings.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function setup(extra = {}) {
  const messages = { wings: [], ui: [] };
  const timers = [];
  const globalObj = {
    webkit: { messageHandlers: {
      wings: { postMessage: m => messages.wings.push(m) },
      ui: { postMessage: m => messages.ui.push(m) }
    } },
    setTimeout: (fn, ms) => timers.push({ fn, ms }),
    clearTimeout: id => { if (timers[id - 1]) timers[id - 1].fn = () => {}; },
    ...extra
  };
  // Run every pending timer of this length (the Undo window is 5 s).
  const elapse = ms => timers.filter(t => t.ms === ms).forEach(t => { const f = t.fn; t.fn = () => {}; f(); });
  const wings = createDualWings(null, { globalObj, gestures: false, ...extra.options });
  return { wings, messages, elapse };
}

const slot = (wings, side, id) => (side === 'left' ? wings.leftEl : wings.rightEl)
  .querySelectorAll('.rc-wing-slot').find(s => s.getAttribute('data-widget') === id);
const ids = (wings, side) => (side === 'left' ? wings.leftEl : wings.rightEl)
  .querySelectorAll('.rc-wing-slot').map(s => s.getAttribute('data-widget'));

function swipe(el, dx) {
  el.dispatchEvent({ type: 'pointerdown', clientX: 200, clientY: 100, pointerId: 1, button: 0 });
  el.dispatchEvent({ type: 'pointermove', clientX: 200 + dx / 2, clientY: 100, pointerId: 1 });
  el.dispatchEvent({ type: 'pointermove', clientX: 200 + dx, clientY: 100, pointerId: 1 });
  el.dispatchEvent({ type: 'pointerup', clientX: 200 + dx, clientY: 100, pointerId: 1 });
}

test('swipe left removes the card; Undo in the toast puts it back in the same place', () => {
  const { wings, messages, elapse } = setup();
  assert.deepEqual(ids(wings, 'left'), ['recense', 'preview', 'quicktime']);
  swipe(slot(wings, 'left', 'preview'), -140);
  assert.deepEqual(ids(wings, 'left'), ['recense', 'quicktime']);
  assert.ok(messages.ui.some(m => m.haptic === 'edge'), 'a haptic as the swipe passes the threshold');
  const toast = wings.leftEl.querySelectorAll('.rc-wing-toast')[0];
  assert.equal(toast.hidden, false);
  assert.equal(toast.querySelectorAll('.rc-wing-toast-text')[0].textContent, 'Preview removed');
  toast.querySelectorAll('.rc-wing-toast-undo')[0].dispatchEvent({ type: 'click' });
  assert.deepEqual(ids(wings, 'left'), ['recense', 'preview', 'quicktime']);
  assert.equal(toast.hidden, true);
  // After 5 s the toast goes and Undo has nothing left to do.
  swipe(slot(wings, 'left', 'quicktime'), -140);
  elapse(5000);
  assert.equal(toast.hidden, true);
  assert.equal(wings.undoRemove(), false);
  assert.deepEqual(ids(wings, 'left'), ['recense', 'preview']);
  wings.destroy();
});

test('a short swipe does nothing; a vertical drag is left to scrolling', () => {
  const { wings } = setup();
  swipe(slot(wings, 'left', 'preview'), -40);
  swipe(slot(wings, 'left', 'preview'), 40);
  const s = slot(wings, 'left', 'preview');
  s.dispatchEvent({ type: 'pointerdown', clientX: 200, clientY: 100, pointerId: 1, button: 0 });
  s.dispatchEvent({ type: 'pointermove', clientX: 205, clientY: 220, pointerId: 1 });
  s.dispatchEvent({ type: 'pointerup', clientX: 205, clientY: 220, pointerId: 1 });
  assert.deepEqual(ids(wings, 'left'), ['recense', 'preview', 'quicktime']);
  assert.deepEqual(wings.getPinned().left, []);
  wings.destroy();
});

test('swipe right pins: the card goes first and stays first; swiping right again unpins', () => {
  const { wings } = setup();
  swipe(slot(wings, 'left', 'quicktime'), 140);
  assert.deepEqual(ids(wings, 'left'), ['quicktime', 'recense', 'preview']);
  assert.ok(slot(wings, 'left', 'quicktime').classList.contains('rc-wing-pinned'), 'the pin mark shows');
  // Nothing displaces it: adding, moving others up, or a host widget arriving keeps it on top.
  wings.addWidget('left', 'mail');
  wings.moveWidgetBy('left', 'recense', -1);
  wings.reorderWidget('left', 'mail', 0);
  assert.equal(ids(wings, 'left')[0], 'quicktime');
  // The state carries the pin (draftpad.wings.json) and a fresh page restores it.
  const saved = JSON.stringify(wings.getState());
  assert.equal(JSON.parse(saved).version, 2);
  const again = setup().wings;
  again.setState(saved);
  assert.equal(ids(again, 'left')[0], 'quicktime');
  assert.deepEqual(again.getPinned().left, ['quicktime']);
  swipe(slot(wings, 'left', 'quicktime'), 140);
  assert.ok(!slot(wings, 'left', 'quicktime').classList.contains('rc-wing-pinned'));
  assert.deepEqual(wings.getPinned().left, []);
  wings.destroy();
  again.destroy();
});

test('Mac: a two-finger horizontal trackpad swipe removes or pins the same way', () => {
  const { wings, elapse } = setup();
  const wheel = (el, dx) => { for (let i = 0; i < 4; i++) el.dispatchEvent({ type: 'wheel', deltaX: dx / 4, deltaY: 0 }); elapse(160); };
  wheel(slot(wings, 'right', 'calendar'), -160); // fingers right: deltaX < 0 → pin
  assert.deepEqual(wings.getPinned().right, ['calendar']);
  assert.deepEqual(ids(wings, 'right'), ['calendar', 'recense']);
  wheel(slot(wings, 'right', 'recense'), 160); // fingers left: deltaX > 0 → remove
  assert.deepEqual(ids(wings, 'right'), ['calendar']);
  slot(wings, 'right', 'calendar').dispatchEvent({ type: 'wheel', deltaX: 0, deltaY: 40 }); // a scroll is a scroll
  elapse(160);
  assert.deepEqual(ids(wings, 'right'), ['calendar']);
  wings.destroy();
});

test('every swipe has a visible control: ··· menu Pin, Unpin, Remove, Move up, Move down', () => {
  const { wings } = setup();
  const menu = (id, label) => {
    slot(wings, 'left', id).querySelectorAll('.rc-wing-more')[0].dispatchEvent({ type: 'click' });
    const item = slot(wings, 'left', id).querySelectorAll('.rc-wing-menu-item').find(n => n.textContent === label);
    assert.ok(item, `${label} is in ${id}'s menu`);
    item.dispatchEvent({ type: 'click' });
  };
  menu('preview', 'Move down');
  assert.deepEqual(ids(wings, 'left'), ['recense', 'quicktime', 'preview']);
  menu('preview', 'Move up');
  assert.deepEqual(ids(wings, 'left'), ['recense', 'preview', 'quicktime']);
  menu('quicktime', 'Pin');
  assert.deepEqual(ids(wings, 'left'), ['quicktime', 'recense', 'preview']);
  menu('quicktime', 'Unpin');
  assert.deepEqual(wings.getPinned().left, []);
  menu('preview', 'Remove');
  assert.ok(!ids(wings, 'left').includes('preview'));
  assert.equal(wings.undoRemove(), true);
  assert.ok(ids(wings, 'left').includes('preview'));
  // Move up is greyed out on the top card.
  slot(wings, 'left', ids(wings, 'left')[0]).querySelectorAll('.rc-wing-more')[0].dispatchEvent({ type: 'click' });
  const up = slot(wings, 'left', ids(wings, 'left')[0]).querySelectorAll('.rc-wing-menu-item').find(n => n.textContent === 'Move up');
  assert.equal(up.getAttribute('aria-disabled'), 'true');
  wings.destroy();
});

test('the Recense card: pin, remove, move, and back again from "Show in wing…"', () => {
  const { wings } = setup();
  wings.removeWidget('right', 'recense');
  assert.deepEqual(ids(wings, 'right'), ['calendar']);
  assert.ok(wings.catalogFor('right', 'rec').some(e => e.id === 'recense'));
  wings.openFind('right');
  const input = wings.rightEl.querySelectorAll('.rc-wing-find-input')[0];
  input.value = 'rec';
  input.dispatchEvent({ type: 'input' });
  input.dispatchEvent({ type: 'keydown', key: 'Enter' });
  assert.deepEqual(ids(wings, 'right'), ['calendar', 'recense']);
  assert.equal(wings.isFindOpen('right'), false, 'adding closes the field back to the pill');
  wings.moveWidget('recense', 'left'); // the left wing has it already: the right one just goes
  assert.deepEqual(ids(wings, 'right'), ['calendar']);
  assert.equal(ids(wings, 'left').filter(x => x === 'recense').length, 1);
  wings.destroy();
});

test('"Show in wing…": tap the pill for the field; typing filters; a tap adds; Esc and ✕ close it', () => {
  const { wings } = setup();
  const find = wings.leftEl.querySelectorAll('.rc-wing-find')[0];
  const pill = find.querySelectorAll('.rc-wing-find-pill')[0];
  const box = find.querySelectorAll('.rc-wing-find-box')[0];
  assert.equal(box.hidden, true);
  pill.dispatchEvent({ type: 'click' });
  assert.equal(pill.hidden, true);
  assert.equal(box.hidden, false);
  const names = () => find.querySelectorAll('.rc-wing-find-item').map(n => n.textContent);
  assert.deepEqual(names(), ['Agenda · from the right wing', 'Find My', 'Mail'], 'iPhone Mirroring waits for the Mac');
  const input = find.querySelectorAll('.rc-wing-find-input')[0];
  input.value = 'ma';
  input.dispatchEvent({ type: 'input' });
  assert.deepEqual(names(), ['Mail']);
  input.dispatchEvent({ type: 'keydown', key: 'Escape' });
  assert.equal(box.hidden, true);
  assert.equal(pill.hidden, false);
  assert.equal(input.value, '');
  pill.dispatchEvent({ type: 'keydown', key: 'Enter' });
  find.querySelectorAll('.rc-wing-find-item').find(n => n.textContent.startsWith('Agenda')).dispatchEvent({ type: 'click' });
  assert.deepEqual(ids(wings, 'left'), ['recense', 'preview', 'quicktime', 'calendar'], 'a widget moves over');
  assert.deepEqual(ids(wings, 'right'), ['recense']);
  pill.dispatchEvent({ type: 'click' });
  find.querySelectorAll('.rc-wing-find-close')[0].dispatchEvent({ type: 'click' });
  assert.equal(box.hidden, true);
  wings.destroy();
});

test('nothing playing: the wing opens with "Show in wing…" already open, focus in it; playing: the pill', () => {
  let focused = 0;
  const changes = [];
  const { wings } = setup({ options: { onFindChange: (side, open) => changes.push([side, open]) } });
  const input = wings.leftEl.querySelectorAll('.rc-wing-find-input')[0];
  input.focus = () => { focused += 1; };
  wings.openWing('left');
  assert.equal(wings.isFindOpen('left'), true);
  assert.equal(focused, 1, 'the cursor is in the field');
  assert.deepEqual(changes, [['left', true]], 'the host hears it (the Mac panel takes key focus)');
  wings.closeFind('left');
  assert.deepEqual(changes.at(-1), ['left', false], 'closing gives focus back');
  // Opening again while the field is still open asks for focus again.
  wings.openFind('left');
  wings.wingShown('left');
  assert.deepEqual(changes.slice(-2), [['left', true], ['left', true]]);
  wings.closeFind('left');
  wings.setRecenseLine('Le vendeur livrera.', 'The seller will deliver.');
  wings.wingShown('left');
  assert.equal(wings.isFindOpen('left'), false, 'something playing: the pill, nothing in the way');
  wings.destroy();
});

test('a v1 draftpad.wings.json loads unchanged (Recense still on top of both wings), and saves as v2', () => {
  const v1 = {
    version: 1,
    leftWidgets: ['calendar', 'preview'],
    rightWidgets: ['quicktime', 'mail'],
    previewData: { src: 'exhibit-a.pdf', caption: 'Exhibit A' },
    qtData: { src: '', title: '', playbackRate: 1.25, loopRange: [3, 9], currentTime: 0 },
    findMyItems: [],
    mailMessages: []
  };
  const { wings } = setup();
  wings.setState(JSON.stringify(v1));
  assert.deepEqual(ids(wings, 'left'), ['recense', 'calendar', 'preview']);
  assert.deepEqual(ids(wings, 'right'), ['recense', 'quicktime', 'mail']);
  const st = wings.getState();
  assert.equal(st.version, 2);
  assert.deepEqual(st.previewData, v1.previewData);
  assert.equal(st.qtData.playbackRate, 1.25);
  assert.deepEqual(st.qtData.loopRange, [3, 9]);
  assert.deepEqual(st.pinned, { left: [], right: [] });
  // v2 with Recense removed stays removed (no re-adding on load).
  const v2 = { ...st, rightWidgets: ['quicktime', 'mail'] };
  wings.setState(JSON.stringify(v2));
  assert.deepEqual(ids(wings, 'right'), ['quicktime', 'mail']);
  wings.destroy();
});

test('a card swipe stops at the card: the wing\'s own close swipe never sees it', () => {
  const { wings } = setup();
  let stopped = 0;
  const s = slot(wings, 'left', 'preview');
  s.dispatchEvent({ type: 'pointerdown', clientX: 200, clientY: 100, pointerId: 1, button: 0 });
  s.dispatchEvent({ type: 'pointermove', clientX: 150, clientY: 100, pointerId: 1, stopPropagation: () => { stopped += 1; } });
  assert.equal(stopped, 1);
  wings.destroy();
});

test('Mac wing panels: no title and no × (owner, W2); the grabber sits at the top; the panel takes key only for typing', () => {
  const page = fs.readFileSync(path.resolve(__dirname, '../src/wingpanel.js'), 'utf8');
  assert.ok(!page.includes("'Left Wing'") && !page.includes("'Right Wing'"), 'no visible title');
  assert.ok(page.includes("'aria-label': side === 'left' ? 'Left wing' : 'Right wing'"), 'VoiceOver keeps the name');
  assert.ok(!page.includes('rc-wingpanel-close') && !page.includes('rc-wingpanel-arrange'), 'no × and no Arrange');
  const css = fs.readFileSync(path.resolve(__dirname, '../src/styles.css'), 'utf8');
  const grab = css.slice(css.indexOf('.rc-wing-grabber {'), css.indexOf('}', css.indexOf('.rc-wing-grabber {')));
  assert.ok(grab.includes('top: 6px') && !grab.includes('top: 50%'), 'grabber at the top end');
  assert.ok(/prefers-reduced-motion[\s\S]*rc-wing-find-box[\s\S]*animation: none/.test(css), 'Reduce Motion: no dissolve');
  const swift = fs.readFileSync(path.resolve(__dirname, '../../strip/wingpanels.swift'), 'utf8');
  assert.ok(swift.includes('case "focus": typing.insert(s); takeKey(s)'));
  assert.ok(swift.includes('case "unfocus": typing.remove(s); giveKeyBack(s)'));
  assert.ok(swift.indexOf('setRecenseLine(') < swift.indexOf('w.host.send("setArranging(false)")'),
    'the line reaches the page before "just opened", so it knows whether anything plays');
});
