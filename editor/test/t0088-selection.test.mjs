// Regression guard: T-0088 — the green "other matches" fill read as the selection, and the real selection was too faint.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { THEMES } from '../src/theme.js';

const alpha = rgba => Number(/,\s*([\d.]+)\)$/.exec(rgba)[1]);

test('T-0088: the selection is clearly visible in both themes', () => {
  assert.ok(alpha(THEMES.dark.selection) >= 0.35, THEMES.dark.selection);
  assert.ok(alpha(THEMES.light.selection) >= 0.28, THEMES.light.selection);
});

test('T-0088: other matches of the selection are an underline on whole words, never a fill', () => {
  const theme = readFileSync(new URL('../src/theme.js', import.meta.url), 'utf8');
  const rule = /'\.cm-selectionMatch': \{([^}]*)\}/.exec(theme);
  assert.ok(rule, '.cm-selectionMatch is styled');
  assert.match(rule[1], /backgroundColor: 'transparent'/);
  const search = readFileSync(new URL('../src/search.js', import.meta.url), 'utf8');
  assert.match(search, /highlightSelectionMatches\(\{ wholeWords: true, minSelectionLength: 3 \}\)/);
});

test('T-0088: our selection rule matches CodeMirror focused-rule specificity (else its #233 grey wins)', () => {
  const theme = readFileSync(new URL('../src/theme.js', import.meta.url), 'utf8');
  assert.match(theme, /'&\.cm-focused > \.cm-scroller > \.cm-selectionLayer \.cm-selectionBackground/);
});
