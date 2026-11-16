// FEAT-07 / FEAT-16 P5: the pill's Find in the web player and the Mac's strip (homebar.js find*). The same fixture and
// the same answers as ShowsKit's TranscriptFindTests.swift, so the Swift pill and this one find the same lines.
import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

createRequire(import.meta.url)("../src/client/homebar.js");
const H = globalThis.Homebar;

// Gallery's lines: s (start), text, tr (a translation, or {lang: text})
const lines = [
  { s: 0, text: "Hello and welcome", tr: "Xin chào và chào mừng" },
  { s: 5, text: "We talk about Việt Nam today", tr: { vi: "Hôm nay nói về Việt Nam" } },
  { s: 10, text: "Le café est prêt", tr: { en: "The coffee is ready" } },
  { s: 20, text: "Đà Nẵng and Hà Nội" },
];

test("search ignores case and accents, and reads every translation", () => {
  assert.deepEqual(H.findHits(lines, "viet"), [1]);
  assert.deepEqual(H.findHits(lines, "CAFE"), [2]);
  assert.deepEqual(H.findHits(lines, "da nang"), [3], "đ folds to d");
  assert.deepEqual(H.findHits(lines, "chao"), [0], "the translation is searched too");
  assert.deepEqual(H.findHits(lines, "coffee"), [2]);
  assert.deepEqual(H.findHits(lines, "a"), [], "one letter finds nothing");
  assert.deepEqual(H.findHits(lines, " a "), [], "spaces don't count as letters");
  assert.deepEqual(H.findHits(lines, "zzz"), []);
  assert.deepEqual(H.findHits(lines, "ｃａｆｅ"), [2], "full-width folds to narrow");
});

test("search sees the lines as they arrive", () => {
  assert.deepEqual(H.findHits(lines.slice(0, 1), "nam"), []);
  assert.deepEqual(H.findHits(lines.slice(0, 2), "nam"), [1]);
  assert.deepEqual(H.findHits(null, "nam"), []);
});

test("step wraps both ways", () => {
  const h = [1, 3, 5];
  assert.equal(H.findStep(h, null), 1);
  assert.equal(H.findStep(h, 1), 3);
  assert.equal(H.findStep(h, 5), 1);
  assert.equal(H.findStep(h, 1, true), 5);
  assert.equal(H.findStep(h, 4), 1, "a hit no longer there starts again from the first");
  assert.equal(H.findStep([], null), null);
});

test("the count reads as the Swift pill's", () => {
  assert.equal(H.findCount([], "a", null), "");
  assert.equal(H.findCount([], "zz", null), "No matches");
  assert.equal(H.findCount([1, 3], "ab", null), "2 found");
  assert.equal(H.findCount([1, 3], "ab", 3), "2 of 2");
});
