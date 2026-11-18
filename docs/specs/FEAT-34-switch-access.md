# FEAT-34 · Switch access: every Recense action from one or two switches, and devices on and off

From: owner 2026-11-18 ("our version to use our features via switch control, turn on/off devices") · Status: `[ ]` spec · Effort: medium, in phases
Binding law it serves: `docs/law/interaction.md:31`: "A gesture only speeds an action up. The same action also has a visible control, a menu item and a voice command."

## Verdict first
- **Affirm, with one objection:** don't build our own scanner first.
  - Apple's Switch Control already scans whatever an app makes accessible, on iPhone, iPad and Mac, offline (Apple's documentation; **not tested here**).
  - Our missing piece is upstream: **no list of Recense's actions exists, and no gesture has an accessible equivalent.**
- **Order:**
  1. P0: every action reachable by Apple's Switch Control.
  2. P1: one action catalogue, also exposed as Shortcuts actions.
  3. P2: our own light switch deck (spoken, en/fr/vi, headphone buttons).
  4. P3: devices on and off.
  - Each phase is useful alone.

## Premises checked against the code (main bfb4bab, 2026-11-18)
- **proven:** no `accessibilityAction`, `accessibilityCustomActions` or `NSAccessibilityCustomAction` anywhere.
  - So the rest-hold console (`RestHoldConsole`, `strip/app.swift:352-380`), edge swipes and finger-count gestures are unreachable by a switch unless a menu holds them too.
- **proven:** no action catalogue. Actions are scattered:
  - menus in `strip/app.swift`
  - `RecensePlaces` (`Places.swift:6`)
  - editor voice moves (`executeVoiceMove`, `editor/src/index.js:1157`)
  - editor key handlers
- **proven, reusable:**
  - App Intents: `DraftpadVoiceIntent.swift` (Add to Draftpad, Action button), `PairIntent.swift` (an `AppShortcutsProvider`).
  - Lock Screen and headphone commands: `MPRemoteCommandCenter` (`NativePlayer.swift`).
  - Pencil double-tap and squeeze: `editor/src/index.js`, `Draftpad.swift`.
  - Mac Shortcuts runner: `/usr/bin/shortcuts run` (`strip/app.swift:3843`).
  - Mac audio output switching (`kAudioHardwarePropertyDefaultOutputDevice`) and brightness: `strip/app.swift`.
  - The headphone route brain: `BridgeDecision.decide` (`shared/bosebridge.swift`, FEAT-15).
- **proven absent:** GameController, HomeKit, CoreBluetooth/IOBluetooth, a `recense://` URL scheme.
- **Fact (Apple platform):** an iOS app cannot switch the phone off, lock it, or toggle Wi-Fi or Bluetooth itself. Only the Shortcuts app can, through the owner's own shortcuts (**assumed** from Apple's documentation; checked on the iPhone in P3).

## P0 · Apple's Switch Control reaches everything (audit + fixes; low cost; binding law already)
- Every gesture-only action gets a menu item and an accessibility custom action on the view that owns the gesture.
  - Covers the rest-hold console, edge swipes, scrub, loop, the ink tools and the floating window.
- Every icon-only control gets a label in en, fr and vi.
- The Draftpad web view: the editor's controls carry ARIA roles and labels so Switch Control scans them.
- **Check:** with Apple Switch Control on (Settings › Accessibility › Switch Control, screen as the switch), on iPhone, iPad and Mac:
  - play, pause, loop a line
  - switch Follow-in language
  - add to Draftpad
  - open the floating window
  - With no touch except the switch. Recorded through iPhone Mirroring.

## P1 · One action catalogue
- **One file both runtimes read:** `shared/actions/actions.json`. Each action has:
  - `id`
  - its title in en, fr and vi
  - where it applies (place or view)
  - its voice phrases
  - whether it changes data (then it asks before acting, per the law)
- **Swift reads it** (Codable) and **the editor and web read it** (import). No second list.
- **Each action then appears in:**
  - the menu
  - the voice moves
  - a Shortcuts action (one `AppIntent` per action group, in an `AppShortcutsProvider`)
  - so it also reaches Siri, the Action button, Back Tap and the Shortcuts menu of Apple's Switch Control
- **Test:** every `id` in the catalogue has a menu item, a voice phrase and an intent. No menu item is missing from the catalogue.

## P2 · The switch deck (ours: in the app, spoken, no system mode)
- **Why ours as well:**
  - Apple's mode takes over the whole device.
  - Ours is on only inside Recense.
  - It speaks each choice in the owner's voice and language, offline (ReadAloud).
  - It can use the headphone buttons while listening.
- **One switch:** the deck steps through choices on its own; a press chooses. **Two switches:** one steps, one chooses.
- **At most 7 choices at a time:** the current view's catalogue actions, most-used first. One focus, a large ring, never colour alone.
- **Step time:** default 1.5 s; owner range 0.5–5 s. Nothing moves faster under Reduce Motion; the ring changes in place.
- **Switch sources:** a keyboard key or a foot pedal (it acts as a keyboard), Pencil squeeze, a tap anywhere on the screen, headphone play/pause and next.
  - Headphone buttons mean "switch" only while the deck is on. Turning it on is announced aloud and shown in the strip and floating window.
  - Turning it off returns them to playback at once.
- **Check:** with one key, open a recording, loop a line, switch to Vietnamese, add a note. Every step is heard. Mac + iPhone + iPad.

## P3 · Devices on and off
- **The Mac (our code, offline):**
  - display sleep
  - brightness (exists)
  - output device and the Bose route (exist)
  - headphones connect/disconnect (IOBluetooth: **untested** with the QC SC)
- **iPhone and iPad:** Recense runs the owner's named shortcuts (Wi-Fi, Bluetooth, Low Power, Focus) through Shortcuts. The deck lists them by name. Recense never claims to do what only iOS can.
- **The hub and other Macs:** wake by Wake-on-LAN (own code, local network) once the hub machine exists (FEAT-18 H3); sleep through the hub's own endpoint.
- **Recense's own device roles:** pause or forget a paired device (SEC-02 "Forget <device>") as a deck action.
- **Lights (owner has an Aqara light, Matter + HomeKit):** controlled through Apple's HomeKit framework, which reaches Matter accessories added to the Home app. It works on the local network with no Aqara account at the moment of use (**assumed**; checked on the iPhone in P3). Mac: through the same Home data on macOS (**untested**).

## Outside services
- **At the moment of use:** none. Switch Control, Shortcuts, App Intents, IOBluetooth and Wake-on-LAN are on the device or the local network.
- **Setup:** none.

## Not adopting (and why)
- **A scanner that replaces Apple's:** duplicates the system. Ours is a light deck on the same catalogue.
- **Gestures as the only route to an action:** forbidden by the law. P0 fixes what exists.

## Owner decisions (defaults hold until answered)
- **Which devices to switch (answered 2026-11-18):** Mac display, Mac audio and headphones, the owner's iPhone/iPad shortcuts, and the Aqara light (Matter + HomeKit).
- **The deck's default step time:** 1.5 s.
