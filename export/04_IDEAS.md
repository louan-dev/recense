# Sill — Ideas & Explorations

This file preserves possibilities without making them requirements.

## Status Vocabulary

- **NOW** — currently selected/actively being built
- **EXPLORE** — being evaluated
- **LATER** — worthwhile but not currently selected
- **EXPERIMENTAL** — feasibility or usefulness is unproven
- **REJECTED** — intentionally declined
- **SUPERSEDED** — replaced by a later approach
- **IMPLEMENTED** — verified in the product

## Zero-UI Executive Function Middleware

Original framing for the broader idea:

> Bridge raw human intent and continuous thought expression directly into a local, durable Markdown surface, acting as a low-friction layer between the user's cognitive state and the computer's execution capabilities.

This is a conceptual framing, not a requirement that Sill expose no UI at all.

## Voice + Gesture

Explore a system in which:

- gesture summons the environment
- voice captures or queries thought
- typing remains optional
- gesture dismisses the environment
- prior context remains easy to recover

The interface should not depend on conventional back/forward navigation when spatial or gesture-based transitions can preserve continuity more naturally.

## Continuous Text + Audio

Potential future model:

- typed text
- dictated text
- audio recordings
- transcripts
- timestamps
- text-to-speech playback
- AI summaries
- definitions
- translation

The conceptual property is that voice and text coexist in one continuous page rather than becoming disconnected note systems.

## Audio Recording + Transcript

Potential future capability:

- record audio to `.m4a`
- link audio to timestamped transcript ranges
- preserve the recording and transcription alongside the Markdown history
- enable later playback and semantic retrieval

## Temporal Semantic Memory

A long-term direction is to make the Markdown history queryable by time and concept.

Potential questions:

- How did this idea evolve?
- When did I first think of this?
- What did I previously conclude?
- What changed?
- Which past brainstorm relates to this new idea?

Possible implementation ingredients:

- timestamps
- transcript links
- local indexing
- embeddings
- hybrid lexical/semantic search
- local model support such as Ollama

Do not claim hallucination-free AI. Reliability should be treated as an engineering goal.

## Natural-Language Actions

Potential voice-driven actions include:

- calendar entries
- reminders
- email drafts
- information retrieval
- summarization
- explanations
- translation
- selected system actions

Prefer draft-first, read-back, confirmation, execution.

## Antinote-Style Command Layer

Potential low-friction commands triggered by `::` include:

- `::today`
- screenshot-to-text
- find/replace
- timer
- simple Markdown operations
- checklist operations
- navigation
- other tiny utilities

The command layer should remain composable and lightweight rather than becoming a conventional command-heavy IDE.

## Contextual Time / Weather

Time should open prominently when the top-center panel is summoned, then recede into a quieter form.

Weather should appear contextually rather than as a permanent dashboard tile.

## Multiple Time Zones

Potential restrained hierarchy:

- one primary timezone
- a small number of secondary zones
- country/context labels
- relative offsets when useful

Avoid a world-clock dashboard.

## Calendar / Deadlines / Timers

Potential signals:

- imminent events
- current events
- deadlines
- active timers
- important upcoming commitments

A temporal indicator may shift subtly under genuinely urgent conditions. Red, if used, should communicate real time sensitivity rather than decoration.

## Selective Notifications

Possible high-value sources:

- Messages/SMS
- Telegram in the specific SMS-bridge use case
- important communications
- recent calls
- urgent calendar events

Do not recreate the full macOS Notification Center.

## Telegram / SMS Bridge

A future integration may surface an existing Telegram-based SMS bridge in the Sill environment, particularly when the user's phone is unavailable.

The purpose is resilience and access to important communication, not social-feed aggregation.

## Global Media Control

Possible future integration with the separate Personal Data Cloud media player.

Concept:

```text
active media anywhere on Mac
        ↓
Sill detects relevant playback
        ↓
minimal playback controls surface
```

This is future/experimental. Do not import another project's entire player UI into Sill.

## Shared Media Interaction Language

The Personal Data Cloud media player has explored a spatial language in which horizontal interaction represents playback/time scales, for example:

- slower → faster
- earlier → later
- A → B

Sill may borrow the conceptual language later, but should not automatically inherit the implementation or visual design.

## Voice / Superwhisper-Like Layer

Explore proprietary or local/native/global speech input rather than assuming a third-party application must remain a permanent dependency.

Keep speech capture, transcription, interpretation, and action execution as separable layers.

## Adaptive Cognitive Styling

Potential visual adaptation includes:

- automatic light/dark adaptation
- subtle tinting
- contrast adaptation
- panel-only dimming
- ambient display changes

Treat these as design experiments. Do not make medical claims.

## Accessibility-Oriented Exploration

Potential areas:

- VoiceOver compatibility
- Switch Control
- keyboard alternatives
- low-vision-friendly contrast
- auditory interaction
- motor-friendly interaction
- touch/gesture alternatives

All require real testing before public claims.

## Web Clipping / Knowledge Acquisition

Potential future capability for clipping or importing useful material into the continuous memory surface, with provenance preserved where practical.

## Assistive / Learning Partner Direction

Longer-term possibilities include voice-driven recitation, definitions, explanations, translation, summarization, and iterative brainstorming on the same durable page.

The goal is not to create a generic chatbot inside Sill; the goal is to reduce the friction of continuing a line of thought.
