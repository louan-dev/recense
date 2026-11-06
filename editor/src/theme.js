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
    selection: 'rgba(56, 189, 248, 0.20)',
    activeLine: 'rgba(91, 155, 213, 0.07)'
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
    selection: 'rgba(8, 145, 178, 0.18)',
    activeLine: 'rgba(43, 108, 176, 0.06)'
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

export function createThemeCompartments() {
  return {
    theme: new Compartment(),
    fontSize: new Compartment()
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
        maxWidth: `${COLUMN_CHARS}ch`,
        margin: '0 auto',
        padding: '28px 20px 96px 20px',
        lineHeight: '1.65'
      },
      '.cm-cursor, .cm-dropCursor': {
        borderLeftColor: palette.cyan,
        borderLeftWidth: '2px'
      },
      '&.cm-focused .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection': {
        backgroundColor: palette.selection
      },
      '.cm-activeLine': {
        backgroundColor: palette.activeLine,
        borderRadius: '4px'
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
      '.cm-searchMatch': {
        backgroundColor: 'rgba(56, 189, 248, 0.22)',
        outline: `1px solid ${palette.cyan}`
      },
      '.cm-searchMatch.cm-searchMatch-selected': {
        backgroundColor: 'rgba(56, 189, 248, 0.42)'
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
