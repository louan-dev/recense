# Recense — Device & Platform Matrix

## Primary Device

**2020 13-inch MacBook Pro, M1**

Important hardware characteristic:

- no physical display notch

Recense should optimize for the actual geometry and behavior of this machine rather than imitating a newer notched MacBook.

## Current Verified Environment

- macOS Sequoia 15.5
- 2020 13-inch MacBook Pro with M1
- Draftpad built and verified in this environment

## Top-Center Geometry

The main surface should be designed around the real desktop/menu-bar geometry.

The product should not require a hardware notch to make sense.

Potential implementation considerations include:

- actual screen bounds
- `NSScreen` geometry
- menu-bar area
- safe placement relative to system UI
- full-screen behavior
- multiple displays
- display scaling
- appearance/light-dark mode
- sleep/wake transitions

These should be tested rather than assumed.

## Global Gesture Requirements

Target behavior:

- three-finger swipe up → Draftpad/memory
- three-finger swipe down → top-center time/essentials

Required qualities:

- global
- low latency
- predictable
- no visible pointer choreography
- independent of the focused application

## BetterTouchTool / Native Boundary

Current prototype uses BetterTouchTool.

Future native gesture support should be treated as a technical investigation. Do not assume macOS exposes the exact desired global trackpad gesture events through a public API.

If native replacement is not feasible, document the constraint instead of creating a brittle workaround.

## iPhone Mirroring

The current BTT environment has included gesture behavior while mirroring an iPhone.

Treat this as a separate experimental research problem. Do not let it contaminate the core Recense architecture until feasibility is established.

## Accessibility / Assistive Technologies

Potential future testing targets:

- VoiceOver
- Switch Control
- alternative input methods
- low-vision workflows
- motor-friendly interaction

These are testing targets, not proof of compatibility.

## Other Hardware

Unless later validated, treat these as experimental/unknown:

- Intel Macs
- Magic Mouse-specific behavior
- multi-account Calendar environments
- unusual display configurations
- third-party assistive hardware
