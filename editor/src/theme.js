import { Compartment } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { HighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { tags } from '@lezer/highlight';

export const DEFAULT_FONT_SIZE = 18;
export const COLUMN_CHARS = 66;

export const THEMES = {
  dark: {
    name: 'dark',
    bg: 'rgba(11, 14, 20, 0.92)',
    surface: '#0b0e14',
    panelBg: 'rgba(15, 20, 28, 0.96)',
    text: '#e6edf3',
    muted: '#8b98a9',
    blue: '#5b9bd5',
    cyan: '#38bdf8',
    border: 'rgba(91, 155, 213, 0.22)',
    selection: 'rgba(56, 189, 248, 0.40)'
  },
  light: {
    name: 'light',
    bg: '#f7f6f2',
    surface: '#f7f6f2',
    panelBg: '#efede7',
    text: '#1c2430',
    muted: '#5c6877',
    blue: '#2b6cb0',
    cyan: '#0891b2',
    border: 'rgba(43, 108, 176, 0.22)',
    selection: 'rgba(8, 145, 178, 0.30)'
  }
};

export function normalizeThemeName(mode) {
  return mode === 'light' ? 'light' : 'dark';
}

export function normalizeFontSize(px) {
  const n = Number(px);
  if (!Number.isFinite(n)) return DEFAULT_FONT_SIZE;
  return Math.max(12, Math.min(36, Math.round(n)));
}

// Derived from Spec: UI-07 · Larger / Smaller text in the menu: 2 px a step, inside normalizeFontSize's 12–36.
export const FONT_STEP_PX = 2;
export function stepFontSize(px, dir) {
  return normalizeFontSize(normalizeFontSize(px) + FONT_STEP_PX * Math.sign(Number(dir) || 0));
}

export function createThemeCompartments() {
  return {
    theme: new Compartment(),
    fontSize: new Compartment(),
    history: new Compartment()   // FEAT-23 rule 3: emptied when the document swaps, so undo never crosses documents
  };
}

export function buildThemeExtension(mode = 'dark') {
  const key = normalizeThemeName(mode);
  const palette = THEMES[key];
  const isDark = key === 'dark';

  const editorTheme = EditorView.theme(
    {
      '&': {
        color: palette.text,
        backgroundColor: 'transparent'
      },
      '.cm-content': {
        caretColor: palette.cyan,
        // UI-07 · devicelayout.js sets these per device; the Mac keeps the fallbacks.
        maxWidth: `var(--rc-col, ${COLUMN_CHARS}ch)`,
        margin: '0 auto',
        padding: 'var(--rc-pad-top, 28px) var(--rc-pad-x, 20px) var(--rc-pad-bottom, 96px) var(--rc-pad-x, 20px)',
        lineHeight: '1.65'
      },
      '.cm-cursor, .cm-dropCursor': {
        borderLeftColor: palette.cyan,
        borderLeftWidth: '2px'
      },
      // T-0088 · as specific as CodeMirror's own focused rule, or its #233 grey wins and the selection all but vanishes.
      '&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection': {
        backgroundColor: palette.selection
      },
      '.cm-gutters': {
        backgroundColor: 'transparent',
        color: palette.muted,
        border: 'none'
      },
      '.cm-foldPlaceholder': {
        backgroundColor: 'transparent',
        border: `1px solid ${palette.border}`,
        color: palette.cyan,
        borderRadius: '4px',
        padding: '0 6px',
        margin: '0 4px'
      },
      '.cm-panels': {
        backgroundColor: palette.panelBg,
        color: palette.text,
        borderBottom: `1px solid ${palette.border}`
      },
      // T-0088 · other copies of the selected word: a dotted underline, never a fill that looks like a selection.
      '.cm-selectionMatch': {
        backgroundColor: 'transparent',
        textDecoration: `underline dotted ${palette.muted}`,
        textUnderlineOffset: '4px'
      },
      '.cm-searchMatch': {
        backgroundColor: 'rgba(56, 189, 248, 0.22)',
        borderRadius: '3px'
      },
      '.cm-searchMatch.cm-searchMatch-selected': {
        backgroundColor: 'rgba(56, 189, 248, 0.52)',
        outline: `1.5px solid ${palette.cyan}`,
        borderRadius: '3px'
      }
    },
    { dark: isDark }
  );

  const highlight = HighlightStyle.define([
    { tag: tags.heading, color: palette.blue, fontWeight: '600' },
    { tag: tags.strong, color: palette.text, fontWeight: '600' },
    { tag: tags.emphasis, color: palette.text, fontStyle: 'italic' },
    { tag: [tags.link, tags.url], color: palette.cyan },
    { tag: [tags.monospace, tags.processingInstruction], color: palette.blue },
    { tag: [tags.meta, tags.comment], color: palette.muted }
  ]);

  return [editorTheme, syntaxHighlighting(highlight)];
}

export function buildFontSizeExtension(px = DEFAULT_FONT_SIZE) {
  const size = normalizeFontSize(px);
  return EditorView.theme({
    '&': {
      fontSize: `${size}px`
    },
    '.cm-content': {
      fontSize: `${size}px`
    }
  });
}
