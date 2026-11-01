# Recense

> Archived draft from October 2026, when Recense was its own app and heard through Groq and Whisper. Today Recense lives inside Sill and hears on this Mac; see the [README](../README.md) for what is current.

*A multimodal score for the verbal world*

![macOS 14.2+](https://img.shields.io/badge/macOS-14.2%2B-black)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-Demucs%20on%20MPS-black)
![Players](https://img.shields.io/badge/plays%20with-Safari%20·%20Chromium%20·%20Firefox%20·%20QuickTime-black)
![Status](https://img.shields.io/badge/status-private%20pilot-orange)

> *To listen well is to read a score that is still being written.*

Recense is a way of learning languages through several senses at once, which is what it means to call it multimodal. The learner hears a voice and watches its words light up as they are spoken, and is then invited to speak along. The premise is simple. **Speech has pitch and pulse and phrasing, and every verbal exchange is composed in the moment by the people taking part in it.**

In Recense a transcript behaves more like a score than a page of text. Each word lights at the moment the voice begins to sound it. A clipped syllable flickers briefly, while a long vowel stays lit for as long as the speaker holds it. Machine timestamps tend to begin early and end late, spreading each word across the silence around it. Recense therefore separates the voice from whatever is playing beneath it and listens for the moment each word begins and ends. The English sits beneath the original and moves in step with it, so that reading and hearing arrive together.

The longer story of why Recense exists, and what it hopes to carry across, waits in [the preface](recense-preface.md).

Every key and setting lives in [the reference](reference.md).

## Learning in concert

Speech is multimodal by nature. It reaches us through the ear, yet it is shaped by the face and the breath, and it is understood best when more of those channels are available. Seeing a speaker makes speech in noise far easier to follow. Training that engages several senses tends to produce faster and more effective learning than training through one. Words spoken aloud are remembered better than words read silently, and subtitles in the language being sung have helped television audiences improve their reading.

This is how I learned to play. A piece entered through my eyes and my ears and settled eventually in my hands. Recense offers the same route into a language. The ear follows the voice while the eye follows the light across each word, and the learner's own voice joins them.

<sub>Sumby and Pollack (1954) studied seeing speech in noise, and McGurk and MacDonald (1976) showed sight changing what is heard. Shams and Seitz (2008) reviewed the benefits of training through several senses. MacLeod and colleagues (2010) studied memory for words read aloud, and Kothari and colleagues (2004) studied subtitles in the language being sung on Indian television.</sub>

## Verbal exchange heard as melody

### Singing together

Anyone who has sung with friends late into the night already understands how a verbal exchange works. One voice moves toward a harmony and another follows. Someone takes up a melody and bends it, and the others adjust. The key emerges from the listening. Conversation proceeds in much the same way. Each speaker waits for an opening and answers what was offered, carrying it somewhere new, and the meaning that results belongs to everyone involved.

### Impromptu speech as improvisation

To improvise is to compose and perform at once. Impromptu speech does exactly this, since every reply is assembled while it is spoken. A verbal exchange is a sequence of such replies, each built from what the previous speaker offered. Verbal exchange is therefore improvisation. The two share a root, although they are taught in separate rooms.

Improvisers depend on form, whether a chord progression the whole band knows or a beat that holds steady, and impromptu speech has forms of its own. Ideas arranged in threes feel complete, much as a blues verse states a line twice and turns on the third. Announcing where a thought is going allows the listener to follow each turn, in the way a band follows a singer who calls the change a bar early. The improviser's craft explains how speech arises in the moment. The orator's craft explains how it is sustained.

### Rests and balance

The one who leads a symphony lowers a palm to soften the loudest voices so that a quieter one can come through. A rest in conversation is a comparable act of generosity. It hands the phrase to someone else.

### The tune and its chords

A transcript resembles a page that carries only the tune and its chords. The words are present, and the phrasing is left to whoever reads them. Recense restores the phrasing. It renders rhythm and breath and silence as shapes the eye can follow, so that the ear receives the sound while the eye receives its shape.

## Kinship

Recense belongs to a long line of attempts to hear speech as melody. Aniruddh Patel's research suggests that language and melody draw on overlapping resources in the brain for making sense of structure as it unfolds. The Brazilian composer and bandleader Hermeto Pascoal spent years transcribing recorded speech and setting it to harmony, treating a voice on the radio as a melody waiting for its chords. Recense carries the same intuition into the learning of languages.

## Beyond the reach of English

English works like the shared tuning of modern instruments, which divides the octave into twelve equal steps. It allows players from many traditions to perform together, and it softens some of the color that belongs to each key. Fluency in it is distributed by region and privilege, and by curricula that governments choose for reasons of their own. Spoken wisdom in English and spoken wisdom in other languages face each other through glass. Transcription has its limits, and the tools that turn speech into text have been developed unevenly, so ideas on either side remain visible in outline while their words go unheard. Recense tries to open the window. The English supplies the common tuning and the original keeps its color, so that indigenous knowledge can reach the West and the West's ideas can reach places the world's attention passes by.

## How Recense listens

Recense follows whatever happens to be playing. QuickTime Player and Apple's Music app communicate with it through Apple Events, as do Safari and the browsers built on Chromium. Firefox reaches it through a small companion extension called the Recense Bridge. In a browser, any audio or video that is producing sound will do. macOS asks once for permission to automate each app, and Safari and Chrome also require JavaScript from Apple Events to be switched on.

The audio is collected ahead of playback. A file on disk is read directly, while a stream is downloaded or passed along by the Firefox extension. In a song the voice is first separated from its accompaniment. Whisper then transcribes the audio through Groq in pieces of two minutes, and each request begins where the voice begins.

Whisper's timings are approximate, so Recense refines them against the loudness of the audio in frames of ten milliseconds. A word that follows a pause begins where the voice actually resumes, and a word that precedes a pause ends where the voice falls away. On an isolated voice every word is refined in this way, and any word Whisper placed over silence is removed, on the reasonable grounds that silence says very little.

For songs, published lyrics are compared with what was actually sung and then fitted to the voice. Each line is translated into English along with a map of which words correspond. The highlight follows the position the player reports. Small irregularities in those reports are smoothed so that the light moves steadily forward, while a jump or a pause or a change of speed brings it to the new position at once. A single setting adjusts the timing if a particular setup runs early or late.

## Two ways of reading

A small switch in the top right corner of the window, which appears on hover, moves between Follow and Learn. The M key does the same.

Follow places the original above and the English below. A band of light crosses each word in the time it takes to be spoken and crosses the matching English word at the same moment. Each word brightens about a fifth of a second early, so that the eye arrives slightly before the ear. When the voice begins, a gold pulse flares and fades, briefly for a clipped syllable and more slowly for a held one. In Arabic and Hebrew the light travels from right to left. Its pace follows the media clock, so it slows and quickens with the playback speed.

Languages rarely agree on word order. Each English word therefore borrows the timing of the words it translates. Where those timings would run backward, Recense pools neighboring words until the sequence moves forward again, so the light keeps its direction even when the meaning doubles back on itself.

Learn keeps the original ahead of the listener, ready to be read and spoken along with. About a third of a second after a phrase of three or four words has been heard, a soft gradient passes across it. The words dissolve and their English appears in the same place, in the direction of reading, while the layout itself stays still. Phrases are divided at pauses and at the ends of clauses. A small word that leans on the next one is kept with it, and the English avoids ending a phrase on *the* or *of*. Lines alternate between two positions, one above the other, so that a completed thought remains on screen in English while the next one plays.

Curiosity seldom respects the boundaries of a syllabus, and minds with ADHD tend to wander furthest. Recense accommodates this. A Persian protest song or a Neapolitan street interview can be followed while the language under study stays in view. Follow holds that language steady on screen, and Learn indulges the detour while keeping it in proportion.

The aligned light also makes the relations between languages visible. A borrowed word lights up in both lines at once. A verb can be watched traveling to the end of a German clause, where German grammar has been sending its verbs for centuries.

## Songs

Songs require additional care. Demucs separates the voice from the band using the Mac's graphics processor, or the main processor when necessary, so that Whisper can hear the singer clearly.

Lyrics are selected by what was sung. LRCLIB supplies candidates by title and artist within ten seconds of the track's length, and the winner must contain at least 35 percent of the words actually heard. When every candidate falls short, Recense searches Genius for the sung words and tries LRCLIB again with the results. If that search also comes up empty, the screen shows what was heard. An honest transcript is more useful to a learner than a confident mistake.

Unpunctuated lyrics, such as Persian as Whisper writes it, are divided repeatedly at the singer's longest pauses of a fifth of a second or more. Each line becomes a line of the song and translates as a complete thought.

A chorus printed once and sung three times appears three times. A lyric line that Whisper missed is laid over the singing at the voice's own rhythm. A stretch whose language or wording departs from the lyrics is transcribed again in pieces of 25 seconds or less, so that Whisper can reconsider its language. Whisper's habitual filler and its invented subtitle credits are removed. A track that turns out to be entirely instrumental shows a quietly breathing ♪ INSTRUMENTAL in place of invented words.

## The loop

At rest the Home Bar is a single stroke along the bottom of the window. It turns blue while the whole track loops, and small beads at its ends mark the points A and B. The beads remain hollow until that loop is switched on.

Hovering over the stroke reveals the loop controls. On the keyboard L loops the track, while A and B set the two points. Clicking the stroke opens the speeds, which range from half to double, and the angle brackets step between them. Any speed other than normal remains visible beneath the stroke as a reminder.

Pressing and holding turns the stroke into a ruler for the entire track. Sliding sideways moves through it, and sliding upward zooms in as far as 64×. Near A and B the playhead is drawn in as though by a magnet. Resting two fingers on the trackpad over the bar pauses playback and opens the same ruler, so the frame holds still under the hand until the fingers lift.

A useful loop begins a breath before the phrase and ends just after its final syllable. At three quarters speed the phrase opens up and the mouth has time to form each vowel. Returning to full speed afterward feels a little like stepping onto a moving walkway. Pronunciation is learned the way any physical habit is learned, through repetitions small enough to manage and frequent enough to stick.

The space bar plays and pauses. The arrow keys skip ten seconds in either direction, and Escape folds the bar away.

## Corrections

A wrong line can be corrected where it stands. Pressing E or double clicking the line opens it for editing, and the player waits while the correction is typed. Return keeps the change and Escape discards it. An empty correction hides a line that Whisper invented. Clicking a line with the right button offers Reset Line to Auto, which restores the automatic version.

Corrections sit on top of the transcript, so later redos and improvements leave them in place. Any word a correction introduces joins that language's glossary, and Whisper reads the glossary as a prompt for everything it transcribes afterward. The machine, in other words, learns from being corrected, which is a virtue in machines and people alike.

## Keeping what was heard

Export Transcript, found in the menu bar or reached with ⌘E, writes the whole source into an Obsidian vault in iCloud Drive, where it can be opened on any device. The Markdown version begins with a short header describing the source and gives each line a timestamp, with its English beneath it.

The same export can become an audiobook. Recense cuts the audio into chapters of about ten minutes, each at the quiet before the nearest line, and passes them to Audiobook Builder for assembly. When the finished `.m4b` appears, Recense names it and removes the chapter files. Beside it go a `.vtt` file with every word timed and a note that embeds the audiobook. [The read along viewer](viewer/read-along.html) plays the two together on any device, and tapping a word jumps to it.

## Beneath the surface

Whisper identifies one language per request by its sound. Apple's NaturalLanguage identifies a language by its spelling, three words at a time. Each notices what the other misses, so Recense lets them vote. Languages written in Arabic script share their letters closely, and NaturalLanguage will confidently declare Dari to be Urdu. In such cases the sound decides. When Whisper writes a passage twice, once translated and once as sung, the translated copy is discarded.

The same recording can arrive from a video site, a podcast feed and a file on disk. Recense recognizes it by an acoustic fingerprint built on the Philips scheme of Haitsma and Kalker, finds the offset between the sources and reuses the transcript it already has. This spares a day's quota. Translations are remembered line by line.

Translation rotates through Groq's free models, and when one reaches its daily limit the next takes over. If every model is exhausted or the network is down, macOS 15 translates on the device. Those lines are marked as drafts and redone once the quota returns.

Media stays on the Mac only while it is in use. Afterward it moves to a temporary folder in Cloudflare R2, or it is deleted when R2 is absent, since it can be fetched again. Transcripts cost a day's quota to rebuild, so they are mirrored to a permanent folder together with corrections and the glossary, and merged back on launch. Each day Recense measures how quickly media has been arriving. It then keeps files for the longest period that stays under 80 percent of the free tier, up to 90 days. The archive, in effect, looks after itself.

## Getting started

Recense runs on macOS 14.2 or later with Apple Silicon, and macOS 15 is recommended for translation on the device. It requires a Groq API key, and the free tier is sufficient. Optional helpers are described in [the reference](reference.md).

The build script compiles `main.swift` and signs the app with a stable identity, which allows macOS to remember its permissions between builds. Create a certificate of your own in Keychain Access and enter its name in `build.sh`. Then build and open the app.

```bash
./build.sh && open Recense.app
```

Recense adds itself as a login item on first launch, and its menu can switch that off.

Settings live in `~/.config/recense/config`, one `KEY=VALUE` per line. `GROQ_API_KEY` is the only one required.

When captions appear to stall, the log is the first place to look. Groq's free tier has daily quotas, and when one runs out Recense waits for it to reset. The log at `~/Library/Logs/recense.log` names the quota and the length of the wait.

The whole app lives in `main.swift`. The Firefox extension lives in `extension/`, and `tests/regress.sh` replays every track that once went wrong.

## Status

Recense is a private pilot offered as a direct download. It drives other apps through Apple Events and runs scripts inside browser tabs, and those abilities lie beyond what the App Store sandbox permits. It therefore lives outside the store.

* * *

Every language is a performance already underway. Recense allows a learner to slow a passage down and play it back until they can carry it alone.
