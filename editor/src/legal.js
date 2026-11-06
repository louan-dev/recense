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

/**
 * Parses a single line as a legal numbered item (`1.`, `1.1`, `(a)`, `(i)`).
 * Uses `prevItem` and indentation to disambiguate `(i)` between level 2 (`(a)`) and level 3 (`(i)`).
 */
export function parseLegalItem(lineText, prevItem = null) {
  if (typeof lineText !== 'string') return null;

  let m = DECIMAL_ITEM_RE.exec(lineText);
  if (m) {
    const [, indent, majorStr, minorStr, space, body] = m;
    return {
      level: 1,
      style: '1.1',
      indent,
      major: Number(majorStr),
      index: Number(minorStr),
      marker: `${majorStr}.${minorStr}`,
      space,
      body
    };
  }

  m = TOP_ITEM_RE.exec(lineText);
  if (m) {
    const [, indent, numStr, space, body] = m;
    return {
      level: 0,
      style: '1.',
      indent,
      major: Number(numStr),
      index: Number(numStr),
      marker: `${numStr}.`,
      space,
      body
    };
  }

  m = PAREN_ITEM_RE.exec(lineText);
  if (m) {
    const [, indent, tokenRaw, space, body] = m;
    const token = tokenRaw.toLowerCase();
    const romanVal = fromRoman(token);
    const alphaVal = fromAlpha(token);

    let isRoman = false;
    if (romanVal !== null) {
      if (token.length > 1) {
        isRoman = true;
      } else if (indent.length >= 8) {
        isRoman = true;
      } else if (prevItem && prevItem.level === 3) {
        isRoman = true;
      } else if (token === 'i') {
        // `(i)` is Roman numeral 1 unless it directly follows `(h)` at level 2
        const followsHAtLevel2 = prevItem && prevItem.level === 2 && prevItem.index === 8;
        isRoman = !followsHAtLevel2;
      }
    }

    if (isRoman) {
      return {
        level: 3,
        style: '(i)',
        indent,
        major: prevItem ? prevItem.major : 1,
        index: romanVal,
        marker: `(${token})`,
        space,
        body
      };
    }

    if (alphaVal !== null) {
      return {
        level: 2,
        style: '(a)',
        indent,
        major: prevItem ? prevItem.major : 1,
        index: alphaVal,
        marker: `(${token})`,
        space,
        body
      };
    }
  }

  return null;
}

export function formatLegalMarker(level, counters) {
  const [c0, c1, c2, c3] = counters;
  switch (level) {
    case 0:
      return `${Math.max(1, c0)}.`;
    case 1:
      return `${Math.max(1, c0)}.${Math.max(1, c1)}`;
    case 2:
      return `(${toAlpha(Math.max(1, c2))})`;
    case 3:
    default:
      return `(${toRoman(Math.max(1, c3))})`;
  }
}

export function formatLegalLine(level, counters, body = '', customIndent = null) {
  const indent = customIndent !== null ? customIndent : INDENTS[Math.max(0, Math.min(3, level))];
  const marker = formatLegalMarker(level, counters);
  return `${indent}${marker} ${body}`;
}

export function isSectionHeadingLine(lineText) {
  return typeof lineText === 'string' && /^§\s+\S/.test(lineText);
}

/**
 * Renumbers all legal list blocks in `text` so that items are sequential
 * (`1.`, `1.1`, `(a)`, `(i)`) after moves, insertions, promotions, or deletions.
 */
export function renumberLegalLists(text) {
  const source = typeof text === 'string' ? text : '';
  const lines = source.split('\n');
  let counters = [0, 0, 0, 0];
  let prevItem = null;

  const out = lines.map(line => {
    const trimmed = line.trim();
    if (trimmed === '' || trimmed === PAGE_MARKER || /^#{1,6}\s+/.test(trimmed) || /^§\s+/.test(trimmed)) {
      counters = [0, 0, 0, 0];
      prevItem = null;
      return line;
    }

    const parsed = parseLegalItem(line, prevItem);
    if (!parsed) {
      return line;
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
      if (counters[0] === 0) counters[0] = 1;
      if (counters[1] === 0) counters[1] = 1;
      counters[2] += 1;
      counters[3] = 0;
    } else {
      if (counters[0] === 0) counters[0] = 1;
      if (counters[1] === 0) counters[1] = 1;
      if (counters[2] === 0) counters[2] = 1;
      counters[3] += 1;
    }

    const marker = formatLegalMarker(lvl, counters);
    prevItem = {
      ...parsed,
      major: counters[0],
      index: counters[lvl],
      marker
    };

    return `${parsed.indent}${marker}${parsed.space}${parsed.body}`;
  });

  return out.join('\n');
}

/**
 * Computes the counters `[c0, c1, c2, c3]` up to `targetLineIndex` (0-based, inclusive).
 */
function computeContextAtLine(lines, targetLineIndex) {
  let counters = [0, 0, 0, 0];
  let prevItem = null;
  let parsedTarget = null;

  for (let i = 0; i <= targetLineIndex && i < lines.length; i++) {
    const line = lines[i];
    const trimmed = line.trim();
    if (trimmed === '' || trimmed === PAGE_MARKER || /^#{1,6}\s+/.test(trimmed) || /^§\s+/.test(trimmed)) {
      counters = [0, 0, 0, 0];
      prevItem = null;
      continue;
    }
    const parsed = parseLegalItem(line, prevItem);
    if (!parsed) continue;

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
      if (counters[0] === 0) counters[0] = 1;
      if (counters[1] === 0) counters[1] = 1;
      counters[2] += 1;
      counters[3] = 0;
    } else {
      if (counters[0] === 0) counters[0] = 1;
      if (counters[1] === 0) counters[1] = 1;
      if (counters[2] === 0) counters[2] = 1;
      counters[3] += 1;
    }

    prevItem = {
      ...parsed,
      major: counters[0],
      index: counters[lvl]
    };
    if (i === targetLineIndex) {
      parsedTarget = prevItem;
    }
  }

  return { counters, parsedTarget };
}

/**
 * Pure helper: continues a legal numbered item when Enter is pressed at `cursorOffset`.
 * Returns `{ text, cursor }` or `null` if the line at `cursorOffset` is not a legal item.
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

  const { counters, parsedTarget } = computeContextAtLine(lines, lineIdx);
  if (!parsedTarget) return null;

  const lineStart = offset;
  const lineText = lines[lineIdx];
  const prefixLen = parsedTarget.indent.length + parsedTarget.marker.length + parsedTarget.space.length;
  const bodyStart = lineStart + prefixLen;

  // If the item has no body text, pressing Enter clears the empty marker on this line
  if (parsedTarget.body.trim() === '') {
    const before = source.slice(0, lineStart);
    const after = source.slice(lineStart + lineText.length);
    const nextDoc = renumberLegalLists(before + after);
    return {
      text: nextDoc,
      cursor: lineStart
    };
  }

  const splitAt = Math.max(bodyStart, pos);
  const keptOnCurrentLine = source.slice(lineStart, splitAt);
  const movedToNextLine = source.slice(splitAt, lineStart + lineText.length);

  const nextCounters = [...counters];
  nextCounters[parsedTarget.level] += 1;
  for (let k = parsedTarget.level + 1; k < 4; k++) nextCounters[k] = 0;

  const nextMarker = formatLegalMarker(parsedTarget.level, nextCounters);
  const insertedPrefix = `${parsedTarget.indent}${nextMarker} `;
  const newLines = [...lines];
  newLines.splice(lineIdx, 1, keptOnCurrentLine, `${insertedPrefix}${movedToNextLine}`);

  const renumbered = renumberLegalLists(newLines.join('\n'));
  const renumberedLines = renumbered.split('\n');
  let newCursor = 0;
  for (let i = 0; i <= lineIdx; i++) {
    newCursor += renumberedLines[i].length + 1;
  }
  const nextParsed = parseLegalItem(renumberedLines[lineIdx + 1]);
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
 * then renumbers the list.
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

  const oldLineText = lines[lineIdx];
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
  lines[lineIdx] = formatLegalLine(targetLevel, tempCounters, parsedTarget.body);

  const renumbered = renumberLegalLists(lines.join('\n'));
  const renumberedLines = renumbered.split('\n');
  let newLineStart = 0;
  for (let i = 0; i < lineIdx; i++) {
    newLineStart += renumberedLines[i].length + 1;
  }
  const updatedParsed = parseLegalItem(renumberedLines[lineIdx]);
  const newPrefixLen = updatedParsed
    ? updatedParsed.indent.length + updatedParsed.marker.length + updatedParsed.space.length
    : 0;

  return {
    text: renumbered,
    cursor: Math.min(
      newLineStart + renumberedLines[lineIdx].length,
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
  if (result.text === current && result.cursor === view.state.selection.main.head) {
    return true;
  }
  view.dispatch({
    changes: { from: 0, to: current.length, insert: result.text },
    selection: { anchor: result.cursor }
  });
  return true;
}

/**
 * Automatically renumbers legal lists when lines are deleted or moved.
 */
const legalRenumberFilter = EditorState.transactionFilter.of(tr => {
  if (!tr.docChanged || tr.annotation(externalSetTextAnnotation)) return tr;
  let lineCountChanged = false;
  tr.changes.iterChanges((fromA, toA, fromB, toB, inserted) => {
    const removedText = tr.startState.doc.sliceString(fromA, toA);
    if (removedText.includes('\n') || inserted.toString().includes('\n')) {
      lineCountChanged = true;
    }
  });
  if (!lineCountChanged) return tr;

  const newDocText = tr.newDoc.toString();
  const renumbered = renumberLegalLists(newDocText);
  if (renumbered === newDocText) return tr;

  const head = Math.min(renumbered.length, tr.newSelection.main.head);
  return [
    tr,
    {
      changes: { from: 0, to: newDocText.length, insert: renumbered },
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
          const cur = view.state.doc.toString();
          const renumbered = renumberLegalLists(cur);
          if (renumbered !== cur) {
            view.dispatch({
              changes: { from: 0, to: cur.length, insert: renumbered },
              selection: view.state.selection
            });
          }
          return true;
        }
      },
      {
        key: 'Alt-ArrowDown',
        run(view) {
          const moved = moveLineDown(view);
          if (!moved) return false;
          const cur = view.state.doc.toString();
          const renumbered = renumberLegalLists(cur);
          if (renumbered !== cur) {
            view.dispatch({
              changes: { from: 0, to: cur.length, insert: renumbered },
              selection: view.state.selection
            });
          }
          return true;
        }
      }
    ])
  ];
}
