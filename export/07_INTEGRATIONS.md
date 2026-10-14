# Sill — Integrations

Integrations are candidate service boundaries, not commitments to expose every service in the main UI.

## Apple Calendar

Potential/desired role:

- concise upcoming events
- currently occurring event
- imminent deadline
- relevant commitments

Use native macOS Calendar APIs where appropriate.

Sill should complement Calendar rather than become a full Calendar replacement.

## Time Zones

Potential contextual integration:

- one primary timezone
- compact secondary zones
- country/context labels
- relative offsets when useful

Avoid a full world-clock dashboard.

## Weather

Weather should be contextual and appear when relevant rather than taking permanent panel space.

## Messages / SMS

Potential selective notification source for high-value communication.

Do not reproduce the full messaging application inside Sill.

## Telegram / SMS Bridge

The owner has an existing Telegram-based SMS bridge concept.

Potential Sill role:

- surface important bridged SMS messages
- provide access when a phone is unavailable
- avoid social-feed behavior

## Recent Calls / Phone

Candidate integration for selective high-value information, subject to macOS API and permission constraints.

## WhatsApp / Signal / WeChat / FaceTime / Voicemail

Candidate communication sources only. Do not assume all should be integrated.

The inclusion rule remains: an integration belongs only if it materially reduces friction.

## Password Managers

Candidates include Bitwarden and Proton Pass.

The goal would be contextual access or quick actions, not embedding a full password manager UI.

## iCloud Drive / Proton Drive

Candidate storage/quick-access integrations.

Do not create duplicate storage abstractions when native file access already solves the task.

## Dictionary / TextSniper

Potential lightweight utilities for contextual lookup, text capture, or reference tasks.

## Text-to-Speech / Speech Input

Potential future native/local speech pathways.

Keep capture, transcription, interpretation, and execution separate.

## Obsidian

Core integration.

The Markdown file used by Draftpad must remain independently usable in Obsidian.

Future plugin compatibility may be useful, but proprietary coupling should be avoided.

## DEVONthink

Potential future knowledge/retrieval integration.

Treat as an external research direction until a concrete workflow justifies it.

## Activepieces / Automation

Potential external automation layer.

Any automation should be explicit, auditable, and bounded; avoid turning Sill into a generic automation trigger surface.

## Personal Data Cloud / Media Player

Sill and the separate Personal Data Cloud project may eventually exchange small, well-defined interfaces.

Potential future use:

- global playback detection
- minimal playback controls
- shared media context

Do not merge the projects prematurely.

## Integration Rule

> If a service does not reduce friction, it does not belong in Sill.
