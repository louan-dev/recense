# Sill — Decisions

This document records meaningful choices so they do not have to be rediscovered in future chats.

## 2026-10-06 — Product Name: Sill

**Decision:** The larger native macOS utility is named **Sill**.

**Relationship:** Draftpad is the original foundation and persistent Markdown/memory subsystem inside Sill.

**Supersedes:** The working name “Nook.”

**Rationale:** The name aligns with the product's architectural metaphor: a thin surface at the edge of the computer where important things can rest without intruding on the main workspace.

## Draftpad Remains the Memory Subsystem

**Decision:** Draftpad is not being abandoned as Sill expands.

**Rationale:** Its one-file Markdown model, continuity, portability, and low-friction interaction remain central to the product direction.

## Markdown Source of Truth

**Decision:** The canonical Draftpad Markdown file remains the durable source of truth for the scratchpad/memory layer.

**Rationale:** Preserve portability and independent usability in Obsidian; avoid making Sill the only access path.

## BetterTouchTool as Scaffolding

**Decision:** BetterTouchTool is a current prototype dependency for global gestures, but not a permanent architectural commitment.

**Rationale:** Maintain working behavior while investigating whether the required gesture pathway can eventually be handled natively.

## Current/Future Separation

**Decision:** Future capabilities must not be treated as current requirements merely because they appear in the product vision.

**Rationale:** Prevent speculative features such as semantic memory, AI actions, media controls, or broad integrations from driving current architecture prematurely.

## Backend Before Polish

**Decision:** When tradeoffs arise, prioritize backend/system reliability over frontend polish.

**Rationale:** A stable foundation reduces repeated downstream debugging and keeps the UI simpler to refine later.

## Native Device Context

**Decision:** The primary design target is the actual 2020 13-inch M1 MacBook Pro, which has no physical display notch.

**Rationale:** Sill should exploit the real hardware rather than forcing a newer MacBook interaction model onto it.

## Accessibility Claims

**Decision:** Accessibility-oriented design intent does not equal validated accessibility.

**Rationale:** Public claims should distinguish design intent, hypothesis, observed behavior, testing, and clinical/accessibility evidence.
