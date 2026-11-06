import { StateField } from '@codemirror/state';
import { Decoration, EditorView } from '@codemirror/view';

export const PAGE_MARKER = '<!-- page -->';
export const PAGE_JOINER = `\n\n${PAGE_MARKER}\n\n`;

const WEEKDAYS = new Set([
  'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'
]);

const MONTHS = new Map([
  ['January', 0], ['February', 1], ['March', 2], ['April', 3],
  ['May', 4], ['June', 5], ['July', 6], ['August', 7],
  ['September', 8], ['October', 9], ['November', 10], ['December', 11]
]);

const FULL_DATE_RE = /^([A-Za-z]+),\s+([A-Za-z]+)\s+(\d{1,2}),\s+(\d{4})$/;

/**
 * Parses a full-style date line such as "Friday, November 6, 2026".
 * Returns the UTC timestamp (ms) if valid, or null otherwise.
 */
export function parseDateLine(line) {
  if (typeof line !== 'string') return null;
  const trimmed = line.trim();
  const m = FULL_DATE_RE.exec(trimmed);
  if (!m) return null;
  const [, weekday, monthName, dayStr, yearStr] = m;
  if (!WEEKDAYS.has(weekday) || !MONTHS.has(monthName)) return null;
  const month = MONTHS.get(monthName);
  const day = Number(dayStr);
  const year = Number(yearStr);
  if (day < 1 || day > 31 || year < 1900 || year > 2200) return null;
  const dt = new Date(Date.UTC(year, month, day, 12, 0, 0));
  if (dt.getUTCFullYear() !== year || dt.getUTCMonth() !== month || dt.getUTCDate() !== day) {
    return null;
  }
  return dt.getTime();
}

export function isFullDateLine(line) {
  return parseDateLine(line) !== null;
}

/**
 * Splits a Draftpad document into pages without altering the underlying string.
 * Matches Draftpad's `parsePages` / `pageJoiner` (`\n\n<!-- page -->\n\n`) byte-for-byte
 * while recording exact character and line offsets in the full document.
 */
export function inspectDraftpadPages(text) {
  const source = typeof text === 'string' ? text : '';
  const parts = source.split(PAGE_MARKER);
  const pages = [];
  let cursor = 0;

  for (let i = 0; i < parts.length; i++) {
    const part = parts[i];
    let leadTrim = 0;
    let trailTrim = 0;
    if (i > 0) {
      while (
        leadTrim < part.length &&
        (part[leadTrim] === '\n' || part[leadTrim] === '\r')
      ) {
        leadTrim++;
      }
    }
    if (i < parts.length - 1) {
      while (
        trailTrim < part.length - leadTrim &&
        (part[part.length - 1 - trailTrim] === '\n' ||
          part[part.length - 1 - trailTrim] === '\r')
      ) {
        trailTrim++;
      }
    }

    const from = cursor + leadTrim;
    const to = cursor + part.length - trailTrim;
    const rawContent = source.slice(from, to);
    const startLine = source.slice(0, from).split('\n').length;
    const pageLines = rawContent.split('\n');
    const endLine = startLine + pageLines.length - 1;

    let firstNonEmptyLine = null;
    let firstNonEmptyLineNumber = startLine;
    for (let j = 0; j < pageLines.length; j++) {
      const candidate = pageLines[j].trim();
      if (candidate.length > 0) {
        firstNonEmptyLine = pageLines[j];
        firstNonEmptyLineNumber = startLine + j;
        break;
      }
    }

    const dateMs = firstNonEmptyLine !== null ? parseDateLine(firstNonEmptyLine) : null;
    pages.push({
      index: i,
      from,
      to,
      startLine,
      endLine,
      dateLine: dateMs !== null ? firstNonEmptyLine.trim() : null,
      dateLineNumber: dateMs !== null ? firstNonEmptyLineNumber : null,
      dateMs,
      title: dateMs !== null
        ? firstNonEmptyLine.trim()
        : (firstNonEmptyLine ? firstNonEmptyLine.trim().slice(0, 60) : `Page ${i + 1}`),
      rawContent
    });

    cursor += part.length + PAGE_MARKER.length;
  }

  return pages;
}

/**
 * Locates every `<!-- page -->` marker line and every page-opening full-style
 * date line in `text` for decoration without mutating the document text.
 */
export function findPageDecorations(text) {
  const source = typeof text === 'string' ? text : '';
  const lines = source.split('\n');
  const markers = [];
  const dateLines = [];
  let offset = 0;
  let awaitingPageFirstContentLine = true;

  for (let i = 0; i < lines.length; i++) {
    const rawLine = lines[i];
    const lineText = rawLine.endsWith('\r') ? rawLine.slice(0, -1) : rawLine;
    const from = offset;
    const to = offset + lineText.length;
    const lineNumber = i + 1;

    if (lineText === PAGE_MARKER) {
      markers.push({ from, to, lineNumber });
      awaitingPageFirstContentLine = true;
    } else if (awaitingPageFirstContentLine && lineText.trim().length > 0) {
      awaitingPageFirstContentLine = false;
      if (isFullDateLine(lineText)) {
        dateLines.push({ from, to, lineNumber, text: lineText.trim() });
      }
    }

    offset += rawLine.length + 1;
  }

  return { markers, dateLines };
}

const pageDividerLineDeco = Decoration.line({
  attributes: {
    class: 'cm-page-divider-line',
    'data-page-marker': 'true',
    'aria-label': 'Page break'
  }
});

const pageDateLineDeco = Decoration.line({
  attributes: {
    class: 'cm-page-date-line'
  }
});

function buildPageDecoSet(doc) {
  const text = doc.toString();
  const { markers, dateLines } = findPageDecorations(text);
  const items = [];
  for (const m of markers) {
    items.push(pageDividerLineDeco.range(m.from));
  }
  for (const d of dateLines) {
    items.push(pageDateLineDeco.range(d.from));
  }
  items.sort((a, b) => a.from - b.from);
  return Decoration.set(items, true);
}

const pageDecorationsField = StateField.define({
  create(state) {
    return buildPageDecoSet(state.doc);
  },
  update(decos, tr) {
    if (!tr.docChanged) return decos;
    return buildPageDecoSet(tr.state.doc);
  },
  provide: f => EditorView.decorations.from(f)
});

export function pageMarkersExtension() {
  return [pageDecorationsField];
}
