import { foldService, codeFolding, foldGutter, foldEffect, unfoldEffect, foldedRanges } from '@codemirror/language';
import { EditorView } from '@codemirror/view';
import { PAGE_MARKER, inspectDraftpadPages } from './pages.js';

const ATX_HEADING_RE = /^(#{1,6})\s+(.+?)\s*$/;
const SECTION_HEADING_RE = /^§\s+(.+?)\s*$/;

/**
 * Parses a single line to determine if it is a Markdown ATX heading (`#`..`######`)
 * or a legal section heading (`§ ...`).
 */
export function parseHeadingLine(lineText) {
  if (typeof lineText !== 'string') return null;
  const trimmedRight = lineText.replace(/\s+$/, '');
  const sec = SECTION_HEADING_RE.exec(trimmedRight);
  if (sec) {
    return {
      kind: 'section',
      level: 1,
      marker: '§',
      title: sec[1].trim()
    };
  }
  const atx = ATX_HEADING_RE.exec(trimmedRight);
  if (atx) {
    return {
      kind: 'atx',
      level: atx[1].length,
      marker: atx[1],
      title: atx[2].trim()
    };
  }
  return null;
}

/**
 * Extracts all headings (`#`..`######` and `§ `) from a document, along with
 * their page index and foldable range `[foldFrom, foldTo]` (stopping before the
 * next heading of equal/higher rank or the next `<!-- page -->` divider).
 */
export function extractHeadings(text) {
  const source = typeof text === 'string' ? text : '';
  const lines = source.split('\n');
  const lineOffsets = [];
  let offset = 0;
  for (let i = 0; i < lines.length; i++) {
    lineOffsets.push({
      lineNumber: i + 1,
      from: offset,
      to: offset + lines[i].length,
      text: lines[i]
    });
    offset += lines[i].length + 1;
  }

  const rawHeadings = [];
  let pageIndex = 0;
  for (let i = 0; i < lineOffsets.length; i++) {
    const info = lineOffsets[i];
    if (info.text === PAGE_MARKER) {
      pageIndex++;
      continue;
    }
    const parsed = parseHeadingLine(info.text);
    if (parsed) {
      rawHeadings.push({
        ...parsed,
        lineIndex: i,
        lineNumber: info.lineNumber,
        from: info.from,
        to: info.to,
        pageIndex
      });
    }
  }

  return rawHeadings.map((h, idx) => {
    let endLineIndex = lines.length - 1;
    for (let k = h.lineIndex + 1; k < lines.length; k++) {
      if (lines[k] === PAGE_MARKER) {
        endLineIndex = k - 1;
        break;
      }
      const nextParsed = parseHeadingLine(lines[k]);
      if (nextParsed && nextParsed.level <= h.level) {
        endLineIndex = k - 1;
        break;
      }
    }
    while (endLineIndex > h.lineIndex && lines[endLineIndex].trim() === '') {
      endLineIndex--;
    }
    const canFold = endLineIndex > h.lineIndex;
    const foldFrom = canFold ? h.to : null;
    const foldTo = canFold ? lineOffsets[endLineIndex].to : null;
    return {
      id: `heading-${idx}-${h.from}`,
      kind: h.kind,
      level: h.level,
      marker: h.marker,
      title: h.title,
      lineNumber: h.lineNumber,
      from: h.from,
      to: h.to,
      pageIndex: h.pageIndex,
      foldFrom,
      foldTo
    };
  });
}

/**
 * Computes the `{ from, to }` fold range for the heading starting on the line
 * containing `lineStartOffset`, or `null` if that line is not a foldable heading.
 */
export function computeHeadingFoldRange(text, lineStartOffset) {
  const headings = extractHeadings(text);
  const found = headings.find(h => h.from === lineStartOffset);
  if (!found || found.foldFrom === null || found.foldTo === null || found.foldTo <= found.foldFrom) {
    return null;
  }
  return { from: found.foldFrom, to: found.foldTo };
}

/**
 * Returns Draftpad pages for the Outline panel. When `newestFirst` is true,
 * pages are sorted by their opening date line (`dateMs` descending, newest at the top)
 * without mutating or reordering the underlying document string.
 */
export function orderPagesForOutline(text, { newestFirst = false } = {}) {
  const pages = inspectDraftpadPages(text);
  const headings = extractHeadings(text);
  const enriched = pages.map(p => ({
    ...p,
    headings: headings.filter(h => h.pageIndex === p.index)
  }));

  if (!newestFirst) {
    return enriched;
  }

  return [...enriched].sort((a, b) => {
    const aHas = a.dateMs !== null;
    const bHas = b.dateMs !== null;
    if (aHas && bHas && a.dateMs !== b.dateMs) {
      return b.dateMs - a.dateMs;
    }
    if (aHas !== bHas) {
      return aHas ? -1 : 1;
    }
    return a.index - b.index;
  });
}

/**
 * Checks whether a heading is currently folded in `state`.
 */
export function isHeadingFolded(state, heading) {
  if (!heading || heading.foldFrom === null || heading.foldTo === null) return false;
  let folded = false;
  const ranges = foldedRanges(state);
  ranges.between(heading.foldFrom, heading.foldTo, (from, to) => {
    if (from === heading.foldFrom && to === heading.foldTo) {
      folded = true;
    }
  });
  return folded;
}

/**
 * Toggles the fold state of `heading` in `view`.
 */
export function toggleHeadingFold(view, heading) {
  if (!heading || heading.foldFrom === null || heading.foldTo === null) return false;
  const currentlyFolded = isHeadingFolded(view.state, heading);
  view.dispatch({
    effects: currentlyFolded
      ? unfoldEffect.of({ from: heading.foldFrom, to: heading.foldTo })
      : foldEffect.of({ from: heading.foldFrom, to: heading.foldTo })
  });
  return !currentlyFolded;
}

/**
 * Moves cursor to `offset` and scrolls it into view.
 */
export function jumpToOffset(view, offset) {
  const clamped = Math.max(0, Math.min(view.state.doc.length, offset));
  view.dispatch({
    selection: { anchor: clamped },
    effects: EditorView.scrollIntoView(clamped, { y: 'start', yMargin: 24 })
  });
  view.focus();
}

export function headingFoldExtension() {
  const service = foldService.of((state, lineStart) => {
    return computeHeadingFoldRange(state.doc.toString(), lineStart);
  });
  return [
    service,
    codeFolding(),
    foldGutter({
      openText: '▾',
      closedText: '▸'
    })
  ];
}
