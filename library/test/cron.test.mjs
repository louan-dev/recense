// Regression guard: BUG-30 (a failing cron job is logged and never stops the next one)
import assert from "node:assert/strict";
import { runJobs } from "../src/common.js";

const logged = [], real = console.error;
console.error = (...a) => logged.push(a.join(" "));
const ran = [];
const out = await runJobs({
  a: async () => { ran.push("a"); throw new Error("boom"); },
  b: async () => { ran.push("b"); },
  c: () => { ran.push("c"); throw new Error("sync boom"); },
  d: async () => { await new Promise((r) => setTimeout(r, 5)); ran.push("d"); },
});
console.error = real;
assert.deepEqual(ran.sort(), ["a", "b", "c", "d"]);
assert.deepEqual(out.map((r) => r.status), ["rejected", "fulfilled", "rejected", "fulfilled"]);
assert.equal(logged.length, 2);
assert.ok(logged[0].includes("cron job a failed") && logged[1].includes("cron job c failed"));
console.log("ok cron: failures logged, every job ran");
