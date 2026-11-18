// Derived from Spec: PLAN-1118 §11b · the debug channel's JS twin gives the Swift twin's bytes
// (shared/ShowsKit/Tests/ShowsKitTests/Fixtures/debugchannel.json), refuses what Swift refuses, and never throws. Run with `npm test`.
import { readFileSync } from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const code = readFileSync(new URL("../src/client/debuglog.js", import.meta.url), "utf8");
const fix = JSON.parse(readFileSync(new URL("../../shared/ShowsKit/Tests/ShowsKitTests/Fixtures/debugchannel.json", import.meta.url), "utf8"));
const load = () => vm.runInNewContext(code + "; RecenseDebugLog");

let passed = 0;
const test = (name, fn) => { fn(); passed++; console.log("ok   " + name); };

test("same bytes as Swift for every fixture case", () => {
  const L = load();
  assert.ok(fix.cases.length > 5);
  for (const c of fix.cases) assert.equal(L.line(c.feature, c.event, c.fields, c.at), c.line, c.event);
});

test("no sink: lines wait in a ring; a sink later receives them in order and then new ones directly", () => {
  const L = load();
  L.event("carry", "carry.send", { n: 1 }); L.event("carry", "carry.apply"); L.event("carry", "nope.x");
  assert.equal(L.dump("carry").length, 2);
  const got = [];
  L.setSink((f, l) => got.push([f, JSON.parse(l).event]));
  L.event("m4b", "m4b.done");
  assert.deepEqual(got, [["carry", "carry.send"], ["carry", "carry.apply"], ["m4b", "m4b.done"]]);
  assert.equal(L.dump().length, 0);
});

test("the ring keeps the last 200 lines", () => {
  const L = load();
  for (let i = 0; i < 250; i++) L.event("carry", "carry.x", { i });
  const d = L.dump("carry");
  assert.equal(d.length, 200);
  assert.equal(JSON.parse(d[0]).fields.i, "50");
});

test("a sink that throws never reaches the caller", () => {
  const L = load();
  L.setSink(() => { throw new Error("disk full"); });
  L.event("carry", "carry.x");
  L.event("carry", "carry.y", { circular: { toString() { throw new Error("x"); } } });
});

console.log(passed + " passed");
