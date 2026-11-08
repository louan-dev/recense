// The calendar sheet: the scanner (wings.js createCalendarScanner) reads every page as you write, and each new event in
// the future opens this sheet, prefilled, once typing has paused. Nothing is saved until "Add to Calendar":
//   · revise any field first (title, day, times, all day, place, notes);
//   · "Don't add" remembers the no (draftpad.events.json keeps it as "x:<id>", next to the events already added);
//   · tapping outside or Esc only puts it off: it comes back next time Draftpad opens.
// Never in the wing panels (they show the same page; the editor alone asks).

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

const pad = n => String(n).padStart(2, '0');
export function localDate(d) { return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`; }
export function localTime(d) { return `${pad(d.getHours())}:${pad(d.getMinutes())}`; }

/** The event the sheet's fields describe (local time, as the scanner reads dates). */
export function eventFromFields(base, f) {
  const [y, m, d] = String(f.date).split('-').map(Number);
  const at = (t, fallbackH) => {
    const [h, mi] = String(t || '').split(':').map(Number);
    return new Date(y, (m || 1) - 1, d || 1, Number.isFinite(h) ? h : fallbackH, Number.isFinite(mi) ? mi : 0);
  };
  const start = f.allDay ? new Date(y, m - 1, d) : at(f.start, 9);
  let end = f.allDay ? new Date(y, m - 1, d + 1) : at(f.end, start.getHours() + 1);
  if (end <= start) end = new Date(start.getTime() + 3_600_000);
  return {
    ...base,
    title: String(f.title || '').trim() || base.title,
    startISO: start.toISOString(),
    endISO: end.toISOString(),
    allDay: Boolean(f.allDay),
    location: String(f.location || '').trim(),
    notes: String(f.notes || '').trim()
  };
}

/** Which scanned events to offer: future, not added, not refused, not already offered this session. */
export function eventsToOffer(events, { dismissed, offered, now = Date.now() }) {
  return events.filter(ev => !ev.added && !dismissed.has(ev.id) && !offered.has(ev.id)
    && Date.parse(ev.endISO || ev.startISO) >= now);
}

export function createCalendarSheet({ layer, onAdd, onDismiss, now = () => Date.now() }) {
  const dismissed = new Set();
  const offered = new Set();
  const queue = [];
  let current = null;

  const scrim = el('div', 'rc-sheet-scrim rc-cal-scrim');
  scrim.hidden = true;
  const sheet = el('form', 'rc-sheet rc-cal-sheet');
  sheet.setAttribute('role', 'dialog');
  sheet.setAttribute('aria-label', 'New calendar event');
  scrim.appendChild(sheet);
  layer.appendChild(scrim);
  scrim.addEventListener('pointerdown', e => { if (e.target === scrim) later(); });
  sheet.addEventListener('keydown', e => { if (e.key === 'Escape') { e.preventDefault(); later(); } });

  function field(label, input) {
    const w = el('label', 'rc-cal-field');
    w.append(el('span', 'rc-cal-label', label), input);
    return w;
  }
  function input(type, value, cls = 'rc-library-input') {
    const i = el(type === 'textarea' ? 'textarea' : 'input', cls);
    if (type !== 'textarea') i.type = type;
    if (type === 'checkbox') i.checked = Boolean(value);
    else i.value = value ?? '';
    return i;
  }

  function render(ev) {
    sheet.innerHTML = '';
    const s = new Date(ev.startISO), e = new Date(ev.endISO || ev.startISO);
    const f = {
      title: input('text', ev.title),
      date: input('date', localDate(s)),
      start: input('time', localTime(s)),
      end: input('time', localTime(e)),
      allDay: input('checkbox', ev.allDay, 'rc-cal-check'),
      location: input('text', ev.location || ''),
      notes: input('textarea', ev.notes ?? ev.rawLine ?? '')
    };
    f.notes.rows = 3;
    const times = el('div', 'rc-cal-row');
    times.append(field('Starts', f.start), field('Ends', f.end));
    const syncAllDay = () => { times.hidden = f.allDay.checked; };
    f.allDay.addEventListener('change', syncAllDay);
    syncAllDay();

    const head = el('div', 'rc-sheet-head');
    head.append(el('span', 'rc-sheet-title', 'New event from your note'));
    const from = el('p', 'rc-cal-from', ev.rawLine ? `“${ev.rawLine.trim()}”` : '');
    const allDay = el('label', 'rc-cal-allday');
    allDay.append(f.allDay, el('span', '', 'All day'));
    const buttons = el('div', 'rc-cal-buttons');
    const no = el('button', 'rc-library-details', 'Don’t add');
    no.type = 'button';
    const yes = el('button', 'rc-library-listen', 'Add to Calendar');
    yes.type = 'submit';
    buttons.append(no, yes);
    no.addEventListener('click', () => { dismissed.add(ev.id); onDismiss?.(ev.id); next(); });
    sheet.onsubmit = e => {
      e.preventDefault();
      onAdd?.(eventFromFields(ev, {
        title: f.title.value, date: f.date.value, start: f.start.value, end: f.end.value,
        allDay: f.allDay.checked, location: f.location.value, notes: f.notes.value
      }));
      next();
    };
    sheet.append(el('div', 'rc-sheet-grabber'), head, from, field('Title', f.title), field('Day', f.date), allDay, times,
      field('Place', f.location), field('Notes', f.notes), buttons);
    if (queue.length) sheet.append(el('p', 'rc-cal-more', `${queue.length} more after this`));
  }

  function next() {
    current = queue.shift() || null;
    if (!current) { scrim.hidden = true; return; }
    render(current);
    scrim.hidden = false;
  }
  function later() {
    if (current) offered.delete(current.id);
    for (const q of queue) offered.delete(q.id);
    queue.length = 0;
    current = null;
    scrim.hidden = true;
  }

  /** New scan results: queue the events worth asking about; open the sheet if it's closed. */
  function offer(events) {
    for (const ev of eventsToOffer(events, { dismissed, offered, now: now() })) {
      offered.add(ev.id);
      queue.push(ev);
    }
    if (!current) next();
  }

  function setDismissed(ids) { for (const id of ids) dismissed.add(id); }

  return { offer, setDismissed, isOpen: () => Boolean(current), close: later };
}
