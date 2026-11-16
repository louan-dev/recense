// Regression guard: BUG-22
// The editor draws no band behind the caret's line, on any host (PWA, Mac, iPhone, iPad all load this editor).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const src = f => readFileSync(new URL(`../src/${f}`, import.meta.url), 'utf8');

test('BUG-22: the editor does not turn on CodeMirror\'s active-line band', () => {
  assert.doesNotMatch(src('index.js'), /highlightActiveLine/);
});

test('BUG-22: no theme or stylesheet paints .cm-activeLine', () => {
  assert.doesNotMatch(src('theme.js'), /activeLine/i);
  assert.doesNotMatch(src('styles.css'), /cm-activeLine/);
});

test('BUG-22: the built editor carries no active-line band either', () => {
  const dist = readFileSync(new URL('../dist/editor.html', import.meta.url), 'utf8');
  // CodeMirror's base theme still names .cm-activeLine; only the plugin that tags the line must be gone.
  assert.doesNotMatch(dist, /class:\s*"cm-activeLine"/);
  assert.doesNotMatch(dist, /activeLine:\s*"rgba/);
});
