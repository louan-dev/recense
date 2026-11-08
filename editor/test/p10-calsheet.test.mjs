// The calendar sheet: what it asks about, and the event it hands the host after revisions.
import test from 'node:test';
import assert from 'node:assert/strict';
import { eventsToOffer, eventFromFields, localDate, localTime } from '../src/calsheet.js';

const now = new Date(2026, 10, 8, 12, 0).getTime();
const ev = (id, day, extra = {}) => ({ id, title: 'Moot court', startISO: new Date(2026, 10, day, 14).toISOString(),
  endISO: new Date(2026, 10, day, 15).toISOString(), rawLine: 'Moot court tomorrow 2pm', ...extra });

test('asks only about future events not added, refused or already asked', () => {
  const list = [ev('a', 9), ev('b', 7), ev('c', 9, { added: true }), ev('d', 10), ev('e', 11)];
  const got = eventsToOffer(list, { dismissed: new Set(['d']), offered: new Set(['e']), now });
  assert.deepEqual(got.map(e => e.id), ['a']);
});

test('the revised fields become the event, in local time', () => {
  const out = eventFromFields(ev('a', 9), { title: ' Moot court finals ', date: '2026-11-10', start: '16:30', end: '18:00',
    allDay: false, location: 'Room 4', notes: 'bring brief' });
  assert.equal(out.id, 'a');
  assert.equal(out.title, 'Moot court finals');
  assert.equal(localDate(new Date(out.startISO)), '2026-11-10');
  assert.equal(localTime(new Date(out.startISO)), '16:30');
  assert.equal(localTime(new Date(out.endISO)), '18:00');
  assert.equal(out.location, 'Room 4');
  assert.equal(out.notes, 'bring brief');
});

test('all day spans the day; an end before the start becomes one hour', () => {
  const d = eventFromFields(ev('a', 9), { title: '', date: '2026-11-10', allDay: true });
  assert.equal(d.allDay, true);
  assert.equal(d.title, 'Moot court', 'empty title keeps the note’s');
  assert.equal(new Date(d.endISO) - new Date(d.startISO), 86_400_000);
  const r = eventFromFields(ev('a', 9), { title: 'x', date: '2026-11-10', start: '10:00', end: '09:00' });
  assert.equal(new Date(r.endISO) - new Date(r.startISO), 3_600_000);
});
