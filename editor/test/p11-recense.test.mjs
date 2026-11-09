// Recense what you typed (M1): typed text as Lines, citations checked, only edited lines redone, chapters frozen while
// the panel is open, and "Make heading" the only write. Test pages are written here (never the owner's notes).
import test from 'node:test';
import assert from 'node:assert/strict';
import { pageSentences, pageSections, docSections, sentenceLine, reconcile, fnv1a } from '../src/typedlines.js';
import { checkLines, extractive, settle, settleExtra, askExtract, reformatKind, keyTerms, isMixed, ownLanguageProse } from '../src/lenses.js';
import { createRecense, lensBlocks, QUIET_MS, LENSES } from '../src/recense.js';
import { chapterEntries } from '../src/chapters.js';

const PAGE = `Sunday, November 8, 2026

A contract needs an offer, acceptance and consideration. In Carlill v Carbolic Smoke Ball Co, an advertisement was held to be a unilateral offer.

Mrs Carlill used the smoke ball as directed and still caught influenza. So the company had to pay her the £100 it promised.`;

test('a typed paragraph becomes valid Line JSON, one Line per sentence, keyed by its text', () => {
  const ss = pageSentences(PAGE).filter(s => !s.isHeading);
  assert.equal(ss.length, 4);
  assert.deepEqual(ss.map(s => s.p), [0, 0, 1, 1]);
  assert.equal(ss[0].key, fnv1a('A contract needs an offer, acceptance and consideration.'));
  const line = JSON.parse(JSON.stringify(sentenceLine(ss[0], 0)));
  assert.equal(line.id, 0);
  assert.equal(line.english, null);
  assert.deepEqual(line.words.map(w => w.text), ['A', 'contract', 'needs', 'an', 'offer,', 'acceptance', 'and', 'consideration.']);
  for (const w of line.words) assert.deepEqual(Object.keys(w).sort(), ['end', 'start', 'text']);
  assert.equal(PAGE.slice(ss[1].from, ss[1].to), ss[1].text, 'offsets point at the sentence in the page');
});

test('sections cut at your own headings and after ~1,500 words at a paragraph end', () => {
  const long = Array.from({ length: 40 }, (_, i) => `Paragraph ${i} ${'word '.repeat(60)}ends here.`).join('\n\n');
  const secs = pageSections(`# Facts\n\n${long}\n\n# Holding\n\nThe court held for the plaintiff.`);
  assert.ok(secs.length >= 3);
  assert.ok(secs.every(s => s.words <= 1500 + 70));
  assert.equal(secs.at(-1).heading, 'Holding');
  assert.equal(secs[0].heading, 'Facts');
});

test('every lens line has `from` or is labelled added, and a line whose terms are not in its sources is dropped', () => {
  const ss = pageSentences(PAGE).filter(s => !s.isHeading);
  const [a, b, c, d] = ss.map(s => s.key);
  const { kept, dropped } = checkLines([
    { text: 'A contract requires offer, acceptance and consideration.', from: [a] },
    { text: 'The defendant breached a lease of farmland in Ohio.', from: [c] },        // not in what it cites
    { text: 'Carlill caught influenza after using the smoke ball.', from: [] },        // no citation, but it is there
    { text: 'Would the result differ for a bilateral offer?', from: [] },              // a question: added
    { text: 'Advertisement held unilateral offer.', from: ['nope', b] }                // unknown keys are removed
  ], ss);
  assert.equal(dropped.length, 1);
  assert.match(dropped[0].text, /farmland/);
  for (const l of kept) assert.ok(l.from.length > 0 || l.added === true, l.text);
  assert.deepEqual(kept.find(l => /influenza/.test(l.text)).from, [c]);
  assert.equal(kept.find(l => /bilateral/.test(l.text)).added, true);
  assert.deepEqual(kept.find(l => /Advertisement/.test(l.text)).from, [b]);
  assert.equal(checkLines([{ text: 'Carlill caught influenza; [s3]', from: [c] }], ss).kept[0].text, 'Carlill caught influenza',
    'a citation id written into the line is taken out');
  assert.ok(!kept.some(l => /farmland/.test(l.text)));
  void d;
});

test('no model: extractive lenses from the owner’s own sentences, labelled, every line cited', () => {
  const [sec] = docSections(PAGE);
  const r = settle(sec, { key: sec.key, engine: 'none', why: 'Apple Intelligence is off' });
  assert.equal(r.engine, 'extract');
  assert.equal(r.why, 'Apple Intelligence is off');
  assert.ok(r.title.length > 0);
  assert.equal(r.gist.length, 2, 'one line per paragraph');
  for (const l of [...r.gist, ...r.reformat.lines]) assert.ok(l.from.length > 0);
  assert.equal(reformatKind(sec.sentences), 'irac');
  assert.equal(r.reformat.kind, 'outline', 'IRAC needs the model; without it, the outline');
  assert.ok(keyTerms('Điều 385 Bộ luật Dân sự').includes('điều'));
  void extractive;
});

function harness(text) {
  const state = { text, writes: [], decos: 0 };
  const posts = [];
  let t = 1_000_000;
  const store = new Map();
  const rc = createRecense({
    getText: () => state.text,
    dispatch: spec => {
      if (spec.changes) {
        state.writes.push(spec);
        const { from, insert } = spec.changes;
        state.text = state.text.slice(0, from) + insert + state.text.slice(from);
      }
      if (spec.effects) state.decos++;
    },
    post: m => posts.push(m),
    storage: { getItem: k => store.get(k) ?? null, setItem: (k, v) => store.set(k, v) },
    now: () => t
  });
  return { rc, state, posts, advance: ms => { t += ms; } };
}

const modelReply = (sec, title) => ({
  key: sec.key, engine: 'model', title,
  page: [{ text: 'An advertisement can be a unilateral offer.', from: [sec.sentences[1].key] }],
  gist: [
    { text: 'A contract needs offer, acceptance and consideration.', from: [sec.sentences[0].key], para: sec.sentences[0].p },
    { text: 'Mrs Carlill caught influenza after using the smoke ball.', from: [sec.sentences[2].key], para: sec.sentences[2].p }
  ],
  reformat: { kind: 'irac', lines: [{ text: 'Is an advertisement an offer?', from: [], role: 'issue' }] }
});

test('nothing runs per keystroke: a section is recensed once quiet for 60 s and on power or battery above 30 %', () => {
  const h = harness(PAGE);
  h.rc.docChanged();
  assert.equal(h.rc.tick(), null, 'not quiet yet');
  h.advance(QUIET_MS);
  h.rc.setPowerState(false, 20);
  assert.equal(h.rc.tick(), null, 'battery at 20 %');
  h.rc.setPowerState(false, 45);
  const id = h.rc.tick();
  assert.ok(id);
  const sent = h.posts.find(p => p.recenseSections).recenseSections;
  assert.equal(sent.sections.length, 1);
  assert.equal(h.rc.tick(), null, 'never twice while on its way');
});

test('editing a sentence redoes only the lens lines that cite it', () => {
  const h = harness(PAGE);
  h.rc.setEnabled(true);
  const [sec] = h.rc.sections();
  const id = h.rc.recenseNow();
  assert.ok(h.rc.setSection(id, modelReply(sec, 'Unilateral offers')));
  h.rc.recenseDone(id);
  const edited = sec.sentences[2];
  h.state.text = h.state.text.replace('still caught influenza', 'then caught influenza');
  h.rc.docChanged();
  const [now] = h.rc.sections();
  assert.notEqual(now.key, sec.key);
  const old = h.rc.results.get(sec.key).gist;
  const { kept, stale } = reconcile(old, new Set(now.sentences.map(s => s.key)));
  assert.deepEqual(stale.map(l => l.from[0]), [edited.key]);
  assert.equal(kept.length, 1);
  const blocks = lensBlocks(h.rc.sections(), 'gist', { results: h.rc.results, stale: new Map([[now.key, kept]]) });
  assert.equal(blocks[0].tag, 'earlier');
  assert.equal(blocks[0].lines.length, 1, 'the untouched lines stay on screen until the section is recensed');
  // Only the edited section goes out again.
  h.advance(QUIET_MS);
  h.rc.tick();
  const last = h.posts.filter(p => p.recenseSections).at(-1).recenseSections;
  assert.deepEqual(last.sections.map(s => s.key), [now.key]);
});

test('a new chapter title does not appear while the Chapters panel is open', () => {
  const h = harness(PAGE);
  const [sec] = h.rc.sections();
  h.rc.freeze();                                   // the panel opens
  const id = h.rc.recenseNow();
  h.rc.setSection(id, modelReply(sec, 'Unilateral offers'));
  h.rc.recenseDone(id);
  let pages = chapterEntries(h.state.text, { sections: h.rc.sections(), titles: h.rc.titles(), lastDone: h.rc.lastDone() });
  assert.ok(!pages[0].entries.some(e => e.title === 'Unilateral offers'), 'held while open');
  assert.ok(pages[0].entries.some(e => e.kind === 'new'));
  h.rc.unfreeze();                                 // closed …
  h.rc.freeze();                                   // … and opened again
  pages = chapterEntries(h.state.text, { sections: h.rc.sections(), titles: h.rc.titles(), lastDone: h.rc.lastDone() });
  const e = pages[0].entries.find(x => x.title === 'Unilateral offers');
  assert.equal(e.kind, 'recensed');
  assert.equal(e.gist, 'An advertisement can be a unilateral offer.');
  assert.match(e.listen, /min/);
});

test('"Make heading" is the only path that writes into the page', () => {
  const h = harness(PAGE);
  h.rc.setEnabled(true);
  for (const lens of ['gist', 'reformat', 'source']) h.rc.setLens(lens);
  const [sec] = h.rc.sections();
  const id = h.rc.recenseNow();
  h.rc.setSection(id, modelReply(sec, 'Unilateral offers'));
  h.rc.recenseDone(id);
  h.rc.setSource('s0', { keys: [], lines: [] });
  h.rc.docChanged();
  h.advance(QUIET_MS);
  h.rc.tick();
  h.rc.freeze();
  assert.equal(h.state.writes.length, 0, 'recensing, lenses, the layer and the panel never write');
  assert.equal(h.state.text, PAGE);
  assert.ok(h.rc.makeHeading(sec.key));
  assert.equal(h.state.writes.length, 1);
  assert.match(h.state.text, /\n# Unilateral offers\n\nA contract needs/);
  assert.equal(h.rc.makeHeading('missing'), false);
});

test('only a saved page is written to Recensed/<id>.json, as Lines with chapters', () => {
  const h = harness(PAGE);
  let [sec] = h.rc.sections();
  let id = h.rc.recenseNow();
  h.rc.setSection(id, modelReply(sec, 'Unilateral offers'));
  assert.ok(!h.posts.some(p => p.recenseSave), 'unsaved: the app cache only');
  const saved = PAGE.replace('2026\n', '2026\n<!-- saved abc123 -->\n');
  const h2 = harness(saved);
  [sec] = h2.rc.sections();
  id = h2.rc.recenseNow();
  h2.rc.setSection(id, modelReply(sec, 'Unilateral offers'));
  const out = h2.posts.find(p => p.recenseSave).recenseSave;
  assert.equal(out.pageId, 'abc123');
  const doc = JSON.parse(out.json);
  assert.equal(doc.lines.length, 4);
  assert.deepEqual(doc.chapters.map(c => c.title), ['Unilateral offers']);
  assert.ok(doc.sections[0].gist.every(l => Array.isArray(l.words) && (l.from.length || l.added)));
});

test('the wing card takes the caret paragraph’s lens line with its source, only while the editor has focus', () => {
  const h = harness(PAGE);
  h.rc.setEnabled(true);
  const [sec] = h.rc.sections();
  const id = h.rc.recenseNow();
  h.rc.setSection(id, modelReply(sec, 'Unilateral offers'));
  const card = h.rc.cardFor(sec.sentences[2].from + 3);
  assert.match(card.original, /influenza/);
  assert.match(card.translation, /Mrs Carlill used/);
  assert.equal(h.rc.cardFor(-1), null);
});

const THREE = `Monday, November 9, 2026

A contract needs an offer and an acceptance. The offer must be definite. An invitation to treat is not an offer.

Consideration is something of value given in exchange. Past consideration is no consideration. A promise to pay later counts.

Carlill v Carbolic Smoke Ball Co held that an advertisement was a unilateral offer. Mrs Carlill accepted by using the smoke ball. The company had to pay her the reward.`;

test('Gist: a 3-paragraph page gives exactly 3 paragraph lines and a 3-line page gist, whatever the model sent', () => {
  const [sec] = docSections(THREE);
  const ss = sec.sentences;
  assert.equal(new Set(ss.map(s => s.p)).size, 3);
  // A model that wrote one line per sentence (the M1 shape) and one page line: still 3 + 3.
  const perSentence = settle(sec, { key: sec.key, engine: 'model', title: 'Contract formation',
    page: [{ text: 'A contract needs offer, acceptance and consideration.', from: [ss[0].key, ss[3].key] }],
    gist: ss.map(s => ({ text: s.text, from: [s.key] })) });
  assert.equal(perSentence.gist.length, 3, 'one Gist line per paragraph');
  assert.deepEqual(perSentence.gist.map(l => ss.find(s => s.key === l.from[0]).p), [...new Set(ss.map(s => s.p))]);
  assert.equal(perSentence.page.length, 3, 'a 3-line page gist');
  assert.equal(perSentence.page[0].text, 'A contract needs offer, acceptance and consideration.');
  assert.ok(perSentence.page.slice(1).every(l => l.extract), 'filled lines say they are extracts');
  // The shape the app now asks for: one field per paragraph, three page lines.
  const ps = [...new Set(ss.map(s => s.p))];
  const shaped = settle(sec, { key: sec.key, engine: 'model', title: 'Contract formation',
    page: [
      { text: 'A contract needs a definite offer and an acceptance.', from: [ss[0].key, ss[1].key] },
      { text: 'Consideration is value given in exchange; past consideration does not count.', from: [ss[3].key, ss[4].key] },
      { text: 'Carlill: an advertisement can be a unilateral offer.', from: [ss[6].key] }],
    gist: [
      { text: 'An offer must be definite; an invitation to treat is not an offer.', from: [ss[1].key, ss[2].key], para: ps[0] },
      { text: 'Consideration is value given in exchange, never past.', from: [ss[3].key, ss[4].key], para: ps[1] },
      { text: 'Using the smoke ball accepted the advertisement’s unilateral offer.', from: [ss[6].key, ss[7].key], para: ps[2] },
      { text: 'A fourth line the page did not ask for.', from: [ss[8].key], para: ps[2] }] });
  assert.equal(shaped.gist.length, 3);
  assert.equal(shaped.page.length, 3);
  assert.ok(![...shaped.gist, ...shaped.page].some(l => l.extract), 'all the model’s own lines, checked');
  // A page line that repeats a paragraph line is replaced (the M2 check found the model copying them).
  const copied = settle(sec, { key: sec.key, engine: 'model', title: 'x',
    page: [{ text: 'Consideration is value given in exchange, never past.', from: [ss[3].key] }],
    gist: [{ text: 'Consideration is value given in exchange, never past.', from: [ss[3].key, ss[4].key], para: ps[1] }] });
  assert.equal(copied.page.length, 3);
  assert.ok(!copied.page.some(l => l.text === 'Consideration is value given in exchange, never past.'));
  // No model at all: the same shape from the owner's sentences.
  const ext = settle(sec, { key: sec.key, engine: 'none', why: 'off' });
  assert.equal(ext.gist.length, 3);
  assert.equal(ext.page.length, 3);
  const blocks = lensBlocks([sec], 'gist', { results: new Map([[sec.key, shaped]]) });
  assert.equal(blocks[0].lines.length, 3, 'the page gist sits above the section');
  assert.deepEqual(blocks.slice(1).map(b => b.lines.length), [1, 1, 1], 'one line under each paragraph');
});

test('a lens line is in one language: an English Gist of a Vietnamese sentence is fully English', () => {
  const MIXED = `Tuesday, November 10, 2026

Theo Điều 385 Bộ luật Dân sự, hợp đồng là sự thỏa thuận giữa các bên. A contract also needs consideration in common law.`;
  const [sec] = docSections(MIXED);
  const [vi, en] = sec.sentences;
  const sourceIn = { [vi.key]: 'According to Article 385 of the Civil Code, a contract is an agreement between the parties.' };
  const r = settle(sec, { key: sec.key, engine: 'model', title: 'What a contract is', lang: 'en', sourceIn,
    page: [
      { text: 'Under Article 385 of the Civil Code, a contract is an agreement between the parties.', from: [vi.key], lang: 'en' },
      { text: 'Common law adds consideration.', from: [en.key], lang: 'en' },
      { text: 'A contract is a thỏa thuận giữa các bên.', from: [vi.key], lang: 'en' }],                  // mixed: dropped
    gist: [{ text: 'The hợp đồng needs consideration giữa các bên.', from: [vi.key, en.key], lang: 'en', para: vi.p }] });
  assert.equal(r.page[0].text, 'Under Article 385 of the Civil Code, a contract is an agreement between the parties.',
    'an English line citing a Vietnamese sentence passes against its translation');
  assert.equal(r.page[1].text, 'Common law adds consideration.');
  assert.ok(!r.page.some(l => /thỏa thuận giữa/.test(l.text) && !l.extract), 'the mixed page line was dropped');
  assert.equal(r.gist.length, 1);
  assert.equal(r.gist[0].extract, true, 'the mixed paragraph line gives way to the owner’s own sentence');
  assert.ok(r.dropped >= 2);
  for (const l of [...r.page, ...r.gist].filter(l => !l.extract)) assert.equal(isMixed({ ...l, lang: 'en' }), false, l.text);
  assert.equal(isMixed({ text: 'Hợp đồng là sự thỏa thuận of the parties and the court.', lang: 'vi' }), true);
  assert.equal(isMixed({ text: 'Hợp đồng là sự thỏa thuận giữa các bên.', lang: 'vi' }), false);
  assert.equal(isMixed({ text: 'The text of Bộ luật is short.', lang: 'en' }), true);
  assert.equal(isMixed({ text: 'The Code’s Article 385 defines it.', lang: 'en' }), false);
});

test('a statute, article, case name or glossary term cited in its own language is not mixing; a half-translated clause is', () => {
  const VI = 'The court said the deposit of £1,000 showed the company meant its promise. Theo Điều 385 Bộ luật Dân sự 2015, hợp đồng là sự thỏa thuận giữa các bên.';
  const ok = { text: 'The £1,000 deposit showed the company meant its promise, aligning with Theo Điều 385 Bộ luật Dân sự 2015.', lang: 'en' };
  assert.equal(isMixed(ok, [VI]), false, 'Điều 385 and Bộ luật Dân sự 2015 are cited as written');
  assert.equal(isMixed(ok, ['A sentence that does not hold the reference.']), true, 'only spans found word for word in the source');
  const half = { text: 'Under Điều 385 Bộ luật Dân sự 2015, a contract is a thỏa thuận giữa các bên.', lang: 'en' };
  assert.equal(isMixed(half, [VI]), true, 'the half-translated clause still mixes');
  assert.match(ownLanguageProse(half.text, [VI]), /thỏa thuận giữa các bên/);
  const gl = { text: 'The plaintiff claimed bồi thường thiệt hại for the loss.', lang: 'en' };
  assert.equal(isMixed(gl, ['Nguyên đơn yêu cầu bồi thường thiệt hại.']), true);
  assert.equal(isMixed(gl, ['Nguyên đơn yêu cầu bồi thường thiệt hại.'], ['bồi thường thiệt hại']), false, 'a glossary term');
  const [sec] = docSections(`Wednesday, November 11, 2026\n\n${VI}`);
  const r = settle(sec, { key: sec.key, engine: 'model', title: 'Deposit', lang: 'en',
    page: [ok], gist: [{ ...ok, from: [sec.sentences[0].key, sec.sentences[1].key], para: sec.sentences[0].p }] });
  assert.equal(r.gist[0].text, ok.text, 'the line with the cited statute stays in');
  assert.ok(!r.gist[0].extract);
});

test('Retell: per paragraph a plain line and one retold in the other language, each checked; no model, no retell', () => {
  const [sec] = docSections(THREE);
  const ss = sec.sentences, ps = [...new Set(ss.map(s => s.p))];
  const sourceOther = Object.fromEntries(ss.map(s => [s.key, `[vi] ${s.text}`]));
  sourceOther[ss[0].key] = 'Hợp đồng cần có đề nghị và chấp nhận.';
  const r = settleExtra(sec, 'retell', { key: sec.key, engine: 'model', lang: 'en', other: 'vi', sourceOther, retell: { lines: [
    { text: 'To make a contract, someone offers and someone accepts.', from: [ss[0].key], role: 'plain', para: ps[0], lang: 'en' },
    { text: 'Muốn có hợp đồng, phải có đề nghị và chấp nhận.', from: [ss[0].key], role: 'other', para: ps[0], lang: 'vi' },
    { text: 'Consideration is something of value given in exchange.', from: [ss[3].key], role: 'plain', para: ps[1], lang: 'en' },
    { text: 'Đền bù is a thing of value given in exchange.', from: [ss[3].key], role: 'other', para: ps[1], lang: 'vi' }    // mixed: dropped
  ] } });
  assert.deepEqual(r.lines.map(l => l.role), ['plain', 'other', 'plain']);
  assert.equal(r.lines[1].lang, 'vi', 'the other-language line is checked against the sentence’s translation into it');
  assert.equal(r.dropped, 1);
  const none = settleExtra(sec, 'retell', { key: sec.key, engine: 'none', why: 'off' });
  assert.equal(none.lines.length, 0);
  assert.match(none.why, /needs the on-device model/);
  const blocks = lensBlocks([sec], 'retell', { results: new Map([[sec.key, { ...settle(sec, null), extra: { retell: r } }]]) });
  assert.deepEqual(blocks.map(b => b.lines.length), [2, 1], 'under their paragraphs');
});

test('Ask: question and answer both checked, the answer behind its own button; no model, cloze from key terms', () => {
  const [sec] = docSections(THREE);
  const ss = sec.sentences;
  const x = settleExtra(sec, 'ask', { key: sec.key, engine: 'model', ask: { lines: [
    { text: 'What did Carlill v Carbolic Smoke Ball Co hold about the advertisement?', from: [ss[6].key], role: 'question' },
    { text: 'That the advertisement was a unilateral offer.', from: [ss[6].key], role: 'answer' },
    { text: 'What is the penalty for breach in Ohio?', from: [], role: 'question' },
    { text: 'Ten years in a farmland lease.', from: [ss[0].key], role: 'answer' }          // not in the notes: both go
  ] } });
  assert.equal(x.lines.length, 1);
  assert.equal(x.lines[0].answer, 'That the advertisement was a unilateral offer.');
  const cloze = askExtract(sec);
  assert.equal(cloze.length, 3, 'a card per paragraph');
  for (const c of cloze) {
    assert.match(c.text, /_____/);
    assert.equal(ss.find(s => s.key === c.from[0]).text, c.text.replace('_____', c.answer));
  }
  assert.equal(settleExtra(sec, 'ask', { key: sec.key, engine: 'none' }).engine, 'key terms');
});

test('Reapply: the rule is cited, the new facts and question say added, and your answer is kept beside them', () => {
  const h = harness(THREE);
  h.rc.setEnabled(true);
  h.rc.setLens('reapply');
  assert.ok(LENSES.includes('retell') && LENSES.includes('ask') && LENSES.includes('reapply'));
  const [sec] = h.rc.sections();
  const ss = sec.sentences;
  const id = h.rc.recenseNow();
  const sent = h.posts.filter(p => p.recenseSections).at(-1).recenseSections;
  assert.deepEqual(sent.lenses, ['gist', 'reformat', 'reapply'], 'the lens on screen is asked for with the rest');
  h.rc.setSection(id, { ...modelReply(sec, 'Offers'), reapply: { lines: [
    { text: 'An advertisement can be a unilateral offer accepted by using the smoke ball.', from: [ss[6].key, ss[7].key], role: 'rule' },
    { text: 'A shop promises a free bike to anyone who runs a marathon; Lan runs one.', from: [], role: 'facts', added: true },
    { text: 'Must the shop give Lan the bike?', from: [], role: 'question', added: true }] } });
  h.rc.recenseDone(id);
  const r = h.rc.results.get(sec.key).extra.reapply;
  assert.deepEqual(r.lines.map(l => [l.role, Boolean(l.added)]), [['rule', false], ['facts', true], ['question', true]]);
  const [b] = lensBlocks(h.rc.sections(), 'reapply', { results: h.rc.results, answers: h.rc.answers });
  assert.ok(b.answerKey.startsWith(sec.key));
  h.rc.setAnswer(b.answerKey, 'Yes: the advert is a unilateral offer; running the marathon accepts it.');
  const [b2] = lensBlocks(h.rc.sections(), 'reapply', { results: h.rc.results, answers: h.rc.answers });
  assert.match(b2.answer, /unilateral offer/);
  assert.equal(h.state.writes.length, 0, 'the answer never goes into the page');
  // Switching lens asks only for what is missing.
  h.rc.setLens('retell');
  const last = h.posts.filter(p => p.recenseSections).at(-1).recenseSections;
  assert.deepEqual(last.lenses, ['retell']);
});
