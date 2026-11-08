import test from 'node:test';
import assert from 'node:assert/strict';

import {
  formatTimestamp,
  normalizeCues,
  activeCueIndexAt,
  bookmarkCue,
  toggleBookmarkCue,
  annotateCue,
  createTranscriptPane,
  createAudioSidecar,
  extractDocumentSections,
  summarizeSectionOffline,
  summarizeAllSections,
  speakSectionSummary
} from '../src/audio.js';
import { PAGE_JOINER } from '../src/pages.js';

function countTags(el, tag) {
  if (!el) return 0;
  let count = el.tagName === tag.toUpperCase() ? 1 : 0;
  for (const child of el.children || []) {
    count += countTags(child, tag);
  }
  return count;
}

function countPlaceholders(el) {
  if (!el) return 0;
  let count = (el.getAttribute?.('placeholder') || el.placeholder) ? 1 : 0;
  for (const child of el.children || []) {
    count += countPlaceholders(child);
  }
  return count;
}

test('P4 audio: formatTimestamp formats MM:SS and H:MM:SS accurately', () => {
  assert.equal(formatTimestamp(0), '00:00');
  assert.equal(formatTimestamp(5), '00:05');
  assert.equal(formatTimestamp(59.9), '00:59');
  assert.equal(formatTimestamp(60), '01:00');
  assert.equal(formatTimestamp(75), '01:15');
  assert.equal(formatTimestamp(599), '09:59');
  assert.equal(formatTimestamp(3600), '1:00:00');
  assert.equal(formatTimestamp(3665), '1:01:05');
});

test('P4 audio: activeCueIndexAt live transcript tracking as playback time advances', () => {
  const cues = [
    { id: 'c1', start: 1.0, end: 3.5, text: 'First spoken cue' },
    { id: 'c2', start: 4.0, end: 7.0, text: 'Second spoken cue' },
    { id: 'c3', start: 8.0, end: 12.0, text: 'Third spoken cue' }
  ];

  // Before first cue starts
  assert.equal(activeCueIndexAt(cues, 0.0), -1);
  assert.equal(activeCueIndexAt(cues, 0.9), -1);

  // Exact span of first cue
  assert.equal(activeCueIndexAt(cues, 1.0), 0);
  assert.equal(activeCueIndexAt(cues, 2.5), 0);
  assert.equal(activeCueIndexAt(cues, 3.5), 0);

  // Gap between cue 1 and cue 2 (karaoke holds latest cue started)
  assert.equal(activeCueIndexAt(cues, 3.8), 0);

  // Second cue
  assert.equal(activeCueIndexAt(cues, 4.0), 1);
  assert.equal(activeCueIndexAt(cues, 6.0), 1);
  assert.equal(activeCueIndexAt(cues, 7.0), 1);

  // Gap between cue 2 and cue 3
  assert.equal(activeCueIndexAt(cues, 7.5), 1);

  // Third cue
  assert.equal(activeCueIndexAt(cues, 8.0), 2);
  assert.equal(activeCueIndexAt(cues, 11.5), 2);

  // Beyond last cue (holds last cue)
  assert.equal(activeCueIndexAt(cues, 15.0), 2);

  // Empty or invalid cues
  assert.equal(activeCueIndexAt([], 2.0), -1);
  assert.equal(activeCueIndexAt(null, 2.0), -1);
});

test('P4 audio: bookmarkCue and toggleBookmarkCue update state, post UI snap & audio action', () => {
  const uiMessages = [];
  const audioMessages = [];
  const fakeWindow = {
    webkit: {
      messageHandlers: {
        ui: { postMessage: m => uiMessages.push(m) },
        audio: { postMessage: m => audioMessages.push(m) }
      }
    }
  };

  const state = {
    cues: [
      { id: 'cue-0', start: 12.5, end: 15.0, text: 'The court holds that foreseeability is required.', bookmarked: false },
      { id: 'cue-1', start: 16.0, end: 19.0, text: 'Judgment affirmed.', bookmarked: false }
    ],
    bookmarks: []
  };

  const bm = bookmarkCue(state, 0, 'Essential holding', { globalObj: fakeWindow });

  assert.ok(bm);
  assert.equal(state.cues[0].bookmarked, true);
  assert.equal(state.bookmarks.length, 1);
  assert.equal(state.bookmarks[0].cueId, 'cue-0');
  assert.equal(state.bookmarks[0].time, 12.5);
  assert.equal(state.bookmarks[0].note, 'Essential holding');

  // UI bridge received snap haptic
  assert.deepEqual(uiMessages, [{ haptic: 'snap' }]);

  // Audio bridge received bookmark action
  assert.deepEqual(audioMessages, [{
    action: 'bookmark',
    cueId: 'cue-0',
    time: 12.5,
    text: 'The court holds that foreseeability is required.',
    note: 'Essential holding'
  }]);

  // Updating the bookmark on the same cue updates note rather than duplicating
  bookmarkCue(state, 0, 'Revised note', { globalObj: fakeWindow });
  assert.equal(state.bookmarks.length, 1);
  assert.equal(state.bookmarks[0].note, 'Revised note');

  // toggleBookmarkCue removes bookmark when cue is already bookmarked
  toggleBookmarkCue(state, 0, '', { globalObj: fakeWindow });
  assert.equal(state.cues[0].bookmarked, false);
  assert.equal(state.bookmarks.length, 0);
  assert.ok(audioMessages.some(m => m.action === 'unbookmark' && m.cueId === 'cue-0'));
});

test('P4 audio: annotateCue attaches text, formats [@MM:SS] reference, inserts to page & posts bridge message', () => {
  const audioMessages = [];
  const insertedBlocks = [];
  const fakeWindow = {
    webkit: {
      messageHandlers: {
        audio: { postMessage: m => audioMessages.push(m) }
      }
    }
  };

  const state = {
    cues: [
      { id: 'cue-0', start: 75.0, end: 80.0, text: 'A duty of care arose under the circumstances.', annotation: '' }
    ]
  };

  const res = annotateCue(state, 0, 'Compare with Palsgraf dissent', {
    onInsertToPage: ref => insertedBlocks.push(ref),
    globalObj: fakeWindow
  });

  assert.equal(state.cues[0].annotation, 'Compare with Palsgraf dissent');
  assert.equal(res.reference, '[@01:15] A duty of care arose under the circumstances. — Compare with Palsgraf dissent');
  assert.deepEqual(insertedBlocks, [
    '[@01:15] A duty of care arose under the circumstances. — Compare with Palsgraf dissent'
  ]);

  assert.deepEqual(audioMessages, [{
    action: 'annotate',
    cueId: 'cue-0',
    time: 75.0,
    annotation: 'Compare with Palsgraf dissent'
  }]);
});

test('P4 audio: createTranscriptPane has zero buttons and zero placeholders at rest, renders ink SVG, and supports gestures', () => {
  const seekCalls = [];
  const insertedBlocks = [];
  const fakeWindow = {
    webkit: {
      messageHandlers: {
        audio: { postMessage: m => seekCalls.push(m) },
        ui: { postMessage: () => {} }
      }
    }
  };

  const sidecar = createAudioSidecar({
    globalObj: fakeWindow,
    onInsertToPage: ref => insertedBlocks.push(ref)
  });

  const pane = sidecar.createTranscriptPane();

  // Initially hidden
  assert.equal(pane.element.hidden, true);

  // Playing with cues automatically un-hides the pane
  sidecar.setAudioTranscript({
    playing: true,
    title: 'Oral Argument - Smith v. Jones',
    cues: [
      {
        id: 'c1',
        start: 0.0,
        end: 4.0,
        text: 'May it please the court.',
        speaker: 'Counsel',
        bookmarked: false,
        annotation: '',
        inkStrokes: [
          { points: [[10, 15], [25, 30]], color: '#38bdf8', width: 2 }
        ]
      },
      {
        id: 'c2',
        start: 4.5,
        end: 8.0,
        text: 'The statutory text must govern.',
        speaker: 'Judge',
        bookmarked: true,
        annotation: 'Statutory basis',
        inkStrokes: []
      }
    ]
  });

  assert.equal(pane.element.hidden, false);

  // CRITIC GAP 1 & 4 CHECK: Assert zero <button> elements and zero placeholder strings inside createTranscriptPane
  assert.equal(countTags(pane.element, 'BUTTON'), 0, 'Must have zero <button> elements at rest');
  assert.equal(countPlaceholders(pane.element), 0, 'Must have zero placeholder strings');

  const cuesContainer = pane.element.children[1];
  assert.equal(cuesContainer.children.length, 2);

  const cue0El = cuesContainer.children[0];
  const cue1El = cuesContainer.children[1];

  // Check quiet dot: cue 0 is unbookmarked (empty string), cue 1 is bookmarked ('●')
  const dot0 = cue0El.children.find(c => c.classList.contains('rc-transcript-cue-dot'));
  const dot1 = cue1El.children.find(c => c.classList.contains('rc-transcript-cue-dot'));
  assert.equal(dot0?.textContent, '');
  assert.equal(dot1?.textContent, '●');

  // Check note text: cue 0 has no annotation (hidden), cue 1 has annotation (visible)
  const note0 = cue0El.children.find(c => c.classList.contains('rc-transcript-cue-note'));
  const note1 = cue1El.children.find(c => c.classList.contains('rc-transcript-cue-note'));
  assert.equal(note0?.hidden, true);
  assert.equal(note1?.hidden, false);
  assert.equal(note1?.textContent, 'Statutory basis');

  // CRITIC GAP 2 CHECK: Verify <svg class="rc-cue-ink-svg"> renders cue.inkStrokes
  const inkSvg0 = cue0El.children.find(c => c.classList.contains('rc-cue-ink-svg'));
  assert.ok(inkSvg0, 'Must include <svg class="rc-cue-ink-svg">');
  assert.equal(inkSvg0.children.length, 1);
  assert.equal(inkSvg0.children[0].tagName, 'PATH');
  assert.ok(inkSvg0.children[0].getAttribute('d').includes('M 10 15'));

  // Drawing on cue with pointerType: 'pen' captures new stroke and marks cue annotated
  cue0El.dispatchEvent({ type: 'pointerdown', pointerType: 'pen', clientX: 20, clientY: 25, pressure: 0.6 });
  cue0El.dispatchEvent({ type: 'pointermove', pointerType: 'pen', clientX: 40, clientY: 45, pressure: 0.7 });
  cue0El.dispatchEvent({ type: 'pointerup', pointerType: 'pen' });

  assert.equal(sidecar.getState().cues[0].inkStrokes.length, 2);
  assert.ok(sidecar.getState().cues[0].annotation.length > 0);

  // Progressive disclosure: right-click reveals borderless placeholder-free annotation input
  const annotInput0 = cue0El.children.find(c => c.classList.contains('rc-transcript-annot-input'));
  assert.equal(annotInput0.hidden, true);
  cue0El.dispatchEvent({ type: 'contextmenu' });
  assert.equal(annotInput0.hidden, false);

  // Committing annotation commits to sidecar and page insertion
  annotInput0.value = 'Counsel opened arguments';
  cue0El.dispatchEvent({ type: 'keydown', key: 'Enter', target: annotInput0 });
  assert.equal(annotInput0.hidden, true);
  assert.equal(sidecar.getState().cues[0].annotation, 'Counsel opened arguments');
  assert.ok(insertedBlocks.some(b => b.includes('Counsel opened arguments')));

  // Gestures: Swiping left-to-right (dx >= 36) toggles bookmark on cue 0
  cue0El.dispatchEvent({ type: 'touchstart', touches: [{ clientX: 10, clientY: 50 }] });
  cue0El.dispatchEvent({ type: 'touchend', changedTouches: [{ clientX: 60, clientY: 52 }] });
  assert.equal(sidecar.getState().cues[0].bookmarked, true);
  assert.equal(dot0?.textContent, '●');

  // Double-clicking cue 0 toggles bookmark back off
  cue0El.dispatchEvent({ type: 'dblclick' });
  assert.equal(sidecar.getState().cues[0].bookmarked, false);
  assert.equal(dot0?.textContent, '');

  // Clicking a cue seeks audio
  cue1El.dispatchEvent({ type: 'click' });
  assert.ok(seekCalls.some(m => m.action === 'seek' && m.time === 4.5));

  // Advance time: highlights active cue
  sidecar.updateTime(5.0);
  assert.equal(cue0El.classList.contains('rc-transcript-cue-active'), false);
  assert.equal(cue1El.classList.contains('rc-transcript-cue-active'), true);

  // Clearing cues re-hides the pane
  sidecar.setAudioTranscript({ playing: false, cues: [] });
  assert.equal(pane.element.hidden, true);
});

test('P4 audio: extractDocumentSections splits by headings, legal sections §, or topic paragraphs', () => {
  // 1. Markdown headings and legal sections
  const markdownDoc = `# Case Overview
The court reviewed standard of care issues under maritime law.

## Liability Analysis
The vessel operator must exercise reasonable vigilance.

§ 402A Strict Liability
Where a defect renders the equipment unreasonably dangerous, strict liability attaches.`;

  const sections = extractDocumentSections(markdownDoc);
  assert.equal(sections.length, 3);
  assert.equal(sections[0].title, 'Case Overview');
  assert.equal(sections[1].title, 'Liability Analysis');
  assert.equal(sections[2].title, '402A Strict Liability');
  assert.equal(sections[2].kind, 'section');

  // 2. Draftpad document with page dividers
  const draftpadMultiPage = [
    'Friday, November 6, 2026\n\n# Page 1 Heading\nPage 1 body text.',
    'Monday, November 2, 2026\n\n# Page 2 Heading\nPage 2 body text.'
  ].join(PAGE_JOINER);

  const page1Sections = extractDocumentSections(draftpadMultiPage, 1);
  assert.equal(page1Sections.length, 1);
  assert.equal(page1Sections[0].title, 'Page 2 Heading');
  assert.equal(page1Sections[0].pageIndex, 1);

  // 3. Document without explicit headings: splits by topic paragraphs
  const plainNotes = `Friday, November 6, 2026

The initial contract was negotiated in Tokyo under Japanese law. All payments were scheduled in Yen.

Because the counterparty failed to deliver cargo, the buyer terminated the agreement. The arbitration clause mandates ICC proceedings in Paris.`;

  const paragraphSections = extractDocumentSections(plainNotes);
  assert.ok(paragraphSections.length >= 2);
  assert.equal(paragraphSections[0].kind, 'paragraph');
  assert.ok(paragraphSections[0].text.includes('Tokyo'));
  assert.ok(paragraphSections[1].text.includes('arbitration clause'));
});

test('P4 audio: summarizeSectionOffline pure on-device multilingual legal summarizer (EN, FR, VI)', () => {
  // English legal summary
  const englishSection = {
    title: 'Negligence & Duty of Care',
    text: `The plaintiff filed an action seeking recovery for property damages following a pipeline rupture.
Under established common law doctrine, a defendant must owe a foreseeable duty of care to the claimant.
The trial judge admitted circumstantial evidence of structural wear.
The appellate panel held that failure to conduct ultrasonic inspection constitutes a breach of duty.
Therefore, the judgment in favor of the plaintiff is affirmed.`
  };

  const enSummary = summarizeSectionOffline(englishSection);
  assert.ok(enSummary.summary.length > 0);
  assert.ok(enSummary.bullets.length > 0);
  assert.ok(enSummary.summary.includes('must') || enSummary.summary.includes('held') || enSummary.summary.includes('affirmed'));
  assert.ok(!enSummary.summary.includes('**')); // Clean spoken text with no markdown leftovers

  // French legal summary
  const frenchSection = {
    title: 'Responsabilité contractuelle',
    text: `Les parties ont conclu un contrat de fourniture industrielle en date du 15 mars.
Selon l'article 1231 du Code civil, le débiteur doit réparer le dommage causé par l'inexécution.
La cour d'appel a jugé que le fournisseur n'a pas respecté les spécifications techniques.
En conséquence, la résiliation judiciaire du contrat est prononcée aux torts du défendeur.`
  };

  const frSummary = summarizeSectionOffline(frenchSection);
  assert.ok(frSummary.summary.length > 0);
  assert.ok(frSummary.summary.includes('doit') || frSummary.summary.includes('jugé') || frSummary.summary.includes('En conséquence'));

  // Vietnamese legal summary
  const vietnameseSection = {
    title: 'Vi phạm hợp đồng thương mại',
    text: `Các bên đã ký kết hợp đồng mua bán hàng hóa quốc tế với điều kiện giao hàng CIF cảng Hải Phòng.
Theo quy định của Luật Thương mại, bên bán phải giao hàng đúng số lượng và tiêu chuẩn chất lượng đã cam kết.
Hội đồng Trọng tài kết luận rằng hàng hóa bị hư hỏng do bao bì không phù hợp.
Do đó, bị đơn phải bồi thường toàn bộ tổn thất thực tế phát sinh cho nguyên đơn.`
  };

  const viSummary = summarizeSectionOffline(vietnameseSection);
  assert.ok(viSummary.summary.length > 0);
  assert.ok(viSummary.summary.includes('quy định') || viSummary.summary.includes('phải') || viSummary.summary.includes('Do đó') || viSummary.summary.includes('kết luận'));
});

test('P4 audio: summarizeAllSections enriches all sections in a document', () => {
  const doc = `# Section One
A carrier must exercise utmost care. The court held that strict inspection standards apply.

# Section Two
Under international maritime agreements, liability is limited. Therefore damages cannot exceed statutory limits.`;

  const all = summarizeAllSections(doc);
  assert.equal(all.length, 2);
  assert.ok(all[0].summary.includes('must') || all[0].summary.includes('held'));
  assert.ok(all[1].summary.includes('liability') || all[1].summary.includes('limits'));
  assert.ok(Array.isArray(all[0].bullets));
  assert.ok(Array.isArray(all[1].bullets));
});

test('P4 audio: speakSectionSummary supports .content and .body, posts to native bridge, and falls back to local speechSynthesis', () => {
  const audioBridgeCalls = [];
  const fakeNativeWindow = {
    webkit: {
      messageHandlers: {
        audio: { postMessage: m => audioBridgeCalls.push(m) }
      }
    }
  };

  // CRITIC GAP 3 & 4 CHECK: Object with .content instead of .text
  const secWithContent = {
    id: 's1',
    title: 'Claim Obviousness',
    content: 'The prior art references teach every limitation of claim one. The court held that combining the references was obvious to a person of ordinary skill. Therefore claim one is invalid.'
  };

  const resNative = speakSectionSummary(secWithContent, { globalObj: fakeNativeWindow });
  assert.equal(resNative.spokenVia, 'native');
  assert.equal(audioBridgeCalls.length, 1);
  assert.equal(audioBridgeCalls[0].action, 'speakSummary');
  assert.equal(audioBridgeCalls[0].sectionId, 's1');
  assert.equal(audioBridgeCalls[0].title, 'Claim Obviousness');
  assert.ok(audioBridgeCalls[0].text.length > 0);
  assert.ok(audioBridgeCalls[0].text.includes('obvious') || audioBridgeCalls[0].text.includes('invalid') || audioBridgeCalls[0].text.includes('held'));

  // Also test object with .body instead of .text
  const secWithBody = {
    id: 's2',
    title: 'Contract Termination',
    body: 'A party must give notice within thirty days. The arbitrator held that late notice terminates the claim.'
  };
  const resBody = speakSectionSummary(secWithBody, { globalObj: fakeNativeWindow });
  assert.equal(resBody.spokenVia, 'native');
  assert.equal(audioBridgeCalls.length, 2);
  assert.ok(audioBridgeCalls[1].text.includes('must') || audioBridgeCalls[1].text.includes('held'));

  // Standalone browser fallback with SpeechSynthesis
  const spokenUtterances = [];
  const fakeWebWindow = {
    SpeechSynthesisUtterance: function(text) {
      this.text = text;
      this.lang = 'en-US';
      this.voice = null;
    },
    speechSynthesis: {
      getVoices() {
        return [
          { name: 'Online Voice', localService: false, lang: 'en-US' },
          { name: 'Apple Samantha (Enhanced)', localService: true, lang: 'en-US' }
        ];
      },
      speak(utt) {
        spokenUtterances.push(utt);
      }
    }
  };

  const resWeb = speakSectionSummary(secWithContent, { globalObj: fakeWebWindow });
  assert.equal(resWeb.spokenVia, 'speechSynthesis');
  assert.equal(spokenUtterances.length, 1);
  assert.equal(spokenUtterances[0].voice?.localService, true); // Verified offline local voice selection
});
