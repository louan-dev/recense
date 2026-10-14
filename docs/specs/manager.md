# Integration: Autonomous Calendar Commitment Manager

## Goal
A scheduling engine that runs 24/7 and removes the mental baggage of staying undecided. It acts like a "hedge fund manager for my time": it makes the scheduling decisions and puts them on the calendar for me so I don't have to agonize, overcommit, overextend, waste time, decide late, or pay no-show/late fees. I just show up. I can talk to it and I can talk to it. NotbeookLM style. Runs on quantitative data and looks for gaps in dates in my confirmations and reminders and selects a time for me. 

## Problem it solves
- Indecisiveness and mental energy spent on staying in the middle
- Late cancellations, no-show fees, and providers refusing service after repeated lateness or no-shows

## Core behavior
1. Calendar management: monitors my calendar and schedules, reschedules, and cancels appointments on my behalf.
2. Personalization signals: uses my sleep patterns and phone-activity patterns (when I'm most active) to learn when I'm most likely to attend.
3. Risk prediction: estimates the probability that I'll be late or skip an appointment, and identifies the time windows where my attendance odds are best.
4. Reminders: sends reminders timed around when I'm most responsive on my phone.

## Autonomy rules
- Cancellations: fully automatic, with no approval needed.
  - Send the cancel 24 hours before the appointment on business days.
  - Send it 48 hours before if the deadline falls on a weekend or federal holiday.
- Rescheduling: propose only. The system suggests the best new time based on my calendar and activity data, and I confirm.

## Design principles
- Default to automation over asking me to decide
- Optimize for attendance probability and avoiding fees
- Run continuously in the background

## Open questions to settle before building
- Which calendar provider(s)? (Google, Apple, Outlook)
- Where do the sleep and phone-activity data come from? (HealthKit, Screen Time, wearable, etc.)
- How does it know an appointment has a cancellation deadline or fee? (Manual tags, parsing the event, provider rules)
- How are the cancel messages sent? (Email, provider portal, SMS)
- How are proposed reschedules and reminders delivered to me?
- Platform: backend service, mobile app, or both?