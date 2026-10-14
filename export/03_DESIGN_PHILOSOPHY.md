# Sill — Design Philosophy

## 1. Less Visible Interface, More Available Capability

Sill should not constantly expose everything it can do. The default state should be quiet; capabilities should reveal themselves contextually.

## 2. Reduce Friction, Not Functionality

Do not simplify by deleting useful capability. Simplify by reducing steps, mode switches, navigation, setup, and unnecessary decisions.

## 3. Move With Impulse

The product should support starting and resuming work from an impulse rather than requiring a user to prepare an environment first.

Avoid digging through menus, organizing information before capture, or forcing the user to decide where something belongs before they can express it.

## 4. Preserve Continuity

The environment should feel persistent even when elements appear, disappear, expand, collapse, or change mode.

The user's context should be easy to resume.

## 5. Context Over Dashboarding

Information should appear because it is relevant to the current context, not merely because Sill has a place to display it.

Do not turn the top-center environment into a collection of permanent tiles.

## 6. Native Mac Behavior

Use native macOS APIs and conventions whenever they provide the right foundation.

Do not imitate newer hardware conventions unnecessarily. The primary machine is a 2020 13-inch MacBook Pro with M1 and no physical display notch.

## 7. Backend Before Polish

When there is a meaningful choice between robust underlying behavior and decorative frontend detail, prioritize:

1. backend/system reliability
2. state and data integrity
3. native system integration
4. interaction correctness
5. responsive/device behavior
6. visual polish
7. decorative detail

The interface can become prettier later. A fragile foundation multiplies later debugging.

## 8. Do Not Overbuild

Sill should not become a widget zoo, another notification center, or a configuration-heavy productivity suite.

Every feature must earn its place by solving a real problem or removing meaningful friction.

## 9. Native Feeling, Not Apple Imitation

The desired emotional and interaction qualities are:

- quiet
- precise
- intentional
- tactile
- spatial
- contextual
- restrained
- continuous

Avoid:

- generic SaaS aesthetics
- excessive cards and badges
- giant floating islands
- fake-notch interfaces
- heavy borders
- excessive animation
- visual clutter
- configuration-heavy surfaces

The aspiration is an unreleased Apple design experiment in spirit, not a reproduction of Apple's visual identity.

## 10. Accessibility Design Intent

The project considers reduced visual, auditory, motor, and cognitive friction. It may eventually include voice interaction, low-vision-friendly presentation, keyboard alternatives, VoiceOver, Switch Control, and other assistive pathways.

These are design intentions and hypotheses until actually tested. Do not make clinical, universal-accessibility, or disability-benefit claims without evidence.

## 11. Contextual Time

Time is useful but should not demand constant attention.

The panel should make time immediately available when summoned, then allow it to recede into quieter spatial forms after inactivity.

The same principle applies to weather, calendar signals, notifications, and other contextual information: available when useful, quiet when not.
