// The Chapters tab (the Outline, revamped; brief "Chapters in the section menu"). One list, two kinds:
// · your own headings (#, §, the page date): live, as you type;
// · recensed chapters for stretches without a heading: the title Gist wrote for that section, in italics with a small
//   mark, never written into the page (only "Make heading" does that).
// Titles are taken when the panel opens and held while it's open, so nothing changes under the eyes. Text not yet
// recensed shows as one entry per page, "New since HH:MM". Each entry: title, a dim one-line gist, listening time.
import { orderPagesForOutline } from './outline.js';
import { countWords } from './typedlines.js';
import { LISTEN_WPM } from './library.js';

export function listenLabel(words) {
  if (!words) return '';
  const min = words / LISTEN_WPM;
  return min < 1 ? '< 1 min' : `${Math.round(min)} min`;
}

const hhmm = ms => {
  const d = new Date(ms);
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
};

/**
 * Entries per page, in page order: [{page, entries:[{kind:'heading'|'recensed'|'new', title, gist, from, words,
 * listen, level, current, section}]}].
 * `sections`: docSections(text); `titles`: Map section key → {title, gist} as frozen when the panel opened;
 * `lastDone`: when recensing last finished (ms) or 0; `caret`: the cursor's offset.
 */
export function chapterEntries(text, { sections = [], titles = new Map(), lastDone = 0, caret = -1, newestFirst = false } = {}) {
  const out = [];
  for (const page of orderPagesForOutline(text, { newestFirst })) {
    const secs = sections.filter(s => s.pageIndex === page.index);
    const entries = [];
    for (const h of page.headings) {
      const under = secs.find(s => s.from === h.from);
      entries.push({ kind: 'heading', title: h.kind === 'section' ? `§ ${h.title}` : h.title, level: Math.min(2, h.level),
        from: h.from, gist: under ? titles.get(under.key)?.gist || '' : '', section: under || null, heading: h });
    }
    let fresh = null;
    for (const s of secs) {
      if (s.heading) continue;
      const t = titles.get(s.key);
      if (t?.title) entries.push({ kind: 'recensed', title: t.title, gist: t.gist || '', level: 1, from: s.from, section: s });
      else if (!fresh) fresh = s;
    }
    if (fresh) {
      entries.push({ kind: 'new', title: lastDone ? `New since ${hhmm(lastDone)}` : 'Not recensed yet', gist: '',
        level: 1, from: fresh.from, section: fresh });
    }
    entries.sort((a, b) => a.from - b.from || (a.kind === 'new') - (b.kind === 'new'));
    // Listening time: from this entry to the next one (or the page's end).
    entries.forEach((e, i) => {
      const end = i + 1 < entries.length ? entries[i + 1].from : page.to;
      e.words = countWords(text.slice(e.from, Math.max(e.from, end)));
      e.listen = listenLabel(e.words);
    });
    if (caret >= page.from && caret <= page.to) {
      const cur = [...entries].reverse().find(e => e.from <= caret);
      if (cur) cur.current = true;
    }
    out.push({ page, entries });
  }
  return out;
}

/** The text of a heading made from a recensed chapter, written at the section's start. */
export function headingInsert(title) {
  return `# ${String(title).replace(/\s+/g, ' ').trim()}\n\n`;
}
