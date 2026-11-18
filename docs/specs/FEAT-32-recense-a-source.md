# FEAT-32 · Recense a source: a page, a song or a video becomes one item you can read, hear and translate, offline

From: owner 2026-11-18 ("Recense equivalent of reader mode: find text or audio or video with audio, download offline in the appless hub and the app; AI narration; translation in Vietnamese, French, English, switch between all via the original source; recense in a different language, or learn side by side with the original") · Status: `[ ]` spec only · Effort: high, in slices

## Verdict first
- **The owner's idea is mostly assembled already.** Four of its five parts exist as separate pieces. What is missing is the front door (a link or a page in) and one join (narration with word timings, so a page plays like any recording).
- **The pasted Safari/Zen/Arc skin advice is a UI skin, not this feature.** None of it is adopted here (see "Not adopting").
- **Several things the pastes name do not exist in the repo.** Checked 2026-11-18 on main 977765c; the table has them.

## Premises checked against the code
| Claim in the pastes | Verdict | Evidence |
|---|---|---|
| `shared/askcore.swift`, a local SQLite FTS5 index, on-device cited Ask | **Does not exist** | no `askcore` file; no FTS5 anywhere in Swift or JS. Ask is the Gallery web page (`mobile/HostApp/iOS/Places.swift:17`, `.webPlace("Ask")`) over Workers AI + Vectorize (`library/src/ai.js`: gpt-oss-120b, bge-m3). It does not work offline. **True gap, separate feature, filed as a wish, not built here** |
| `strip/app.swift` shells out to `claude -p` | **True** | `strip/app.swift:6685` |
| Readability.js is available to inject | **Not in the repo** | no copy; only build artefacts matched |
| `Browser.swift` had its sidebar retired for `RecensePlaces` | **Half true** | `Browser.swift` is still the Files-shaped archive browser (its header). `Places.swift` holds `RecensePlaces` (Draftpad, Listen, Ask, Data …) |
| Typed or pasted text cannot yet be recensed | **False, it exists** | `shared/recensetext.swift`: sentences → transcript `Line`s, per-phrase language, Apple Translation en/vi/fr, Apple on-device model lenses (Gist, IRAC) whose every line cites source sentences; no network |
| No AI narration yet | **Partly exists** | `shared/draftpadlibrary.swift` `ReadAloud` (AVSpeechSynthesizer, word ranges live); `library/chau/show.mjs` renders outlines to .m4a with macOS voices in en/vi/fr (Mac only, no word timings) |
| Translation switching on a transcript | **Built** | FEAT-10 (`shared/translateplan.swift`): en / vi / fr / auto / off, on the device; per-language `keep/<key>/tr/<lang>.json` |
| Saving audio and video for offline use | **Built or specced** | FEAT-12 (audio → Music, `[x]`), FEAT-11 (iOS download engine, spike passed), FEAT-30 (Safari bridge) |
| The appless hub plays an item without the app | **Built for transcripts** | `keep/<key>/asr.json` + `tr/<lang>.json` (`library/src/layout.js`), share links `/m/<token>` |
| Zen Browser is desktop-only | **Not checked**; irrelevant to the decision |

## What is missing (the real gap, proven by reading)
- **No way in for a web page.** Nothing turns a URL or an open page into text: no extractor, no snapshot. (`recensetext` takes text the page's editor already holds.)
- **Narration has no timings you can keep.** `ReadAloud` speaks live and `show.mjs` writes audio without word times. A page narrated today could not light words, loop a phrase or be shared as a recording.
- **No audio in the other language.** Translation is text; the player cannot say a French line in a Vietnamese voice and keep its place.

## The design: one item, whatever it came from
An item is a `keep/<key>/` folder (unchanged format). A page becomes one by getting an `asr.json` whose words carry times, exactly like a recording. Then Follow, loop, karaoke light, FEAT-10 translation, export and the hub work with no new player code.

### S1 · Recense the selection or the shared text (no extractor, no new dependency)
- Entry: select text in Safari → Share → Recense (FEAT-03's "Open with Recense"), or paste (FEAT-26).
- Saves `source.json` `{url, title, fetchedAt, sha256, lang}` and the text, then runs the existing `recensetext` path (sentences, languages, translation).
- Done when: a French and a Vietnamese paragraph from a real page arrive as items with Source lines and an en translation, in airplane mode after capture.
- **Why first:** the owner chooses what to keep, so a failed page extractor can never block the feature.

### S2 · Narration with timings (spike first)
- The SDK has the hook: `AVSpeechSynthesizer.write(_:toBufferCallback:toMarkerCallback:)` returns audio buffers plus word markers (AVFAudio header: iOS 16, macOS 13). **Verified to exist; word accuracy for vi and fr voices is untested.**
- Spike: render one 200-word paragraph per language to .m4a and map the markers to `Word.start/end`. Pass = every word has a time, drift under 80 ms against a hand-checked sample, on iPhone and Mac.
- Output: `keep/<key>/audio.<lang>.m4a` + the words' times in `asr.json`; rendered once per (voice, text), as `show.mjs` already caches.
- If the spike fails for a language: that language narrates live only (today's `ReadAloud`) and says so; nothing is faked.

### S3 · Hear it in another language
- A "Listen in" choice on the item: original, en, vi, fr. Choosing X narrates `tr/X.json`'s text (S2 on the translation), stored as `audio.X.m4a`, with its own times.
- The line is the unit: the original line and its translation share `segId` (FEAT-10), so switching language keeps the place.
- Learn side by side: original line above, chosen language below (as FEAT-10 shows now), both lit by their own clock.
- Done when: switch en → vi → fr mid-paragraph and the same sentence stays lit each time.

### S4 · Page extractor (convenience, after S1 to S3 prove the loop)
- Measure before importing anything: write a small text-density extractor and test it on 20 saved pages (en, vi, fr: news, blog, a legal page, a forum thread) against Mozilla Readability used as the **yardstick, not a dependency**. Adopt Readability only if the own extractor loses clearly; the law (`spec-and-index-law.md`) allows no outside kit by default.
- The snapshot (extracted text + source URL + sha256) is kept on the device; the page itself need not be.

### S5 · Audio and video links join the same door
- "Recense this link" routes by kind: page → S1/S4; audio or video → the download engines (FEAT-11/12/30) → on-device ears → `asr.json`. One entry point, no new engine.

## Offline and ownership (the gate)
- Outside services: the source page itself, fetched **once** at capture; Apple Translation language packs, installed once. Narration, translation and lenses run on the device.
- Catch-up to the hub is the normal `keep/` sync: never blocks; the hub plays the item with no app; no company is required beyond what `keep/` already uses.

## Not adopting (and why)
- **Safari capsule + Zen Compact/Glance/Split skin:** a surface change, owned by the UI specs and `docs/law/`; it adds no ingest, narration or translation. Two of its ideas already exist: a tapped citation lights its source sentences in Draftpad (`recensetext` brief), and Mac wing panels (`strip/wingpanels.swift`).
- **Arc's Peek / workspaces:** a second workspace beside Draftpad.
- **WebLLM in a WebView:** an in-page model on an 8 GB Mac; Apple's model already runs on the device.
- **A new FTS5/embedding "AskCore":** a real gap but its own feature; see wish below.

## Owed
- Wish filed: "Ask works offline" (on-device index + cited answers); today Ask needs the network.
- S2's spike decides whether S3 is real for Vietnamese.
- Check that the hub's web player can switch between `audio.<lang>.m4a` tracks (not read yet).
