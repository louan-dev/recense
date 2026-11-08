// The Mac's native wing panels (strip/wingpanels.swift): what the shared page does for them.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { createDualWings } from '../src/wings.js';
import { wingSideFrom } from '../src/wingpanel.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function setup() {
  const messages = { wings: [], ui: [] };
  const fakeGlobal = {
    webkit: {
      messageHandlers: {
        wings: { postMessage: m => messages.wings.push(m) },
        ui: { postMessage: m => messages.ui.push(m) }
      }
    }
  };
  const listeners = {};
  const children = [];
  const container = {
    tagName: 'DIV',
    clientWidth: 800,
    children,
    childNodes: children,
    appendChild(c) { children.push(c); c.parentNode = container; return c; },
    removeChild(c) { children.splice(children.indexOf(c), 1); return c; },
    addEventListener(t, fn) { (listeners[t] = listeners[t] || []).push(fn); },
    removeEventListener(t, fn) { listeners[t] = (listeners[t] || []).filter(f => f !== fn); }
  };
  return { container, fakeGlobal, messages, listeners };
}

test('native wings: open, close and toggle go to the host; the in-page wings stay hidden', () => {
  const { container, fakeGlobal } = setup();
  const wings = createDualWings(container, { globalObj: fakeGlobal });
  const asked = [];
  wings.setNativeWings((op, side) => asked.push([op, side]));
  wings.openWing('left');
  wings.toggleWing('right');
  wings.closeWing('both');
  assert.deepEqual(asked, [['open', 'left'], ['toggle', 'right'], ['close', 'both']]);
  assert.equal(wings.leftEl.hidden, true);
  assert.equal(wings.rightEl.hidden, true);
  // Off again (iOS never turns it on): the wings open in the page as before.
  wings.setNativeWings(null);
  wings.openWing('left');
  assert.equal(wings.isWingOpen('left'), true);
  wings.destroy();
});

test('wing panel page: reveal shows one side; no Arrange; no fan motion; Recense card on both sides', () => {
  const { container, fakeGlobal } = setup();
  const wings = createDualWings(container, { globalObj: fakeGlobal, gestures: false });
  wings.reveal('right');
  assert.equal(wings.rightEl.hidden, false);
  assert.equal(wings.leftEl.hidden, true);
  assert.equal(wings.setArranging, undefined, 'the Arrange pill is gone (W2): the ··· menu moves cards');
  assert.equal(wings.fanOut, undefined, 'wing motion is gone (owner, 11-08)');
  // The grabber first (top of the inner edge), then "Show in wing…", the Undo toast, then Recense, the first card.
  const cls = n => String(n.className || n.getAttribute?.('class') || '');
  for (const el of [wings.leftEl, wings.rightEl]) {
    assert.ok(cls(el.children[0]).includes('rc-wing-grabber'));
    assert.ok(cls(el.children[1]).includes('rc-wing-find'));
    assert.ok(cls(el.children[2]).includes('rc-wing-toast'));
    assert.equal(el.children[3].getAttribute ? el.children[3].getAttribute('data-widget') : el.children[3]['data-widget'], 'recense');
  }
  assert.equal(wings.preferredWidth(), 360, 'nothing playing: the narrow wing');
  const w = wings.setRecenseLine('Les parties conviennent que le vendeur livrera les marchandises dans trente jours.', 'The parties agree the seller will deliver the goods within thirty days.');
  assert.ok(w > 360 && w <= 560, `a long line widens the wing (${w})`);
  wings.destroy();
});

test('wing panel page: no edge-swipe listeners (the trackpad edge opens the panel natively)', () => {
  const { container, fakeGlobal, listeners } = setup();
  const wings = createDualWings(container, { globalObj: fakeGlobal, gestures: false });
  assert.equal((listeners.pointerdown || []).length, 0);
  assert.equal((listeners.touchstart || []).length, 0);
  wings.destroy();
  const again = setup();
  createDualWings(again.container, { globalObj: again.fakeGlobal });
  assert.equal(again.listeners.pointerdown.length, 1, 'the editor page keeps its own edge swipes');
});

test('wing side: the host script variable or #wings=left|right; anything else is the editor', () => {
  assert.equal(wingSideFrom({ __RECENSE_WING_SIDE: 'left' }), 'left');
  assert.equal(wingSideFrom({ location: { hash: '#wings=right' } }), 'right');
  assert.equal(wingSideFrom({ __RECENSE_WING_SIDE: 'top', location: { hash: '' } }), null);
  assert.equal(wingSideFrom(null), null);
});

test('Mac host: wing panels load the same page per side and share state, calendar and text', () => {
  const host = fs.readFileSync(path.resolve(__dirname, '../../strip/editorhost.swift'), 'utf8');
  const panels = fs.readFileSync(path.resolve(__dirname, '../../strip/wingpanels.swift'), 'utf8');
  assert.ok(host.includes('__RECENSE_WING_SIDE'), 'the host tells the page which side it is');
  assert.ok(host.includes('setNativeWings(true)'), 'the editor page hands its wings to the native panels');
  // Regression (2026-11-08): wings.js posts saveState's state as a JSON string; JSONSerialization.data(withJSONObject:)
  // on a String throws an Objective-C exception that try? can't catch, so moving a card crashed the app.
  assert.ok(host.includes('(state as? String)'), 'the saved wings state is taken as the JSON string it is');
  const ios = fs.readFileSync(path.resolve(__dirname, '../../mobile/HostApp/iOS/Draftpad.swift'), 'utf8');
  assert.ok(ios.includes('(state as? String)'), 'iOS takes the saved wings state as the JSON string it is (same crash)');
  assert.ok(panels.includes('NSVisualEffectView'), 'frosted glass behind each card');
  assert.ok(panels.includes('.canJoinAllSpaces') && panels.includes('.nonactivatingPanel'), 'floats on every Space, never takes focus');
  assert.ok(panels.includes('accessibilityDisplayShouldReduceMotion'), 'Reduce Motion: no slide, no fan');
});
