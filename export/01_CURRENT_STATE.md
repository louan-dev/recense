# Sill — Current State

## Product State

Sill is the larger product direction. Draftpad is the existing working foundation and intended persistent Markdown/memory subsystem.

The current product should still be treated as an evolving system. Do not infer that every concept documented elsewhere is implemented.

## Draftpad Foundation

Current known characteristics:

- Native macOS application using Swift/AppKit.
- Floating note window.
- No Dock icon.
- Reads and writes one canonical Markdown file in an Obsidian vault.
- One continuous note rather than a collection of separate note objects.
- BetterTouchTool currently supplies global gestures.
- A hotkey can summon the application without BetterTouchTool.
- Source lives at `~/Developer/obsidian/draftpad`.
- Built and verified on macOS Sequoia 15.5 on a 2020 13-inch M1 MacBook Pro.
- User intends the repository to remain private initially, with possible future GitHub publication.
- A LaunchAgent is desired for startup.
- A repository-contained cleanup script is desired to remove the project and installed components cleanly.

## Current Interaction Concept

The foundational loop is:

1. Summon the note over the current application.
2. Capture, reference, or develop a thought.
3. Dismiss it without losing context.
4. Summon it again later without reconstructing the working state.

The interaction is intended to feel like moving with an impulse rather than entering a separate productivity application.

## Current Feature Exploration

Draftpad is being explored with an Antinote-style command mechanism:

- Typing `::` opens a command autocomplete popover.
- Commands can insert or perform small, low-friction utilities.
- Known examples include `::today` for the current date.
- Other explored command concepts include screenshot-to-text, find and replace, timers, Markdown utilities, checklists, and navigation.

These commands should remain small and composable. Do not assume every proposed command is already implemented.

## BetterTouchTool Status

BetterTouchTool is current implementation scaffolding for global gestures, not necessarily the permanent architecture.

The longer-term question is whether the required global gesture pathway can be reproduced reliably through native macOS mechanisms.

Do not remove working BTT behavior merely for architectural purity. Establish a reliable replacement first.

## Not Yet Established

The following should not be treated as current unless verified in the repository or a later decision document:

- fully native global gesture capture
- production-quality accessibility support
- voice capture/transcription pipeline
- semantic memory/indexing
- AI agent actions
- menu-bar icon relocation/reflow
- global media control
- iPhone-mirroring gesture behavior without BTT
