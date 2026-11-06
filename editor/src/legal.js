import { EditorState, StateField } from '@codemirror/state';
import { Decoration, EditorView, keymap } from '@codemirror/view';
import { moveLineUp, moveLineDown } from '@codemirror/commands';
import { PAGE_MARKER } from './pages.js';
import { externalSetTextAnnotation } from './bridge.js';

const INDENTS = ['', '   ', '      ', '         '];

const ROMAN_VALUES = [
  ['m', 1000], ['cm', 900], ['d', 500], ['cd', 400],
  ['c', 100], ['xc', 90], ['l', 50], ['xl', 40],
  ['x', 10], ['ix', 9], ['v', 5], ['iv', 4], ['i', 1]
];

const ROMAN_VALID_RE = /^m{0,3}(cm|cd|d?c{0,3})(xc|xl|l?x{0,3})(ix|iv|v?i{0,3})$/i;

export function toRoman(num) {
  let n = Math.max(1, Math.floor(num));
  let out = '';
  for (const [sym, val] of ROMAN_VALUES) {
    while (n >= val) {
      out += sym;
      n -= val;
    }
  }
  return out;
}

export function fromRoman(str) {
  if (typeof str !== 'string' || !str.trim()) return null;
  const s = str.trim().toLowerCase();
  if (!ROMAN_VALID_RE.test(s)) return null;
  let i = 0;
  let total = 0;
  for (const [sym, val] of ROMAN_VALUES) {
    while (s.startsWith(sym, i)) {
      total += val;
      i += sym.length;
    }
  }
  return total > 0 ? total : null;
}

export function toAlpha(num) {
  let n = Math.max(1, Math.floor(num));
  let out = '';
  while (n > 0) {
    n--;
    out = String.fromCharCode(97 + (n % 26)) + out;
    n = Math.floor(n / 26);
  }
  return out;
}

export function fromAlpha(str) {
  if (typeof str !== 'string' || !/^[a-z]+$/i.test(str.trim())) return null;
  const s = str.trim().toLowerCase();
  let n = 0;
  for (let i = 0; i < s.length; i++) {
    n = n * 26 + (s.charCodeAt(i) - 96);
  }
  return n;
}

const DECIMAL_ITEM_RE = /^(\s*)(\d+)\.(\d+)(\s+)(.*)$/;
const TOP_ITEM_RE = /^(\s*)(\d+)\.(\s+)(.*)$/;
const PAREN_ITEM_RE = /^(\s*)\(([a-z]+)\)(\s+)(.*)$/i;

function splitLineCR(line) {
  if (typeof line === 'string' && line.endsWith('\r')) {
    return { clean: line.slice(0, -1), cr: '\r' };
  }
  return { clean: typeof line === 'string' ? line : '', cr: '' };
}

function classifyParenToken(indent, tokenRaw, prevItem) {
  const token = tokenRaw.toLowerCase();
  const upper = tokenRaw === tokenRaw.toUpperCase();
  const romanVal = fromRoman(token);
  const alphaVal = fromAlpha(token);

  let isRoman = false;
  if (romanVal !== null) {
    if (token.length > 1) {
      isRoman = true;
    } else if (upper && (token === 'i' || token === 'v' || token === 'x')) {
      isRoman = true;
    } else if (prevItem && prevItem.level === 3) {
      if (
        indent.length >= prevItem.indent.length ||
        romanVal === prevItem.rawIndex + 1 ||
        romanVal === prevItem.index + 1
      ) {
        isRoman = true;
      }
    } else if (prevItem && prevItem.level === 2) {
      if (token === 'i') {
        const prevNearH =
          prevItem.rawIndex === 8 ||
          prevItem.index === 8 ||
          prevItem.rawIndex === 7 ||
          prevItem.index === 7;
        isRoman = !(prevNearH && indent.length <= prevItem.indent.length);
      } else {
        isRoman = false;
      }
    } else if (token === 'i') {
      isRoman = true;
    }
  }

  return { token, upper, romanVal, alphaVal, isRoman };
}

/**
 * Parses a single line as a legal numbered item (`1.`, `1.1`, `(a)`, `(i)`).
 * Leaves prose numbers, years (`1990.`), decimals (`1.5 hours`), and isolated
 * statutory/cross-reference citations (`(c) of the statute`, `(v) supra`) alone.
 * Decides ambiguous `(i)` from the item before it and preserves Roman numeral case.
 */
export function parseLegalItem(lineText, prevItem = null, nextLineText = null) {
  if (typeof lineText !== 'string') return null;
  const { clean, cr } = splitLineCR(lineText);

  let m = DECIMAL_ITEM_RE.exec(clean);
  if (m) {
    const [, indent, majorStr, minorStr, space, body] = m;
    const major = Number(majorStr);
    const minor = Number(minorStr);
    if (major <= 0 || major >= 100 || minor <= 0 || minor >= 100) {
      return null;
    }

    let nextMatchesSameMajor = false;
    if (typeof nextLineText === 'string') {
      const nextClean = splitLineCR(nextLineText).clean;
      const nm = DECIMAL_ITEM_RE.exec(nextClean);
      if (nm && Number(nm[2]) === major) {
        nextMatchesSameMajor = true;
      }
    }

    const inListContext =
      indent.length > 0 ||
      minor === 1 ||
      (prevItem !== null && (prevItem.major === major || prevItem.level <= 1)) ||
      nextMatchesSameMajor;

    if (!inListContext) {
      return null;
    }

    return {
      level: 1,
      style: '1.1',
      upper: false,
      indent,
      major,
      index: minor,
      rawIndex: minor,
      rawToken: `${majorStr}.${minorStr}`,
      marker: `${majorStr}.${minorStr}`,
      space,
      body,
      cr
    };
  }

  m = TOP_ITEM_RE.exec(clean);
  if (m) {
    const [, indent, numStr, space, body] = m;
    const num = Number(numStr);
    const followsPrevTop =
      prevItem &&
      prevItem.level === 0 &&
      (prevItem.rawIndex === num - 1 || prevItem.index === num - 1);
    if (num <= 0 || (num >= 100 && !followsPrevTop)) {
      return null;
    }
    return {
      level: 0,
      style: '1.',
      upper: false,
      indent,
      major: num,
      index: num,
      rawIndex: num,
      rawToken: numStr,
      marker: `${numStr}.`,
      space,
      body,
      cr
    };
  }

  m = PAREN_ITEM_RE.exec(clean);
  if (m) {
    const [, indent, tokenRaw, space, body] = m;
    const { token, upper, romanVal, alphaVal, isRoman } = classifyParenToken(
      indent,
      tokenRaw,
      prevItem
    );

    const level = isRoman ? 3 : 2;
    const indexVal = isRoman ? romanVal : alphaVal;
    if (indexVal === null) return null;

    // Standalone unindented parenthesized tokens with index > 2 (e.g. `(c) of the statute`,
    // `(v) supra / (x) infra`) are prose unless they start a consecutive sequence like `(h)/(i)/(j)`.
    if (indent.length === 0 && !prevItem && indexVal > 2) {
      let hasConsecutiveNext = false;
      if (typeof nextLineText === 'string') {
        const nextClean = splitLineCR(nextLineText).clean;
        const nm = PAREN_ITEM_RE.exec(nextClean);
        if (nm) {
          const fakePrev = {
            level,
            indent,
            major: 1,
            index: indexVal,
            rawIndex: indexVal
          };
          const nextClass = classifyParenToken(nm[1], nm[2], fakePrev);
          const nextLevel = nextClass.isRoman ? 3 : 2;
          const nextIdx = nextClass.isRoman ? nextClass.romanVal : nextClass.alphaVal;
          if (nextLevel === level && nextIdx === indexVal + 1) {
            hasConsecutiveNext = true;
          }
        }
      }
      if (!hasConsecutiveNext) {
        return null;
      }
    }

    const formattedToken = upper ? token.toUpperCase() : token;
    return {
      level,
      style: isRoman ? (upper ? '(I)' : '(i)') : (upper ? '(A)' : '(a)'),
      upper,
      indent,
      major: prevItem ? prevItem.major : 1,
      index: indexVal,
      rawIndex: indexVal,
      rawToken: tokenRaw,
      marker: `(${formattedToken})`,
      space,
      body,
      cr
    };
  }

  return null;
}

export function formatLegalMarker(level, counters, options = {}) {
  const [c0, c1, c2, c3] = counters;
  const upper = Boolean(options.upper);
  switch (level) {
    case 0:
      return `${Math.max(1, c0)}.`;
    case 1:
      return `${Math.max(1, c0)}.${Math.max(1, c1)}`;
    case 2: {
      const a = toAlpha(Math.max(1, c2));
      return `(${upper ? a.toUpperCase() : a})`;
    }
    case 3:
    default: {
      const r = toRoman(Math.max(1, c3));
      return `(${upper ? r.toUpperCase() : r})`;
    }
  }
}

export function formatLegalLine(level, counters, body = '', customIndent = null, options = {}) {
  const indent = customIndent !== null ? customIndent : INDENTS[Math.max(0, Math.min(3, level))];
  const marker = formatLegalMarker(level, counters, options);
  const cr = options.cr || '';
  return `${indent}${marker} ${body}${cr}`;
}

export function isSectionHeadingLine(lineText) {
  if (typeof lineText !== 'string') return false;
  const { clean } = splitLineCR(lineText);
  return /^§\s+\S/.test(clean);
}

/**
 * Renumbers legal list items in `text` sequentially (`1.`, `1.1`, `(a)`, `(i)`),
 * while leaving non-list numbers, years, decimals, and prose citations untouched,
 * preserving Roman numeral case and CRLF line endings.
 */
export function renumberLegalLists(text) {
  const source = typeof text === 'string' ? text : '';
  const lines = source.split('\n');
  let counters = [0, 0, 0, 0];
  let prevItem = null;
  let sawBlankLine = false;

  const out = lines.map((line, i) => {
    const { clean } = splitLineCR(line);
    const trimmed = clean.trim();

    if (trimmed === '') {
      sawBlankLine = true;
      prevItem = null;
      return line;
    }

    if (trimmed === PAGE_MARKER || /^#{1,6}\s+/.test(trimmed) || /^§\s+/.test(trimmed)) {
      counters = [0, 0, 0, 0];
      prevItem = null;
      sawBlankLine = false;
      return line;
    }

    const nextLine = i + 1 < lines.length ? lines[i + 1] : null;
    const parsed = parseLegalItem(line, prevItem, nextLine);
    if (!parsed) {
      counters = [0, 0, 0, 0];
      prevItem = null;
      sawBlankLine = false;
      return line;
    }

    const lvl = parsed.level;
    if (lvl === 0) {
      if (sawBlankLine && parsed.rawIndex === 1) {
        counters[0] = 1;
      } else {
        counters[0] += 1;
      }
      counters[1] = 0;
      counters[2] = 0;
      counters[3] = 0;
    } else if (lvl === 1) {
      if (counters[0] === 0) counters[0] = parsed.major > 0 ? parsed.major : 1;
      counters[1] += 1;
      counters[2] = 0;
      counters[3] = 0;
    } else if (lvl === 2) {
      const noParent = counters[0] === 0 && counters[1] === 0 && !prevItem;
      if (counters[0] === 0) counters[0] = 1;
      if (counters[1] === 0) counters[1] = 1;
      if (noParent && counters[2] === 0 && parsed.rawIndex > 2) {
        counters[2] = parsed.rawIndex;
      } else {
        counters[2] += 1;
      }
      counters[3] = 0;
    } else {
      const noParent = counters[0] === 0 && counters[1] === 0 && counters[2] === 0 && !prevItem;
      if (counters[0] === 0) counters[0] = 1;
      if (counters[1] === 0) counters[1] = 1;
      if (counters[2] === 0) counters[2] = 1;
      if (noParent && counters[3] === 0 && parsed.rawIndex > 2) {
        counters[3] = parsed.rawIndex;
      } else {
        counters[3] += 1;
      }
    }

    sawBlankLine = false;
    const marker = formatLegalMarker(lvl, counters, { upper: parsed.upper });
    prevItem = {
      ...parsed,
      major: counters[0],
      index: counters[lvl],
      rawIndex: parsed.rawIndex,
      marker
    };

    return `${parsed.indent}${marker}${parsed.space}${parsed.body}${parsed.cr}`;
  });

  return out.join('\n');
}

function isPotentialListLine(lineText) {
  if (typeof lineText !== 'string') return false;
  const { clean } = splitLineCR(lineText);
  const trimmed = clean.trim();
  if (
    trimmed === '' ||
    trimmed === PAGE_MARKER ||
    /^#{1,6}\s+/.test(trimmed) ||
    /^§\s+/.test(trimmed)
  ) {
    return false;
  }
  return (
    DECIMAL_ITEM_RE.test(clean) ||
    TOP_ITEM_RE.test(clean) ||
    PAREN_ITEM_RE.test(clean)
  );
}

/**
 * Finds the `[start, end]` line index bounds of the contiguous list block
 * containing `targetLineIdx`, or `null` if `targetLineIdx` is not in a list block.
 */
export function findListBlockBounds(lines, targetLineIdx) {
  if (targetLineIdx < 0 || targetLineIdx >= lines.length) return null;
  if (!isPotentialListLine(lines[targetLineIdx])) return null;

  let start = targetLineIdx;
  while (start > 0 && isPotentialListLine(lines[start - 1])) {
    start--;
  }
  let end = targetLineIdx;
  while (end + 1 < lines.length && isPotentialListLine(lines[end + 1])) {
    end++;
  }
  return { start, end };
}

/**
 * Renumbers ONLY the contiguous list block holding `targetLineIdx`,
 * leaving every other line in `text` untouched.
 */
export function renumberListBlockAtLine(text, targetLineIdx) {
  const source = typeof text === 'string' ? text : '';
  const lines = source.split('\n');
  let bounds = findListBlockBounds(lines, targetLineIdx);
  if (!bounds && targetLineIdx > 0) {
    bounds = findListBlockBounds(lines, targetLineIdx - 1);
  }
  if (!bounds) return source;

  const blockText = lines.slice(bounds.start, bounds.end + 1).join('\n');
  const renumberedBlock = renumberLegalLists(blockText).split('\n');
  const nextLines = [...lines];
  nextLines.splice(
    bounds.start,
    bounds.end - bounds.start + 1,
    ...renumberedBlock
  );
  return nextLines.join('\n');
}

/**
 * Computes the minimal single-range change `{ from, to, insert }` between `oldText` and `newText`,
 * or `null` if they are identical.
 */
export function computeMinimalTextChange(oldText, newText) {
  if (oldText === newText) return null;
  let from = 0;
  const minLen = Math.min(oldText.length, newText.length);
  while (from < minLen && oldText.charCodeAt(from) === newText.charCodeAt(from)) {
    from++;
  }
  let oldTo = oldText.length;
  let newTo = newText.length;
  while (
    oldTo > from &&
    newTo > from &&
    oldText.charCodeAt(oldTo - 1) === newText.charCodeAt(newTo - 1)
  ) {
    oldTo--;
    newTo--;
  }
  return {
    from,
    to: oldTo,
    insert: newText.slice(from, newTo)
  };
}

/**
 * Computes the counters `[c0, c1, c2, c3]` within the contiguous list block up to `targetLineIndex`.
 */
function computeContextAtLine(lines, targetLineIndex) {
  const bounds = findListBlockBounds(lines, targetLineIndex);
  if (!bounds) return { counters: [0, 0, 0, 0], parsedTarget: null, bounds: null };

  let counters = [0, 0, 0, 0];
  let prevItem = null;
  let parsedTarget = null;

  for (let i = bounds.start; i <= targetLineIndex && i <= bounds.end; i++) {
    const line = lines[i];
    const nextLine = i + 1 <= bounds.end ? lines[i + 1] : null;
    const parsed = parseLegalItem(line, prevItem, nextLine);
    if (!parsed) {
      counters = [0, 0, 0, 0];
      prevItem = null;
      continue;
    }

    const lvl = parsed.level;
    if (lvl === 0) {
      counters[0] += 1;
      counters[1] = 0;
      counters[2] = 0;
      counters[3] = 0;
    } else if (lvl === 1) {
      if (counters[0] === 0) counters[0] = parsed.major > 0 ? parsed.major : 1;
      counters[1] += 1;
      counters[2] = 0;
      counters[3] = 0;
    } else if (lvl === 2) {
      const noParent = counters[0] === 0 && counters[1] === 0 && !prevItem;
      if (counters[0] === 0) counters[0] = 1;
      if (counters[1] === 0) counters[1] = 1;
      if (noParent && counters[2] === 0 && parsed.rawIndex > 2) {
        counters[2] = parsed.rawIndex;
      } else {
        counters[2] += 1;
      }
      counters[3] = 0;
    } else {
      const noParent = counters[0] === 0 && counters[1] === 0 && counters[2] === 0 && !prevItem;
      if (counters[0] === 0) counters[0] = 1;
      if (counters[1] === 0) counters[1] = 1;
      if (counters[2] === 0) counters[2] = 1;
      if (noParent && counters[3] === 0 && parsed.rawIndex > 2) {
        counters[3] = parsed.rawIndex;
      } else {
        counters[3] += 1;
      }
    }

    prevItem = {
      ...parsed,
      major: counters[0],
      index: counters[lvl],
      rawIndex: parsed.rawIndex
    };
    if (i === targetLineIndex) {
      parsedTarget = prevItem;
    }
  }

  return { counters, parsedTarget, bounds };
}

/**
 * Pure helper: continues a legal numbered item when Enter is pressed at `cursorOffset`.
 * Renumbers ONLY the contiguous list holding the cursor.
 */
export function continueLegalOnEnter(text, cursorOffset) {
  const source = typeof text === 'string' ? text : '';
  const pos = Math.max(0, Math.min(source.length, cursorOffset));
  const lines = source.split('\n');

  let offset = 0;
  let lineIdx = 0;
  for (let i = 0; i < lines.length; i++) {
    const end = offset + lines[i].length;
    if (pos >= offset && pos <= end) {
      lineIdx = i;
      break;
    }
    offset = end + 1;
  }

  const { counters, parsedTarget, bounds } = computeContextAtLine(lines, lineIdx);
  if (!parsedTarget || !bounds) return null;

  const lineStart = offset;
  const lineText = lines[lineIdx];
  const cleanLen = lineText.length - parsedTarget.cr.length;
  const prefixLen = parsedTarget.indent.length + parsedTarget.marker.length + parsedTarget.space.length;
  const bodyStart = lineStart + prefixLen;

  // If the item has no body text, pressing Enter clears the empty marker on this line
  if (parsedTarget.body.trim() === '') {
    const newLines = [...lines];
    newLines[lineIdx] = parsedTarget.cr;
    let nextDoc = newLines.join('\n');
    if (lineIdx > bounds.start) {
      nextDoc = renumberListBlockAtLine(nextDoc, lineIdx - 1);
    }
    if (lineIdx < bounds.end) {
      nextDoc = renumberListBlockAtLine(nextDoc, lineIdx + 1);
    }
    return {
      text: nextDoc,
      cursor: lineStart
    };
  }

  const clampedPos = Math.min(pos, lineStart + cleanLen);
  const splitAt = Math.max(bodyStart, clampedPos);
  const keptOnCurrentLine = `${source.slice(lineStart, splitAt)}${parsedTarget.cr}`;
  const movedToNextLine = source.slice(splitAt, lineStart + cleanLen);

  const nextCounters = [...counters];
  nextCounters[parsedTarget.level] += 1;
  for (let k = parsedTarget.level + 1; k < 4; k++) nextCounters[k] = 0;

  const nextMarker = formatLegalMarker(parsedTarget.level, nextCounters, {
    upper: parsedTarget.upper
  });
  const insertedPrefix = `${parsedTarget.indent}${nextMarker} `;
  const newLines = [...lines];
  newLines.splice(
    lineIdx,
    1,
    keptOnCurrentLine,
    `${insertedPrefix}${movedToNextLine}${parsedTarget.cr}`
  );

  const renumbered = renumberListBlockAtLine(newLines.join('\n'), lineIdx + 1);
  const renumberedLines = renumbered.split('\n');
  let newCursor = 0;
  for (let i = 0; i <= lineIdx; i++) {
    newCursor += renumberedLines[i].length + 1;
  }
  const nextParsed = parseLegalItem(
    renumberedLines[lineIdx + 1],
    parsedTarget,
    lineIdx + 2 < renumberedLines.length ? renumberedLines[lineIdx + 2] : null
  );
  if (nextParsed) {
    newCursor += nextParsed.indent.length + nextParsed.marker.length + nextParsed.space.length;
  } else {
    newCursor += insertedPrefix.length;
  }

  return {
    text: renumbered,
    cursor: newCursor
  };
}

/**
 * Pure helper: promotes (`delta = -1`) or demotes (`delta = +1`) the legal item on
 * the line containing `cursorOffset` through `1.` <-> `1.1` <-> `(a)` <-> `(i)`,
 * then renumbers ONLY the contiguous list holding the cursor.
 */
export function shiftLegalLevelAtCursor(text, cursorOffset, delta) {
  const source = typeof text === 'string' ? text : '';
  const pos = Math.max(0, Math.min(source.length, cursorOffset));
  const lines = source.split('\n');

  let offset = 0;
  let lineIdx = 0;
  for (let i = 0; i < lines.length; i++) {
    const end = offset + lines[i].length;
    if (pos >= offset && pos <= end) {
      lineIdx = i;
      break;
    }
    offset = end + 1;
  }

  const { counters, parsedTarget } = computeContextAtLine(lines, lineIdx);
  if (!parsedTarget) return null;

  const offsetInLine = pos - offset;
  const oldPrefixLen = parsedTarget.indent.length + parsedTarget.marker.length + parsedTarget.space.length;
  const bodyOffset = Math.max(0, offsetInLine - oldPrefixLen);

  const targetLevel = Math.max(0, Math.min(3, parsedTarget.level + (delta > 0 ? 1 : -1)));
  if (targetLevel === parsedTarget.level) {
    return { text: source, cursor: pos };
  }

  const tempCounters = [
    Math.max(1, counters[0]),
    Math.max(1, counters[1]),
    Math.max(1, counters[2]),
    Math.max(1, counters[3])
  ];
  lines[lineIdx] = formatLegalLine(targetLevel, tempCounters, parsedTarget.body, null, {
    upper: parsedTarget.upper,
    cr: parsedTarget.cr
  });

  const renumbered = renumberListBlockAtLine(lines.join('\n'), lineIdx);
  const renumberedLines = renumbered.split('\n');
  let newLineStart = 0;
  for (let i = 0; i < lineIdx; i++) {
    newLineStart += renumberedLines[i].length + 1;
  }
  const prevLineParsed =
    lineIdx > 0 ? parseLegalItem(renumberedLines[lineIdx - 1]) : null;
  const updatedParsed = parseLegalItem(renumberedLines[lineIdx], prevLineParsed);
  const newPrefixLen = updatedParsed
    ? updatedParsed.indent.length + updatedParsed.marker.length + updatedParsed.space.length
    : INDENTS[targetLevel].length + formatLegalMarker(targetLevel, tempCounters).length + 1;

  const lineCleanLen = splitLineCR(renumberedLines[lineIdx]).clean.length;
  return {
    text: renumbered,
    cursor: Math.min(
      newLineStart + lineCleanLen,
      newLineStart + newPrefixLen + bodyOffset
    )
  };
}

const sectionHeadingLineDeco = Decoration.line({
  attributes: {
    class: 'cm-section-heading-line'
  }
});

function buildSectionDecorations(doc) {
  const items = [];
  for (let i = 1; i <= doc.lines; i++) {
    const line = doc.line(i);
    if (isSectionHeadingLine(line.text)) {
      items.push(sectionHeadingLineDeco.range(line.from));
    }
  }
  return Decoration.set(items, true);
}

const sectionHeadingField = StateField.define({
  create(state) {
    return buildSectionDecorations(state.doc);
  },
  update(decos, tr) {
    if (!tr.docChanged) return decos;
    return buildSectionDecorations(tr.state.doc);
  },
  provide: f => EditorView.decorations.from(f)
});

function applyPureEdit(view, result) {
  if (!result) return false;
  const current = view.state.doc.toString();
  const change = computeMinimalTextChange(current, result.text);
  if (!change && result.cursor === view.state.selection.main.head) {
    return true;
  }
  view.dispatch({
    ...(change ? { changes: change } : {}),
    selection: { anchor: result.cursor }
  });
  return true;
}

function renumberListAtCursorView(view) {
  const cur = view.state.doc.toString();
  const cursorLineIdx = view.state.doc.lineAt(view.state.selection.main.head).number - 1;
  const renumbered = renumberListBlockAtLine(cur, cursorLineIdx);
  const change = computeMinimalTextChange(cur, renumbered);
  if (change) {
    view.dispatch({
      changes: change,
      selection: view.state.selection
    });
  }
}

/**
 * Automatically renumbers ONLY the contiguous legal list holding the cursor
 * when a line inside that list is deleted. Never triggers on load, setText,
 * typing, or paste.
 */
const legalRenumberFilter = EditorState.transactionFilter.of(tr => {
  if (!tr.docChanged || tr.annotation(externalSetTextAnnotation)) return tr;
  if (
    tr.isUserEvent('input') ||
    tr.isUserEvent('input.type') ||
    tr.isUserEvent('input.paste') ||
    tr.isUserEvent('undo') ||
    tr.isUserEvent('redo')
  ) {
    return tr;
  }

  let hasPureLineDeletion = false;
  let hasInsertion = false;
  let deletedListLine = false;
  let deletionPosB = 0;

  tr.changes.iterChanges((fromA, toA, fromB, toB, inserted) => {
    if (inserted.length > 0) {
      hasInsertion = true;
      return;
    }
    if (toA > fromA) {
      const removedText = tr.startState.doc.sliceString(fromA, toA);
      if (removedText.includes('\n')) {
        hasPureLineDeletion = true;
        deletionPosB = fromB;
        const removedLines = removedText.split('\n');
        if (removedLines.some(l => isPotentialListLine(l))) {
          deletedListLine = true;
        }
      }
    }
  });

  if (hasInsertion || !hasPureLineDeletion || !deletedListLine) {
    return tr;
  }

  const newDocText = tr.newDoc.toString();
  const clampedPos = Math.max(0, Math.min(tr.newDoc.length, deletionPosB));
  const targetLineIdx = tr.newDoc.lineAt(clampedPos).number - 1;
  const renumbered = renumberListBlockAtLine(newDocText, targetLineIdx);
  const change = computeMinimalTextChange(newDocText, renumbered);
  if (!change) return tr;

  const head = Math.min(renumbered.length, tr.newSelection.main.head);
  return [
    tr,
    {
      changes: change,
      selection: { anchor: head },
      sequential: true
    }
  ];
});

export function legalNumberingExtension() {
  return [
    sectionHeadingField,
    legalRenumberFilter,
    keymap.of([
      {
        key: 'Enter',
        run(view) {
          const pos = view.state.selection.main.head;
          const res = continueLegalOnEnter(view.state.doc.toString(), pos);
          return applyPureEdit(view, res);
        }
      },
      {
        key: 'Tab',
        run(view) {
          const pos = view.state.selection.main.head;
          const res = shiftLegalLevelAtCursor(view.state.doc.toString(), pos, +1);
          return applyPureEdit(view, res);
        }
      },
      {
        key: 'Shift-Tab',
        run(view) {
          const pos = view.state.selection.main.head;
          const res = shiftLegalLevelAtCursor(view.state.doc.toString(), pos, -1);
          return applyPureEdit(view, res);
        }
      },
      {
        key: 'Alt-ArrowUp',
        run(view) {
          const moved = moveLineUp(view);
          if (!moved) return false;
          renumberListAtCursorView(view);
          return true;
        }
      },
      {
        key: 'Alt-ArrowDown',
        run(view) {
          const moved = moveLineDown(view);
          if (!moved) return false;
          renumberListAtCursorView(view);
          return true;
        }
      }
    ])
  ];
}
