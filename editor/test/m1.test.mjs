import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  PAGE_MARKER,
  PAGE_JOINER,
  parseDateLine,
  isFullDateLine,
  inspectDraftpadPages,
  findPageDecorations
} from '../src/pages.js';
import {
  DEFAULT_FONT_SIZE,
  COLUMN_CHARS,
  THEMES,
  normalizeThemeName,
  normalizeFontSize
} from '../src/theme.js';
import { createEditorState } from '../src/index.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, '..');

test('M1: full-style date lines parse accurately', () => {
  assert.equal(isFullDateLine('Friday, November 6, 2026'), true);
  assert.equal(isFullDateLine('Monday, November 2, 2026'), true);
  assert.equal(isFullDateLine('  Sunday, January 1, 2026  '), true);
  assert.equal(isFullDateLine('2026-11-06'), false);
  assert.equal(isFullDateLine('Nov 6, 2026'), false);
  assert.equal(isFullDateLine('Funday, November 6, 2026'), false);
  assert.equal(isFullDateLine('Friday, February 30, 2026'), false);
  assert.ok(parseDateLine('Friday, November 6, 2026') > parseDateLine('Thursday, November 5, 2026'));
});

test('M1: Draftpad file format round-trips byte for byte and locates page markers', () => {
  const sample = [
    'Friday, November 6, 2026\n\nFirst page body with trailing spaces   \n\tindented line',
    'Monday, November 2, 2026\n\nSecond page body\n<!-- not a page marker -->',
    'Unheaded page\n\nWith multiple paragraphs'
  ].join(PAGE_JOINER);

  const { state } = createEditorState(sample);
  assert.equal(state.doc.toString(), sample);

  const pages = inspectDraftpadPages(sample);
  assert.equal(pages.length, 3);
  assert.equal(pages[0].dateLine, 'Friday, November 6, 2026');
  assert.equal(pages[1].dateLine, 'Monday, November 2, 2026');
  assert.equal(pages[2].dateLine, null);
  assert.equal(pages.map(p => p.rawContent).join(PAGE_JOINER), sample);

  const decos = findPageDecorations(sample);
  assert.equal(decos.markers.length, 2);
  for (const m of decos.markers) {
    assert.equal(sample.slice(m.from, m.to), PAGE_MARKER);
  }
  assert.equal(decos.dateLines.length, 2);
  assert.equal(decos.dateLines[0].text, 'Friday, November 6, 2026');
  assert.equal(decos.dateLines[1].text, 'Monday, November 2, 2026');
});

test('M1: themes and typography defaults meet eye-comfort bar', () => {
  assert.equal(DEFAULT_FONT_SIZE, 18);
  assert.equal(COLUMN_CHARS, 66);
  assert.equal(normalizeThemeName('dark'), 'dark');
  assert.equal(normalizeThemeName('light'), 'light');
  assert.equal(normalizeThemeName('unknown'), 'dark');
  assert.equal(normalizeFontSize(22), 22);
  assert.equal(normalizeFontSize(4), 12);
  assert.equal(normalizeFontSize(99), 36);
  assert.equal(normalizeFontSize('bad'), 18);
  assert.ok(THEMES.dark.blue && THEMES.dark.cyan);
  assert.ok(THEMES.light.blue && THEMES.light.cyan);
});

test('M1: dist/editor.html is a single self-contained offline file with no banned terms', () => {
  const htmlPath = path.join(rootDir, 'dist', 'editor.html');
  assert.equal(fs.existsSync(htmlPath), true, 'dist/editor.html must exist');
  const html = fs.readFileSync(htmlPath, 'utf8');
  assert.match(html, /<!DOCTYPE html>/i);
  assert.match(html, /<style>[\s\S]+<\/style>/);
  assert.match(html, /<script>[\s\S]+<\/script>/);
  assert.doesNotMatch(html, /<script[^>]+src=/i);
  assert.doesNotMatch(html, /<link[^>]+rel=["']stylesheet["']/i);
  assert.doesNotMatch(html, /obsidian/i);
});
