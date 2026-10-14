# Sill — Architecture

## Architectural Direction

Sill should remain a small native macOS system whose visible interface can grow without requiring a monolithic feature architecture.

Prefer native Apple APIs, explicit state, small components, reversible changes, and clear boundaries between the UI layer and system/data services.

## Draftpad Data Model

The canonical scratchpad is the Markdown file used by Draftpad and Obsidian:

`/Users/chauphan/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian/draftpad.md`

This file is the source of truth for the embedded Draftpad workspace.

Requirements:

- keep the file portable
- keep it independently usable in Obsidian
- do not replace it with a proprietary database merely to support Sill
- treat Sill as a view/editing surface over the file
- avoid unnecessary proprietary metadata

## Top-Center Environment

The larger Sill interface is envisioned as a floating, top-center environment above the desktop.

Its purpose is to provide a persistent auxiliary layer where relevant information or actions can surface without forcing the user to search through windows.

The environment should not become a full notification center.

## Panel Foundation

The preferred foundation is a borderless native `NSPanel` or similarly appropriate AppKit floating surface.

The panel should:

- blend with the actual macOS menu-bar environment
- respect system appearance
- avoid a black rectangle
- avoid pretending a physical MacBook notch exists
- avoid excessive borders and shadow
- feel attached to the desktop rather than pasted on top of it

## Two Core Pages

Conceptually, the panel has two primary pages rather than many screens.

### Page 1 — Time / Essentials

Primary/default view. It opens to a time-centered state and may surface concise contextual information such as Calendar, deadlines, additional time zones, battery, essential notifications, or useful quick actions.

### Page 2 — Draftpad / Memory

The embedded Markdown workspace backed by the canonical Draftpad file.

Sill should not create a parallel proprietary note store merely to support this page.

## Contextual Time Model

Time is intentionally contextual rather than permanently dominant.

On summon, the time can appear prominently. After inactivity it may recede into a quieter horizontal form. The intended behavior is a continuous transition rather than a dashboard-like clock widget.

## Global Gestures

The target interaction model includes two core system gestures:

- three-finger swipe up → summon Draftpad/memory
- three-finger swipe down → summon the top-center time/essentials environment

These gestures should ultimately feel like OS-level transitions: immediate, predictable, low-latency, and independent of the currently focused application.

## BetterTouchTool Boundary

Current prototype behavior may depend on BetterTouchTool. Long-term architecture should attempt to replace only the small gesture pathway Sill actually requires rather than recreating BTT generally.

Historical shell example:

```bash
P="$HOME/Developer/obsidian/draftpad"
if pgrep -ix draftpad >/dev/null; then "$P" show; else nohup "$P" >/dev/null 2>&1 & fi
```

This is historical reference material, not a required final implementation.

## Gesture Transition and Cursor Behavior

Avoid visible cursor choreography where possible. A global gesture should feel like a system transition, not a recorded automation sequence.

Do not trade backend reliability for perfect visual behavior.

## Menu-Bar Integration

A potential Sill direction is deeper visual integration with the macOS menu bar, including reflowing or repositioning icons when the top-center panel descends.

Treat this as constrained by macOS APIs and potentially fragile system behavior.

Preferred approach:

- use supported APIs when possible
- avoid fighting undocumented behavior
- do not build a brittle illusion simply because it looks good
- use masking/duplicate representations only if they are reliable, reversible, non-destructive, and resilient to macOS updates

## Future Service Boundary

Potential services should live behind small, explicit integration boundaries rather than becoming deeply coupled to the panel UI.

Examples include Calendar, messaging bridges, password managers, storage providers, dictionary/text tools, weather, and media control.

## Voice Boundary

Keep these concepts distinct:

- dictation
- transcription
- command interpretation
- action execution

A future pathway may look like:

```text
global gesture → voice capture → local transcription → Draftpad
```

or:

```text
voice command → intent parser → draft/confirmation → system action
```

Do not collapse everything into one unsafe automation layer.

## Agent Action Boundary

For consequential external actions, prefer:

```text
draft → read back/explain → user confirmation → execute
```

Do not silently send messages, create commitments, or perform consequential actions without explicit authorization.

## Semantic Memory Boundary

Future semantic search should sit beside the Markdown source of truth rather than replace it.

Potential supporting layers:

```text
Markdown + timestamps + audio/transcript links + local indexing/embeddings + hybrid search
```

The purpose is idea lineage and retrieval, such as understanding when an idea first appeared, how it changed, or what was previously concluded.

Local models such as Ollama may be explored. Do not promise hallucination-free AI.
