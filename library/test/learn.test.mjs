// learn.js: Learn's pure rules, moved out of gallery.js unchanged (2026-11-09). The expected phrases and beats below
// were produced by the gallery.js copy before the move, so this pins "no behaviour change"; and the page loads
// learn.js before gallery.js, which reads its rules from the RecenseLearn global.
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const src = fs.readFileSync(new URL("../src/client/learn.js", import.meta.url), "utf8");
const ctx = { window: {} };
ctx.globalThis = ctx;
vm.createContext(ctx);
vm.runInContext(src, ctx);
const L = ctx.RecenseLearn;

const LINES = [{"s": 0, "e": 3.5999999999999996, "words": [{"t": "Hợp", "s": 0, "e": 0.24}, {"t": "đồng", "s": 0.3, "e": 0.54}, {"t": "là", "s": 0.6, "e": 0.84}, {"t": "sự", "s": 0.8999999999999999, "e": 1.14}, {"t": "thỏa", "s": 1.2, "e": 1.44}, {"t": "thuận", "s": 1.5, "e": 1.74}, {"t": "giữa", "s": 1.8, "e": 2.04}, {"t": "các", "s": 2.1, "e": 2.34}, {"t": "bên,", "s": 2.4, "e": 2.6399999999999997}, {"t": "theo", "s": 2.6999999999999997, "e": 2.9399999999999995}, {"t": "Điều", "s": 2.9999999999999996, "e": 3.2399999999999993}, {"t": "385.", "s": 3.2999999999999994, "e": 3.539999999999999}], "enw": [{"w": "A", "s": [0]}, {"w": "contract", "s": [1]}, {"w": "is", "s": [2]}, {"w": "an", "s": [3]}, {"w": "agreement", "s": [4]}, {"w": "between", "s": [5]}, {"w": "the", "s": [6]}, {"w": "parties,", "s": [7]}, {"w": "under", "s": [8]}, {"w": "Article", "s": [9]}, {"w": "385.", "s": [10]}]}, {"s": 0, "e": 2.1, "words": [{"t": "Me", "s": 0, "e": 0.24}, {"t": "dejas", "s": 0.3, "e": 0.54}, {"t": "sin", "s": 0.6, "e": 0.84}, {"t": "palabras", "s": 0.8999999999999999, "e": 1.14}, {"t": "cuando", "s": 1.2, "e": 1.44}, {"t": "me", "s": 1.5, "e": 1.74}, {"t": "miras.", "s": 1.8, "e": 2.04}], "enw": [{"w": "You"}, {"w": "leave"}, {"w": "me"}, {"w": "speechless"}, {"w": "when"}, {"w": "you"}, {"w": "look"}, {"w": "at"}, {"w": "me."}]}, {"s": 0, "e": 2.4, "words": [{"t": "我", "s": 0, "e": 0.24}, {"t": "爱", "s": 0.3, "e": 0.54}, {"t": "你", "s": 0.6, "e": 0.84}, {"t": "，", "s": 0.8999999999999999, "e": 1.14}, {"t": "永远", "s": 1.2, "e": 1.44}, {"t": "不", "s": 1.5, "e": 1.74}, {"t": "变", "s": 1.8, "e": 2.04}, {"t": "。", "s": 2.1, "e": 2.34}], "enw": [{"w": "I", "s": [0]}, {"w": "love", "s": [1]}, {"w": "you,", "s": [2]}, {"w": "never", "s": [3]}, {"w": "changing.", "s": [4]}]}, {"s": 0, "e": 3, "words": [{"t": "Le", "s": 0, "e": 0.24}, {"t": "contrat", "s": 0.3, "e": 0.54}, {"t": "est", "s": 0.6, "e": 0.84}, {"t": "formé", "s": 0.8999999999999999, "e": 1.14}, {"t": "dès", "s": 1.2, "e": 1.44}, {"t": "que", "s": 1.5, "e": 1.74}, {"t": "l’acceptation", "s": 1.8, "e": 2.04}, {"t": "parvient", "s": 2.1, "e": 2.34}, {"t": "à", "s": 2.4, "e": 2.6399999999999997}, {"t": "l’offrant.", "s": 2.6999999999999997, "e": 2.9399999999999995}], "enw": [{"w": "The", "s": [0, 1]}, {"w": "contract", "s": [1, 2]}, {"w": "is", "s": [2, 3]}, {"w": "formed", "s": [3, 4]}, {"w": "as", "s": [4, 5]}, {"w": "soon", "s": [5, 6]}, {"w": "as", "s": [6, 7]}, {"w": "the", "s": [7, 8]}, {"w": "acceptance", "s": [8, 9]}, {"w": "reaches", "s": [9, 10]}, {"w": "the", "s": [10, 11]}, {"w": "offeror.", "s": [11, 12]}]}, {"s": 0, "e": 0.3, "words": [{"t": "one", "s": 0, "e": 0.24}], "enw": [{"w": "một"}]}];
const PHRASES = [[{"src": [0, 5], "en": [0, 5]}, {"src": [5, 9], "en": [5, 8]}, {"src": [9, 12], "en": [8, 11]}], [{"src": [0, 4], "en": [0, 4]}, {"src": [4, 7], "en": [4, 9]}], [{"src": [0, 4], "en": [0, 3]}, {"src": [4, 8], "en": [3, 5]}], [{"src": [0, 4], "en": [0, 4]}, {"src": [4, 7], "en": [4, 9]}, {"src": [7, 10], "en": [9, 12]}], [{"src": [0, 1], "en": [0, 1]}]];
const BEATS = [[{"t": "Hợp", "s": 0, "e": 0.3}, {"t": "đồng", "s": 0.3, "e": 0.6}, {"t": "là", "s": 0.6, "e": 0.8999999999999999}, {"t": "sự", "s": 0.8999999999999999, "e": 1.2}, {"t": "thỏa", "s": 1.2, "e": 1.5}, {"t": "thuận", "s": 1.5, "e": 1.8}, {"t": "giữa", "s": 1.8, "e": 2.1}, {"t": "các", "s": 2.1, "e": 2.4}, {"t": "bên,", "s": 2.4, "e": 2.6999999999999997}, {"t": "theo", "s": 2.6999999999999997, "e": 2.9999999999999996}, {"t": "Điều", "s": 2.9999999999999996, "e": 3.2999999999999994}, {"t": "385.", "s": 3.2999999999999994, "e": 3.539999999999999}], [{"t": "Me", "s": 0, "e": 0.3}, {"t": "dejas", "s": 0.3, "e": 0.6}, {"t": "sin", "s": 0.6, "e": 0.8999999999999999}, {"t": "palabras", "s": 0.8999999999999999, "e": 1.2}, {"t": "cuando", "s": 1.2, "e": 1.5}, {"t": "me", "s": 1.5, "e": 1.8}, {"t": "miras.", "s": 1.8, "e": 2.04}], [{"t": "我", "s": 0, "e": 0.3}, {"t": "爱", "s": 0.3, "e": 0.6}, {"t": "你", "s": 0.6, "e": 0.8999999999999999}, {"t": "，", "s": 0.8999999999999999, "e": 1.2}, {"t": "永远", "s": 1.2, "e": 1.5}, {"t": "不", "s": 1.5, "e": 1.8}, {"t": "变", "s": 1.8, "e": 2.1}, {"t": "。", "s": 2.1, "e": 2.34}], [{"t": "Le", "s": 0, "e": 0.3}, {"t": "contrat", "s": 0.3, "e": 0.6}, {"t": "est", "s": 0.6, "e": 0.8999999999999999}, {"t": "formé", "s": 0.8999999999999999, "e": 1.2}, {"t": "dès", "s": 1.2, "e": 1.5}, {"t": "que", "s": 1.5, "e": 1.8}, {"t": "l’acceptation", "s": 1.8, "e": 2.1}, {"t": "parvient", "s": 2.1, "e": 2.4}, {"t": "à", "s": 2.4, "e": 2.6999999999999997}, {"t": "l’offrant.", "s": 2.6999999999999997, "e": 2.9399999999999995}], [{"t": "one", "s": 0, "e": 0.24}]];

assert.deepEqual(Object.keys(L).sort(), ["TURN", "UNSPACED", "endsClause", "leansOn", "leansOnEnglish", "phrasesOf", "readingTime", "sourceBeats", "sourcesOf", "translated"]);
assert.ok(Object.isFrozen(L));
LINES.forEach((l, i) => {
  assert.deepEqual(JSON.parse(JSON.stringify(L.phrasesOf(l))), PHRASES[i], `phrases of line ${i}`);
  assert.deepEqual(JSON.parse(JSON.stringify(L.sourceBeats(l))), BEATS[i], `beats of line ${i}`);
});
assert.equal(L.endsClause("bên,"), true);
assert.equal(L.endsClause("你，"), true);
assert.equal(L.leansOn("là"), true);
assert.equal(L.leansOn("我"), false, "an unspaced script's word leans on nothing");
assert.equal(L.TURN, 0.3);

// The page: learn.js before gallery.js; gallery.js keeps no copy of the rules.
const page = fs.readFileSync(new URL("../src/page/gallery.js", import.meta.url), "utf8");
assert.ok(page.indexOf("${learn}") > 0 && page.indexOf("${learn}") < page.indexOf("${js}"), "learn.js loads before gallery.js");
const gallery = fs.readFileSync(new URL("../src/client/gallery.js", import.meta.url), "utf8");
assert.match(gallery, /= RecenseLearn;/);
for (const def of ["const phrasesOf =", "const sourceBeats =", "const endsClause =", "const UNSPACED ="]) {
  assert.ok(!gallery.includes(def), `no old copy in gallery.js: ${def}`);
}
console.log("learn: ok");
