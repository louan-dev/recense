process.env.TZ = 'America/Los_Angeles';
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  extractCalendarEvents,
  createCalendarScanner,
  createDualWings,
  hashEventId,
  formatTimestamp,
  DEFAULT_WIDGETS,
  PAGE_MARKER
} from '../src/wings.js';
import { executeVoiceMove } from '../src/gestures.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// An ISO instant as local wall-clock time, YYYY-MM-DDTHH:MM.
function local(iso) {
  const d = new Date(iso);
  const z = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${z(d.getMonth() + 1)}-${z(d.getDate())}T${z(d.getHours())}:${z(d.getMinutes())}`;
}

function countTags(el, tag) {
  if (!el) return 0;
  let count = el.tagName === tag.toUpperCase() ? 1 : 0;
  for (const child of el.children || el.childNodes || []) {
    count += countTags(child, tag);
  }
  return count;
}

function setupMockDom() {
  const messages = { calendar: [], wings: [], ui: [] };

  const fakeGlobal = {
    webkit: {
      messageHandlers: {
        calendar: {
          postMessage(msg) {
            messages.calendar.push(msg);
          }
        },
        wings: {
          postMessage(msg) {
            messages.wings.push(msg);
          }
        },
        ui: {
          postMessage(msg) {
            messages.ui.push(msg);
          }
        }
      }
    }
  };

  const listeners = {};
  const children = [];

  const container = {
    tagName: 'DIV',
    clientWidth: 800,
    clientHeight: 600,
    getBoundingClientRect() {
      return { left: 0, top: 0, width: 800, height: 600, right: 800, bottom: 600 };
    },
    children,
    childNodes: children,
    firstChild: null,
    appendChild(child) {
      if (child) {
        children.push(child);
        child.parentElement = container;
        child.parentNode = container;
        container.firstChild = children[0] || null;
      }
      return child;
    },
    removeChild(child) {
      const idx = children.indexOf(child);
      if (idx !== -1) {
        children.splice(idx, 1);
        child.parentElement = null;
        child.parentNode = null;
        container.firstChild = children[0] || null;
      }
      return child;
    },
    addEventListener(type, fn) {
      listeners[type] = listeners[type] || [];
      listeners[type].push(fn);
    },
    removeEventListener(type, fn) {
      if (!listeners[type]) return;
      listeners[type] = listeners[type].filter(f => f !== fn);
    },
    dispatchEvent(event) {
      const type = event?.type || 'click';
      const fns = [...(listeners[type] || [])];
      for (const fn of fns) {
        fn(event);
      }
    }
  };

  return { container, fakeGlobal, messages };
}

// ============================================================================
// Requirement 1: 24/7 Multilingual Time & Date Extractor
// ============================================================================

test('P6 Extractor: ISO dates with optional time, range, and standalone header filtering', () => {
  const refDate = new Date('2026-11-10T12:00:00Z');

  const doc = [
    '2026-11-15 14:00',
    '2026-11-15 at 2:30 PM',
    '2026-11-15 14:00 - 15:30 Team sync',
    '2026-11-15', // Standalone ISO date without time or description -> IGNORED
    '2026-11-16 Strategy session' // ISO date with description -> EXTRACTED
  ].join('\n');

  const events = extractCalendarEvents(doc, { referenceDate: refDate });
  assert.equal(events.length, 4, 'Must extract 4 events and ignore 1 standalone date line');

  // Event 1: 2026-11-15 14:00
  assert.equal(local(events[0].startISO), '2026-11-15T14:00');
  assert.equal(local(events[0].endISO), '2026-11-15T15:00');
  assert.equal(events[0].lineNumber, 1);
  assert.equal(events[0].pageIndex, 0);

  // Event 2: 2026-11-15 at 2:30 PM
  assert.equal(local(events[1].startISO), '2026-11-15T14:30');
  assert.equal(local(events[1].endISO), '2026-11-15T15:30');
  assert.equal(events[1].lineNumber, 2);

  // Event 3: 2026-11-15 14:00 - 15:30 Team sync
  assert.equal(events[2].title, 'Team sync');
  assert.equal(local(events[2].startISO), '2026-11-15T14:00');
  assert.equal(local(events[2].endISO), '2026-11-15T15:30');
  assert.equal(events[2].lineNumber, 3);

  // Event 4: 2026-11-16 Strategy session
  assert.equal(events[3].title, 'Strategy session');
  assert.equal(local(events[3].startISO), '2026-11-16T00:00');
  assert.equal(local(events[3].endISO), '2026-11-17T00:00');
  assert.equal(events[3].allDay, true);
  assert.equal(events[3].lineNumber, 5);
});

test('P6 Extractor: English month-name dates and standalone Draftpad header filtering', () => {
  const refDate = new Date('2026-11-10T12:00:00Z');

  const doc = [
    'November 13, 2026 at 2:00 PM',
    'Nov 13, 2026 9:30am',
    'Friday, November 13, 2026 at 14:00',
    'Friday, November 13, 2026', // Standalone Draftpad page header date line -> IGNORED
    'Friday, November 13, 2026: Discovery conference', // Header with description -> EXTRACTED
    'Nov 13, 2026 9:30am - 10:45am Oral Argument' // Range with title
  ].join('\n');

  const events = extractCalendarEvents(doc, { referenceDate: refDate });
  assert.equal(events.length, 5, 'Must extract 5 events and ignore standalone page header date line');

  assert.equal(local(events[0].startISO), '2026-11-13T14:00');
  assert.equal(local(events[0].endISO), '2026-11-13T15:00');

  assert.equal(local(events[1].startISO), '2026-11-13T09:30');
  assert.equal(local(events[1].endISO), '2026-11-13T10:30');

  assert.equal(local(events[2].startISO), '2026-11-13T14:00');
  assert.equal(local(events[2].endISO), '2026-11-13T15:00');

  assert.equal(events[3].title, 'Discovery conference');
  assert.equal(local(events[3].startISO), '2026-11-13T00:00');
  assert.equal(events[3].allDay, true);

  assert.equal(events[4].title, 'Oral Argument');
  assert.equal(local(events[4].startISO), '2026-11-13T09:30');
  assert.equal(local(events[4].endISO), '2026-11-13T10:45');
});

test('P6 Extractor: French date expressions (le DD mois YYYY, demain, ranges)', () => {
  const refDate = new Date('2026-11-17T08:00:00Z');

  const doc = [
    'le 18 novembre 2026 à 10h30',
    '18 novembre 2026 14h00',
    'demain à 14h30',
    '18 novembre 2026', // Standalone date line -> IGNORED
    'le 18 novembre 2026 à 10h30 - 12h00 Audience préliminaire'
  ].join('\n');

  const events = extractCalendarEvents(doc, { referenceDate: refDate });
  assert.equal(events.length, 4, 'Must extract 4 French events and ignore 1 standalone date line');

  assert.equal(local(events[0].startISO), '2026-11-18T10:30');
  assert.equal(local(events[0].endISO), '2026-11-18T11:30');

  assert.equal(local(events[1].startISO), '2026-11-18T14:00');
  assert.equal(local(events[1].endISO), '2026-11-18T15:00');

  // Tomorrow from Nov 17 is Nov 18
  assert.equal(local(events[2].startISO), '2026-11-18T14:30');
  assert.equal(local(events[2].endISO), '2026-11-18T15:30');

  assert.equal(events[3].title, 'Audience préliminaire');
  assert.equal(local(events[3].startISO), '2026-11-18T10:30');
  assert.equal(local(events[3].endISO), '2026-11-18T12:00');
});

test('P6 Extractor: Vietnamese date expressions (ngày DD/MM, ngày mai, ranges)', () => {
  const refDate = new Date('2026-11-19T08:00:00Z');

  const doc = [
    'ngày 20/11/2026 lúc 15:00',
    'ngày 20 tháng 11 năm 2026 lúc 9h30',
    'ngày mai lúc 8:30',
    'ngày 20 tháng 11 năm 2026', // Standalone date line -> IGNORED
    'ngày 20/11/2026 lúc 15:00 - 17:00 Ký kết hợp đồng thương mại'
  ].join('\n');

  const events = extractCalendarEvents(doc, { referenceDate: refDate });
  assert.equal(events.length, 4, 'Must extract 4 Vietnamese events and ignore 1 standalone date line');

  assert.equal(local(events[0].startISO), '2026-11-20T15:00');
  assert.equal(local(events[0].endISO), '2026-11-20T16:00');

  assert.equal(local(events[1].startISO), '2026-11-20T09:30');
  assert.equal(local(events[1].endISO), '2026-11-20T10:30');

  // Ngày mai from Nov 19 is Nov 20
  assert.equal(local(events[2].startISO), '2026-11-20T08:30');
  assert.equal(local(events[2].endISO), '2026-11-20T09:30');

  assert.equal(events[3].title, 'Ký kết hợp đồng thương mại');
  assert.equal(local(events[3].startISO), '2026-11-20T15:00');
  assert.equal(local(events[3].endISO), '2026-11-20T17:00');
});

test('P6 Extractor: Relative English dates (today, tomorrow, title remainder)', () => {
  const refDate = new Date('2026-11-10T08:00:00Z');

  const doc = [
    'today at 5:00 PM',
    'tomorrow at 9:30am',
    'Client call tomorrow at 9:30am',
    '- [ ] Filing deadline today at 5:00 PM - 6:00 PM'
  ].join('\n');

  const events = extractCalendarEvents(doc, { referenceDate: refDate });
  assert.equal(events.length, 4);

  // Today Nov 10
  assert.equal(local(events[0].startISO), '2026-11-10T17:00');
  assert.equal(local(events[0].endISO), '2026-11-10T18:00');

  // Tomorrow Nov 11
  assert.equal(local(events[1].startISO), '2026-11-11T09:30');
  assert.equal(local(events[1].endISO), '2026-11-11T10:30');

  assert.equal(events[2].title, 'Client call');
  assert.equal(local(events[2].startISO), '2026-11-11T09:30');

  assert.equal(events[3].title, 'Filing deadline');
  assert.equal(local(events[3].startISO), '2026-11-10T17:00');
  assert.equal(local(events[3].endISO), '2026-11-10T18:00');
});

test('P6 Extractor: Multi-page Draftpad document tracks exact pageIndex and line numbers', () => {
  const doc = [
    'Page 1 Header',
    '2026-11-15 14:00 First Event',
    '',
    PAGE_MARKER,
    '',
    'Friday, November 13, 2026', // standalone page header
    'November 13, 2026 at 2:00 PM Second Event',
    '',
    PAGE_MARKER,
    '',
    'demain à 14h30 Troisième Événement'
  ].join('\n');

  const refDate = new Date('2026-11-10T12:00:00Z');
  const events = extractCalendarEvents(doc, { referenceDate: refDate });

  assert.equal(events.length, 3);

  // Event 1 on page 0, line 2
  assert.equal(events[0].pageIndex, 0);
  assert.equal(events[0].lineNumber, 2);
  assert.equal(events[0].title, 'First Event');

  // Event 2 on page 1, line 7
  assert.equal(events[1].pageIndex, 1);
  assert.equal(events[1].lineNumber, 7);
  assert.equal(events[1].title, 'Second Event');

  // Event 3 on page 2, line 11
  assert.equal(events[2].pageIndex, 2);
  assert.equal(events[2].lineNumber, 11);
  assert.equal(events[2].title, 'Troisième Événement');
});

test('P6 Extractor: Deterministic hash ID (cal-<8hex>) guarantees duplicate-free re-scans', () => {
  const title = 'Oral Argument';
  const startISO = '2026-11-13T09:30:00.000Z';

  const id1 = hashEventId(title, startISO);
  const id2 = hashEventId(title, startISO);
  const idDifferentTitle = hashEventId('Oral Argument 2', startISO);

  assert.match(id1, /^cal-[0-9a-f]{8}$/, 'Must match cal-<8hex>');
  assert.equal(id1, id2, 'Identical title and startISO must produce identical ID');
  assert.notEqual(id1, idDifferentTitle, 'Different title must produce different ID');

  const doc = '2026-11-15 14:00 Deposition with Expert';
  const scanA = extractCalendarEvents(doc);
  const scanB = extractCalendarEvents(doc);

  assert.equal(scanA[0].id, scanB[0].id);
});

// ============================================================================
// Requirement 2: 24/7 Continuous Calendar Scanner
// ============================================================================

test('P6 Scanner: scanning only proposes; requestAdd posts one event; markSynced marks it added', () => {
  const { fakeGlobal, messages } = setupMockDom();
  const scans = [];
  const scanner = createCalendarScanner({ globalObj: fakeGlobal, onScan: evs => scans.push(evs) });

  const doc1 = ['2026-11-15 14:00 First Meeting', '2026-11-16 10:00 Second Meeting'].join('\n');
  const res1 = scanner.scanText(doc1);
  assert.equal(res1.length, 2);
  assert.equal(scans.length, 1);
  assert.equal(messages.calendar.length, 0, 'a scan never writes to the calendar');
  assert.equal(res1[0].added, false);

  assert.equal(scanner.requestAdd(res1[0]), true);
  assert.equal(messages.calendar.length, 1);
  assert.equal(messages.calendar[0].action, 'addEvents');
  assert.deepEqual(messages.calendar[0].events.map(e => e.id), [res1[0].id]);
  assert.equal(scanner.getSyncedIds().size, 0, 'not added until the host reports the save');

  scanner.markSynced(res1[0].id);
  const res2 = scanner.scanText(doc1);
  assert.equal(res2[0].added, true);
  assert.equal(res2[1].added, false);
  assert.equal(scanner.requestAdd(res2[0]), false, 'an added event is not sent twice');
  assert.equal(messages.calendar.length, 1);
});

test('E2 review #1 regression: typing an event line sends nothing to the calendar', () => {
  const { fakeGlobal, messages } = setupMockDom();
  const scanner = createCalendarScanner({ globalObj: fakeGlobal });
  const ref = new Date('2026-11-08T09:00:00');
  const line = 'Lunch with Mai tomorrow at 1pm';
  for (let i = 1; i <= line.length; i++) scanner.scanText('# Page\n' + line.slice(0, i), { referenceDate: ref });
  scanner.scanText('# Page\nLunch with Mai tomorrow at 2pm', { referenceDate: ref });
  assert.equal(messages.calendar.length, 0);
  const evs = scanner.scanText('# Page\n' + line, { referenceDate: ref });
  assert.equal(evs.length, 1);
  assert.equal(evs[0].title, 'Lunch with Mai');
});

test('E2 review #2 regression: "1pm" is 1 PM local time, not 1 PM UTC', () => {
  const ref = new Date('2026-11-08T09:00:00');
  const [ev] = extractCalendarEvents('Lunch with Mai tomorrow at 1pm', { referenceDate: ref });
  assert.equal(local(ev.startISO), '2026-11-09T13:00');
  assert.equal(ev.startISO, '2026-11-09T21:00:00.000Z', 'PST is UTC-8 in November');
  const [late] = extractCalendarEvents('2026-11-20 22:00 - 01:00 Moot court prep', { referenceDate: ref });
  assert.equal(local(late.endISO), '2026-11-21T01:00', 'a range past midnight ends the next day');
});

test('E2 review #3 regression: header fields and everyday "today" sentences are not events; no duplicates', () => {
  const ref = new Date('2026-11-08T09:00:00');
  const doc = [
    'Date: October 9, 2026',
    'help me reprioritize today, your job is to make a spec',
    'Date: October 9, 2026',
    'ngày mai đi học',
    'Hearing 2026-11-20 at 9:30am',
    'Hearing 2026-11-20 at 9:30am'
  ].join('\n');
  const evs = extractCalendarEvents(doc, { referenceDate: ref });
  assert.deepEqual(evs.map(e => e.title), ['Hearing']);
});

// ============================================================================
// Requirement 3 & 4: Dual Wings, 4 Feathery Widgets, and Zero Chrome
// ============================================================================

test('P6 Dual Wings: zero-chrome at rest, no <button> elements in wings or cards', () => {
  const { container, fakeGlobal } = setupMockDom();

  const wings = createDualWings(container, { globalObj: fakeGlobal });

  assert.equal(DEFAULT_WIDGETS.length, 5);
  assert.deepEqual(DEFAULT_WIDGETS, ['preview', 'quicktime', 'findmy', 'mail', 'calendar']);

  assert.ok(wings.leftEl, 'Left wing element created');
  assert.ok(wings.rightEl, 'Right wing element created');
  assert.equal(wings.leftEl.hidden, true, 'Left wing must start hidden for zero-chrome');
  assert.equal(wings.rightEl.hidden, true, 'Right wing must start hidden for zero-chrome');
  assert.equal(wings.leftEl.getAttribute('data-side'), 'left');
  assert.equal(wings.rightEl.getAttribute('data-side'), 'right');

  // Zero-Chrome: Verify NO <button> elements exist in either wing
  assert.equal(countTags(wings.leftEl, 'button'), 0, 'Left wing must contain zero <button> tags');
  assert.equal(countTags(wings.rightEl, 'button'), 0, 'Right wing must contain zero <button> tags');
  assert.equal(countTags(container, 'button'), 0, 'Container must contain zero <button> tags');

  wings.destroy();
});

test('P6 Dual Wings: symmetric ambidextrous controls (open, close, toggle, haptics)', () => {
  const { container, fakeGlobal, messages } = setupMockDom();

  const wings = createDualWings(container, { globalObj: fakeGlobal });

  assert.equal(wings.isWingOpen('left'), false);
  assert.equal(wings.isWingOpen('right'), false);
  assert.equal(wings.isWingOpen('both'), false);

  // Open Left Wing
  wings.openWing('left');
  assert.equal(wings.isWingOpen('left'), true);
  assert.equal(wings.isWingOpen('right'), false);
  assert.equal(messages.ui.length, 1);
  assert.deepEqual(messages.ui[0], { haptic: 'open' });

  // Close Left Wing
  wings.closeWing('left');
  assert.equal(wings.isWingOpen('left'), false);

  // Open Right Wing
  wings.openWing('right');
  assert.equal(wings.isWingOpen('left'), false);
  assert.equal(wings.isWingOpen('right'), true);
  assert.equal(messages.ui.length, 2);
  assert.deepEqual(messages.ui[1], { haptic: 'open' });

  // Toggle Left Wing (closed -> open)
  wings.toggleWing('left');
  assert.equal(wings.isWingOpen('left'), true);
  assert.equal(wings.isWingOpen('right'), true);
  assert.equal(wings.isWingOpen('both'), true);

  // Toggle Left Wing again (open -> close)
  wings.toggleWing('left');
  assert.equal(wings.isWingOpen('left'), false);

  // Open Both
  wings.openWing('both');
  assert.equal(wings.isWingOpen('both'), true);

  // Close Both
  wings.closeWing('both');
  assert.equal(wings.isWingOpen('both'), false);

  wings.destroy();
});

test('P6 Dual Wings: swapWings mirrors workspace layout instantaneously for ambidexterity', () => {
  const { container, fakeGlobal, messages } = setupMockDom();

  const wings = createDualWings(container, {
    globalObj: fakeGlobal,
    leftWidgets: ['preview', 'quicktime'],
    rightWidgets: ['calendar', 'findmy', 'mail']
  });

  const initialLayout = wings.getWingLayout();
  assert.deepEqual(initialLayout.left, ['preview', 'quicktime']);
  assert.deepEqual(initialLayout.right, ['calendar', 'findmy', 'mail']);

  // Instantaneous Ambidextrous Swap
  wings.swapWings();

  const swappedLayout = wings.getWingLayout();
  assert.deepEqual(swappedLayout.left, ['calendar', 'findmy', 'mail']);
  assert.deepEqual(swappedLayout.right, ['preview', 'quicktime']);
  assert.equal(messages.ui.some(m => m.haptic === 'snap'), true, 'Must post haptic snap on swap');

  // moveWidget test
  wings.moveWidget('preview', 'left');
  const movedLayout = wings.getWingLayout();
  assert.ok(movedLayout.left.includes('preview'));
  assert.ok(!movedLayout.right.includes('preview'));

  wings.destroy();
});

test('P6 Feathery Offline Widgets: Preview exhibits and citation into page', () => {
  const { container, fakeGlobal, messages } = setupMockDom();
  const inserted = [];

  const wings = createDualWings(container, {
    globalObj: fakeGlobal,
    rightWidgets: ['calendar', 'findmy', 'mail'],
    onInsertToPage(snippet) {
      inserted.push(snippet);
    }
  });

  // Set image preview
  wings.setPreviewTarget('recense-file:///docs/exhibit-a.png', 'Exhibit A - Contract');
  const previewCard = wings.leftEl.querySelector('.rc-widget-preview');
  assert.ok(previewCard);
  assert.equal(previewCard.getAttribute('data-src'), 'recense-file:///docs/exhibit-a.png');

  // Click card to cite
  const previewBody = previewCard.querySelector('.rc-preview-body');
  previewBody.dispatchEvent({ type: 'click' });

  assert.equal(inserted.length, 1);
  assert.equal(inserted[0], '![Exhibit A - Contract](recense-file:///docs/exhibit-a.png)\n');
  assert.equal(messages.wings[0].action, 'cite');
  assert.equal(messages.wings[0].type, 'preview');

  // Set PDF preview
  wings.setPreviewTarget('recense-file:///docs/brief.pdf', 'Amicus Brief');
  previewBody.dispatchEvent({ type: 'click' });
  assert.equal(inserted[1], '[Amicus Brief](recense-file:///docs/brief.pdf)\n');

  wings.destroy();
});

test('P6 Feathery Offline Widgets: QuickTime player, rate, loop, and timestamp citation', () => {
  const { container, fakeGlobal, messages } = setupMockDom();
  const inserted = [];

  const wings = createDualWings(container, {
    globalObj: fakeGlobal,
    rightWidgets: ['calendar', 'findmy', 'mail'],
    onInsertToPage(snippet) {
      inserted.push(snippet);
    }
  });

  wings.setMediaSource('recense-file:///media/deposition.mov', 'Deposition Video');
  wings.setPlaybackRate(1.5);
  wings.setLoopRange(10, 45);

  const qtCard = wings.leftEl.querySelector('.rc-widget-quicktime');
  assert.ok(qtCard);
  assert.equal(qtCard.getAttribute('data-src'), 'recense-file:///media/deposition.mov');

  const qtBody = qtCard.querySelector('.rc-qt-body');
  qtBody.dispatchEvent({ type: 'click' });   // a click on the picture (its play controls) cites nothing
  assert.equal(inserted.length, 0);
  qtBody.dispatchEvent({ type: 'click', target: qtCard.querySelector('.rc-qt-timestamp') });

  assert.equal(inserted.length, 1);
  assert.match(inserted[0], /^\[@\d{2}:\d{2}\] Deposition Video\n$/);
  assert.equal(messages.wings.some(m => m.type === 'quicktime'), true);

  wings.destroy();
});

test('P6 Feathery Offline Widgets: Find My 100% offline cache and persistent session', () => {
  const { container, fakeGlobal, messages } = setupMockDom();
  const inserted = [];

  const wings = createDualWings(container, {
    globalObj: fakeGlobal,
    rightWidgets: ['calendar', 'findmy', 'mail'],
    onInsertToPage(snippet) {
      inserted.push(snippet);
    }
  });

  const sampleItems = [
    { id: 'dev-1', name: 'MacBook Pro M4', location: 'Law Library 3rd Floor', updatedAt: '2m ago', battery: '92%', status: 'Nearby' },
    { id: 'dev-2', name: 'iPad Pro', location: 'Home Office', updatedAt: '15m ago', battery: '68%', status: 'Home' }
  ];

  wings.setFindMyItems(sampleItems);

  const findMyCard = wings.rightEl.querySelector('.rc-widget-findmy');
  assert.ok(findMyCard);

  const itemRows = findMyCard.querySelectorAll('.rc-findmy-item');
  assert.equal(itemRows.length, 2);

  // Click first item to cite into page
  itemRows[0].dispatchEvent({ type: 'click' });
  assert.equal(inserted.length, 1);
  assert.equal(inserted[0], 'MacBook Pro M4: Law Library 3rd Floor (as of 2m ago)\n');

  // Open persistent session
  wings.openPersistentSession('findmy');
  const sessionMsg = messages.wings.find(m => m.action === 'openSession' && m.service === 'findmy');
  assert.ok(sessionMsg);
  assert.equal(sessionMsg.url, 'https://www.icloud.com/find');

  wings.destroy();
});

test('P6 Feathery Offline Widgets: Mail digest 100% offline cache and persistent session', () => {
  const { container, fakeGlobal, messages } = setupMockDom();
  const inserted = [];

  const wings = createDualWings(container, {
    globalObj: fakeGlobal,
    rightWidgets: ['calendar', 'findmy', 'mail'],
    onInsertToPage(snippet) {
      inserted.push(snippet);
    }
  });

  const sampleMail = [
    { id: 'm1', from: 'clerk@court.gov', subject: 'Hearing Schedule Order', snippet: 'Hearing confirmed for Friday.', date: '10:15 AM', unread: true },
    { id: 'm2', from: 'colleague@firm.com', subject: 'Draft Review', snippet: 'Section 4 edits attached.', date: 'Yesterday', unread: false }
  ];

  wings.setMailMessages(sampleMail);

  const mailCard = wings.rightEl.querySelector('.rc-widget-mail');
  assert.ok(mailCard);

  const mailRows = mailCard.querySelectorAll('.rc-mail-item');
  assert.equal(mailRows.length, 2);

  // Click first email to cite blockquote into page
  mailRows[0].dispatchEvent({ type: 'click' });
  assert.equal(inserted.length, 1);
  assert.ok(inserted[0].includes('clerk@court.gov'));
  assert.ok(inserted[0].includes('Hearing Schedule Order'));

  // Open persistent session
  wings.openPersistentSession('mail');
  const sessionMsg = messages.wings.find(m => m.action === 'openSession' && m.service === 'mail');
  assert.ok(sessionMsg);
  assert.equal(sessionMsg.url, 'https://www.icloud.com/mail');

  wings.destroy();
});

test('P6 Feathery Offline Widgets: Calendar Agenda widget and jump to line', () => {
  const { container, fakeGlobal, messages } = setupMockDom();
  const jumpedLines = [];

  const wings = createDualWings(container, {
    globalObj: fakeGlobal,
    onJumpToLine(line) {
      jumpedLines.push(line);
    }
  });

  const sampleEvents = [
    { id: 'cal-1', title: 'Oral Argument', startISO: '2026-11-13T09:30:00.000Z', endISO: '2026-11-13T10:30:00.000Z', lineNumber: 42, pageIndex: 1, rawLine: '...' }
  ];

  wings.setCalendarEvents(sampleEvents);

  const calCard = wings.rightEl.querySelector('.rc-widget-calendar');
  assert.ok(calCard);

  const calItems = calCard.querySelectorAll('.rc-cal-item');
  assert.equal(calItems.length, 1);

  calItems[0].dispatchEvent({ type: 'click' });
  assert.equal(jumpedLines.length, 1);
  assert.equal(jumpedLines[0], 42);

  const calMsg = messages.calendar.find(m => m.action === 'jumpToLine');
  assert.ok(calMsg);
  assert.equal(calMsg.lineNumber, 42);

  wings.destroy();
});

// ============================================================================
// Requirement 4: Edge-swipe & Bilateral Inward Swipe Kinetics
// ============================================================================

test('P6 Kinetics: edge-swipe inward opens left/right wing, outward closes wing', () => {
  const { container, fakeGlobal } = setupMockDom();

  const wings = createDualWings(container, { globalObj: fakeGlobal });

  // 1. Swiping inward from left edge (x <= 24, dx >= 36) opens Left Wing
  container.dispatchEvent({
    type: 'touchstart',
    changedTouches: [{ identifier: 1, clientX: 12, clientY: 200 }]
  });
  container.dispatchEvent({
    type: 'touchmove',
    changedTouches: [{ identifier: 1, clientX: 60, clientY: 200 }] // dx = +48 >= 36
  });
  container.dispatchEvent({
    type: 'touchend',
    changedTouches: [{ identifier: 1, clientX: 60, clientY: 200 }]
  });

  assert.equal(wings.isWingOpen('left'), true, 'Left wing must open on left edge inward swipe');
  assert.equal(wings.isWingOpen('right'), false);

  // 2. Swiping outward toward left edge (dx <= -36) closes Left Wing
  container.dispatchEvent({
    type: 'touchstart',
    changedTouches: [{ identifier: 2, clientX: 100, clientY: 200 }]
  });
  container.dispatchEvent({
    type: 'touchmove',
    changedTouches: [{ identifier: 2, clientX: 40, clientY: 200 }] // dx = -60 <= -36
  });
  container.dispatchEvent({
    type: 'touchend',
    changedTouches: [{ identifier: 2, clientX: 40, clientY: 200 }]
  });

  assert.equal(wings.isWingOpen('left'), false, 'Left wing must close on outward swipe');

  // 3. Swiping inward from right edge (x >= 800 - 24 = 776, dx <= -36) opens Right Wing
  container.dispatchEvent({
    type: 'touchstart',
    changedTouches: [{ identifier: 3, clientX: 790, clientY: 250 }]
  });
  container.dispatchEvent({
    type: 'touchmove',
    changedTouches: [{ identifier: 3, clientX: 740, clientY: 250 }] // dx = -50 <= -36
  });
  container.dispatchEvent({
    type: 'touchend',
    changedTouches: [{ identifier: 3, clientX: 740, clientY: 250 }]
  });

  assert.equal(wings.isWingOpen('right'), true, 'Right wing must open on right edge inward swipe');
  assert.equal(wings.isWingOpen('left'), false);

  // 4. Swiping outward toward right edge (dx >= 36) closes Right Wing
  container.dispatchEvent({
    type: 'touchstart',
    changedTouches: [{ identifier: 4, clientX: 700, clientY: 250 }]
  });
  container.dispatchEvent({
    type: 'touchmove',
    changedTouches: [{ identifier: 4, clientX: 750, clientY: 250 }] // dx = +50 >= 36
  });
  container.dispatchEvent({
    type: 'touchend',
    changedTouches: [{ identifier: 4, clientX: 750, clientY: 250 }]
  });

  assert.equal(wings.isWingOpen('right'), false, 'Right wing must close on outward swipe');

  wings.destroy();
});

test('P6 Kinetics: two-touch simultaneous inward swipe from both edges opens BOTH wings', () => {
  const { container, fakeGlobal } = setupMockDom();

  const wings = createDualWings(container, { globalObj: fakeGlobal });

  assert.equal(wings.isWingOpen('both'), false);

  // Two fingers start at opposite edges: Touch 1 at Left (x=10 <= 24), Touch 2 at Right (x=790 >= 776)
  container.dispatchEvent({
    type: 'touchstart',
    changedTouches: [
      { identifier: 10, clientX: 10, clientY: 300 },
      { identifier: 20, clientX: 790, clientY: 300 }
    ]
  });

  // Simultaneous inward swipe
  container.dispatchEvent({
    type: 'touchmove',
    changedTouches: [
      { identifier: 10, clientX: 60, clientY: 300 },  // dx = +50 >= 36
      { identifier: 20, clientX: 740, clientY: 300 }  // dx = -50 <= -36
    ]
  });

  assert.equal(wings.isWingOpen('both'), true, 'Two-touch simultaneous inward swipe must open BOTH wings');

  container.dispatchEvent({
    type: 'touchend',
    changedTouches: [
      { identifier: 10, clientX: 60, clientY: 300 },
      { identifier: 20, clientX: 740, clientY: 300 }
    ]
  });

  wings.destroy();
});

test('P6 Voice & State Persistence: multilingual voice commands and getState/setState round-trip', () => {
  const { container, fakeGlobal, messages } = setupMockDom();
  const wings = createDualWings(container, { globalObj: fakeGlobal });

  const handlers = {
    openWing: side => wings.openWing(side),
    closeWing: side => wings.closeWing(side),
    swapWings: () => wings.swapWings()
  };

  assert.deepEqual(executeVoiceMove('open left wing', handlers), {
    matched: true,
    action: 'openWing',
    side: 'left'
  });
  assert.equal(wings.isWingOpen('left'), true);

  assert.deepEqual(executeVoiceMove('mở hai bên', handlers), {
    matched: true,
    action: 'openWing',
    side: 'both'
  });
  assert.equal(wings.isWingOpen('both'), true);

  assert.deepEqual(executeVoiceMove('đổi bên', handlers), {
    matched: true,
    action: 'swapWings'
  });
  assert.deepEqual(wings.getWingLayout().left, ['calendar']);

  assert.deepEqual(executeVoiceMove('fermer les volets', handlers), {
    matched: true,
    action: 'closeWing',
    side: 'both'
  });
  assert.equal(wings.isWingOpen('left'), false);
  assert.equal(wings.isWingOpen('right'), false);

  // Verify state round-trip
  const saved = JSON.stringify(wings.getState());
  assert.ok(messages.wings.some(m => m.action === 'saveState'));

  const wings2 = createDualWings(container, { globalObj: fakeGlobal });
  wings2.setState(saved);
  assert.deepEqual(wings2.getWingLayout().left, ['calendar']);

  wings.destroy();
  wings2.destroy();
});

test('P6 Native Host Parity: strip/editorhost.swift and mobile/HostApp/iOS/Draftpad.swift wire EventKit & Dual Wings', () => {
  const macHost = fs.readFileSync(path.resolve(__dirname, '../../strip/editorhost.swift'), 'utf8');
  const iosHost = fs.readFileSync(path.resolve(__dirname, '../../mobile/HostApp/iOS/Draftpad.swift'), 'utf8');

  for (const [label, src] of [['Mac host', macHost], ['iOS host', iosHost]]) {
    assert.ok(src.includes('import EventKit'), `${label} must import EventKit`);
    assert.ok(src.includes('draftpad.events.json'), `${label} must persist synced calendar IDs in draftpad.events.json`);
    assert.ok(src.includes('draftpad.wings.json'), `${label} must persist wings state in draftpad.wings.json`);
    assert.ok(src.includes('cfg.websiteDataStore = .default()'), `${label} must keep web sessions signed in via .default()`);
    assert.ok(src.includes('"calendar"'), `${label} must register calendar WKScriptMessageHandler`);
    assert.ok(src.includes('"wings"'), `${label} must register wings WKScriptMessageHandler`);
    assert.ok(src.includes('private func saveEvents('), `${label} must save only confirmed events (saveEvents)`);
    assert.ok(src.includes('.withFractionalSeconds'), `${label} must read JS toISOString() dates (milliseconds), E2 review regression`);
    assert.ok(src.includes('calendarResult('), `${label} must report each save back to the page`);
    assert.ok(src.includes('NLLanguageRecognizer'), `${label} must pick the read-aloud voice from the text's language`);
    assert.ok(!src.includes('try? self.eventStore.save'), `${label} must not drop calendar save errors`);
  }
});

test('Widgets move between wings with one visible control per card', () => {
  const { container, fakeGlobal } = setupMockDom();
  const wings = createDualWings(container, { globalObj: fakeGlobal });
  assert.deepEqual(wings.getWingLayout().left, ['preview', 'quicktime']);
  assert.deepEqual(wings.getWingLayout().right, ['calendar']);
  const movers = wings.leftEl.querySelectorAll('.rc-wing-move');
  assert.equal(movers.length, 2, 'one mover per card');
  assert.equal(countTags(wings.leftEl, 'button'), 0, 'still zero <button> chrome');
  const cal = wings.rightEl.querySelectorAll('.rc-wing-move')[0];
  assert.equal(cal.getAttribute('aria-label'), 'Move Agenda to the left sidebar');
  cal.dispatchEvent({ type: 'click' });
  assert.deepEqual(wings.getWingLayout().left, ['preview', 'quicktime', 'calendar']);
  assert.deepEqual(wings.getWingLayout().right, []);
  const back = wings.leftEl.querySelectorAll('.rc-wing-move')[2];
  back.dispatchEvent({ type: 'keydown', key: 'Enter' });
  assert.deepEqual(wings.getWingLayout().right, ['calendar']);
  wings.destroy();
});

test('iPhone Mirroring card: hidden until the host enables it, opens the app, and moves like any card', () => {
  const { container, fakeGlobal, messages } = setupMockDom();
  const wings = createDualWings(container, { globalObj: fakeGlobal, leftWidgets: ['preview', 'iphone'] });
  assert.equal(wings.leftEl.querySelectorAll('.rc-widget-iphone').length, 0, 'iOS never calls enableHostWidget');
  wings.enableHostWidget('iphone');
  const card = wings.leftEl.querySelectorAll('.rc-widget-iphone');
  assert.equal(card.length, 1);
  card[0].querySelectorAll('.rc-iphone-open')[0].dispatchEvent({ type: 'click' });
  assert.ok(messages.wings.some(m => m.action === 'openApp' && m.app === 'iphone-mirroring'));
  wings.moveWidget('iphone', 'right');
  assert.equal(wings.rightEl.querySelectorAll('.rc-widget-iphone').length, 1);
  wings.destroy();
});

test('Agenda card: Add is the confirm step and shows the host\'s result', () => {
  const { container, fakeGlobal } = setupMockDom();
  const asked = [];
  const wings = createDualWings(container, { globalObj: fakeGlobal, onAddEvent: ev => asked.push(ev.id) });
  const [ev] = extractCalendarEvents('Hearing 2026-11-20 at 9:30am', { referenceDate: new Date('2026-11-08T09:00:00') });
  wings.setCalendarEvents([ev]);
  const add = () => wings.rightEl.querySelectorAll('.rc-cal-add')[0];
  assert.equal(add().textContent, 'Add to Calendar');
  add().dispatchEvent({ type: 'click' });
  assert.deepEqual(asked, [ev.id]);
  assert.equal(add().textContent, 'Adding…');
  wings.setCalendarStatus(ev.id, 'error', 'Calendar access is off');
  assert.equal(add().textContent, 'Not added: Calendar access is off · Try again');
  wings.setCalendarStatus(ev.id, 'added');
  assert.equal(add().textContent, 'Added to Calendar');
  wings.destroy();
});
