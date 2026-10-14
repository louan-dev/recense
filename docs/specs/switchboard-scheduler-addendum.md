# Switchboard: Scheduling Brain Addendum ("Calendar Desk")

Read with `switchboard-spec.md` and `switchboard-iphone-addendum.md`. Switchboard is the **intake and actuation layer** (voicemails and texts in, replies out). This addendum adds the **decision layer**: a 24/7 engine that keeps your appointments at low risk, cancels the ones you will not make before the fee deadline, and proposes better times. It runs on Cloudflare Workers (cron plus queues), not on any chat session, so it keeps working while you sleep.

## 1. Design intent and the core rule

Remove the mental cost of committing: you should not have to decide, decide late, or pay a fee. The engine acts by default, tells you what it did, and you can step in before it acts.

**Core rule (set by the owner):**
- **Cancellations are sent automatically** at the cancellation deadline: **24 hours before the appointment on business days. If the 24-hour mark lands on a weekend or US federal holiday, use 48 hours.** (Section 6.2 covers the edge cases this leaves open.)
- **Rescheduling is never automatic.** The engine only **proposes** the best new times, based on your calendar and activity, and you tap one.

Ideas that make this more than a reminder app:

1. **Cancel by rule, reschedule by proposal.** The deadline is computed from the provider's policy, business days, and federal holidays. A decision card appears shortly before the send time; silence means "go ahead."
2. **Reliability is capital.** Every provider keeps an informal score on you: no-shows, lates, and frequent cancellations all count. The engine keeps a **strike ledger** per provider and manages risk like a portfolio: it avoids stacking risky commitments on one day, sizes the day to your predicted capacity, and treats a provider near its strike limit as untouchable.
3. **Shadow trading before real money.** At first the engine makes every decision silently and logs "I would have cancelled X." After outcomes arrive, it scores itself. Autonomy is promoted only when shadow decisions would have saved money. You can skip this with `/live` (the engine will warn that its probabilities are uncalibrated).

## 2. Modules

| Module | Job |
|---|---|
| Calendar Gateway | Read and write your calendar. Default: Google Calendar API as the source of truth, synced natively to the iPhone. |
| Policy Ledger | Per provider: notice period, fees, office hours, time zone, strike limit, cancel channel, opt-in for auto-cancel. |
| Deadline Calculator | Business-day and federal-holiday aware cancellation deadlines (section 6.2). |
| Commitment Tracker | One row per appointment with deadline, send time, decision time, status. |
| Signals | Wake and bed times, bot-interaction rhythm, travel time, optional location. |
| Outcome Ledger | Ground truth: on time, late, missed. Trains the model and updates strikes. |
| Risk Model | Estimates `p_miss` and `p_late`, with reasons. |
| Decision Engine | Expected-cost comparison of keep, propose-reschedule, and cancel. |
| Action Planner | Sends cancellations and requests through Switchboard's actuator, stores receipts, sets alarms and reminders. |
| Autonomy Governor | Opt-ins, veto windows, rate limits, kill switch, shadow mode. |

## 3. Data model (adds to the main schema)

```sql
CREATE TABLE providers (
  id TEXT PRIMARY KEY, user_id TEXT, entity_id TEXT, name TEXT,
  category TEXT,                       -- health | gov | legal | service | other
  tz TEXT DEFAULT 'America/Los_Angeles',
  office_close_hour INTEGER DEFAULT 17, office_open_hour INTEGER DEFAULT 9,
  cancel_notice_h INTEGER DEFAULT 24,
  fee_noshow REAL DEFAULT 0, fee_late REAL DEFAULT 0, fee_late_cancel REAL, fee_resched REAL DEFAULT 0,
  late_grace_min INTEGER DEFAULT 10,
  strike_limit INTEGER, strike_window_days INTEGER DEFAULT 365, cancel_counts_as_strike INTEGER DEFAULT 0,
  cancel_channel TEXT,                 -- sms | portal | phone
  auto_cancel INTEGER,                 -- NULL = not asked yet (treated as off), 0 = ask me, 1 = engine may cancel
  policy_source TEXT, policy_verified_at INTEGER);

CREATE TABLE commitments (
  id TEXT PRIMARY KEY, user_id TEXT, provider_id TEXT, cal_event_id TEXT,
  title TEXT, starts_at INTEGER, ends_at INTEGER, location TEXT, travel_min INTEGER,
  booked_at INTEGER, importance INTEGER DEFAULT 5,
  status TEXT DEFAULT 'confirmed',     -- tentative | confirmed | cancel_sent | cancelled | rescheduled | attended | late | missed
  cancel_deadline INTEGER, deadline_rule TEXT,        -- '24h' | '48h' | 'walkback'
  send_at INTEGER, decision_at INTEGER, origin_event_id TEXT,
  attend_confirmed INTEGER DEFAULT 0); -- set by "I'm going" (used by deadline_policy = unless_confirmed)

CREATE TABLE cancellations (           -- receipts, for fee disputes
  commitment_id TEXT PRIMARY KEY, sent_at INTEGER, channel TEXT, body TEXT,
  provider_ack_at INTEGER, provider_ack_text TEXT, status TEXT);  -- sent | acked | unacked | failed

CREATE TABLE outcomes (
  commitment_id TEXT PRIMARY KEY, result TEXT,   -- on_time | late | missed | cancelled_by_me | cancelled_by_them
  minutes_late INTEGER, reason TEXT,             -- optional: overslept | forgot | transport | conflict | other
  recorded_via TEXT, recorded_at INTEGER);

CREATE TABLE signals (
  id INTEGER PRIMARY KEY, user_id TEXT, kind TEXT,   -- wake | bed | tg_interaction | arrive | leave
  ts INTEGER, value TEXT);

CREATE TABLE predictions (
  id INTEGER PRIMARY KEY, commitment_id TEXT, made_at INTEGER,
  p_miss REAL, p_late REAL, features_json TEXT, model_version TEXT);

CREATE TABLE decisions (
  id INTEGER PRIMARY KEY, commitment_id TEXT,
  kind TEXT,                           -- keep | propose_reschedule | cancel | late_notice | alarm
  made_at INTEGER, cost_keep REAL, cost_alt REAL, cost_cancel REAL, reasons_json TEXT,
  mode TEXT,                           -- shadow | suggest | auto
  veto_until INTEGER, vetoed_at INTEGER, executed_at INTEGER);

CREATE TABLE strikes (
  id INTEGER PRIMARY KEY, provider_id TEXT,
  kind TEXT,                           -- noshow | late | resched | cancel
  at INTEGER, expires_at INTEGER);
```

## 4. Signals (iPhone-friendly)

| Signal | Source | Notes |
|---|---|---|
| Wake and bed times | Shortcuts automation on the **Sleep** triggers (Wake Up, Bedtime) posting to `POST /signal` | Without an Apple Watch or third-party tracker, iOS records your *scheduled* sleep, not measured sleep. Wake time is the reliable signal; sleep duration is approximate. |
| Activity rhythm | Your own taps and replies to the Telegram bot, plus doorbell round-trip latency | Screen Time data is **not** available to Shortcuts or any API, so this is the substitute: a "responsive hours" heatmap from first-party data. |
| Calendar load | Calendar Gateway | Events per day, gaps between commitments. |
| Travel time | A routing API (Google Routes, Mapbox, or OSRM) from your usual origin | Home and work as coarse labeled places. |
| Outcomes | One-tap check-in 15 minutes after each start: `[On time] [Late] [Missed]` (optional reason) | The training label. Geofence arrival can be added later but is less reliable. |

Location tracking is optional and off by default. The check-in button alone is enough to start.

## 5. Risk model

**Base rate (learned from your history).** For each bucket (hour block x weekday class x category), use a Beta-smoothed rate shrunk toward your global rate: `base = (misses_in_bucket + global_rate * k) / (n_in_bucket + k)`, with `k = 8`.

**Adjustments (log-odds).** Starting weights are hand-set priors, not research-derived. After 30 or more recorded outcomes, refit them with L2-regularized logistic regression:

| Feature | Starting weight |
|---|---|
| Sleep deficit, per hour below 7 | +0.35 |
| Wake-to-start gap under 90 min | +0.8 |
| Travel over 30 min | +0.6 |
| Booked more than 14 days ahead | +0.4 |
| Any miss in the last 60 days | +0.5 |

Every prediction is logged in `predictions` with its features and a plain-language reason ("3 of your last 5 appointments before 9:00 were late").

**Rules mode until the data exists.** With fewer than 30 outcomes the engine does **not** use probabilities. A cancel can then be triggered only by deterministic conditions: you told the bot you can't make it, a hard calendar conflict exists, or the wake-to-start gap is impossible given a fixed earlier commitment. Probabilities are shown only after calibration is checked (weekly Brier score versus the baseline "always predict your global rate").

**Deadline policy setting (`deadline_policy`):**
- `engine` (default): at the deadline, cancel only when the decision engine says cancel (or a rules-mode condition fires).
- `unless_confirmed`: at the deadline, cancel **every** appointment you have not confirmed with `[I'm going]`. This needs no model, turns "undecided" into an explicit yes or an automatic no, and works from day one.

## 6. Decision engine and deadlines

### 6.1 Expected cost

At each checkpoint compare:

- **Keep:** `p_miss * (fee_noshow + strike_cost + delay_cost_per_day * rebook_delay_days) + p_late * fee_late`
- **Propose reschedule:** `friction + fee_resched + delay_cost_per_day * delay_days` plus the keep formula on the *new* slot's probabilities.
- **Cancel:** `fee_cancel + friction + delay_cost_per_day * rebook_delay_days + value_lost`. Cancel is treated as a deferral (you rebook), so `value_lost` defaults to 0.

Pick the cheapest, but leave "keep" only if the saving exceeds `max(minSavings, 15% of keep)`. This margin prevents flip-flopping. After the deadline passes, `fee_resched` and `fee_cancel` jump to the penalty, which pushes the engine toward "keep and show up."

**Mode matters:** a `checkpoint` decision may result in `propose_reschedule`. A `deadline` decision (the final one at `decision_at`) can only be **keep or cancel**, because rescheduling needs your pick. If you ignored a proposal, the engine falls back to keep or cancel at the deadline.

### 6.2 The 24h/48h business-day rule

```
t = start - notice (24h)
if t is a weekend or US federal holiday:  t = start - (notice + 24h)     -- your 48h rule
while t is a weekend or federal holiday:  t = previous business day at office close (default 17:00)   -- safety walk-back
send_at     = t - 60 min          (delivery buffer)
decision_at = send_at - 2 h       (veto window; never earlier than now)
```

The walk-back is needed for cases the 48h rule alone doesn't cover. A Monday 9:00 appointment lands on Sunday at 24h and Saturday at 48h, both closed, so the cancellation would only be read after the deadline. The walk-back moves it to Friday at 17:00. Federal holidays use the standard observed dates (a Saturday holiday is observed the Friday before; a Sunday holiday the Monday after). Offices may keep different hours or close on other days; the provider record can override office days and hours. All dates are computed in the provider's time zone with DST handled by `Intl`.

If a booking is made so late that the computed deadline is already in the past, the engine skips the free-cancel path, applies the fee window costs, and asks you.

```js
// BEGIN decide.js
const logit = (p) => Math.log(p / (1 - p));
const sigmoid = (x) => 1 / (1 + Math.exp(-x));
const clamp = (p, lo = 0.01, hi = 0.99) => Math.min(hi, Math.max(lo, p));

// Beta-smoothed bucket rate shrunk toward the global rate.
function baseRate({ hits, n, globalRate, priorStrength = 8 }) {
  return clamp((hits + globalRate * priorStrength) / (n + priorStrength));
}

// Hand-set priors; refit by regularized logistic regression once >= 30 outcomes exist.
const W = { sleepDeficitPerHour: 0.35, tightWake: 0.8, longTravel: 0.6, farLead: 0.4, recentMiss: 0.5 };

function adjust(p, f) {
  let z = logit(clamp(p));
  z += W.sleepDeficitPerHour * Math.max(0, 7 - (f.sleepHours ?? 7));
  z += W.tightWake * (f.wakeGapMin != null && f.wakeGapMin < 90 ? 1 : 0);
  z += W.longTravel * ((f.travelMin ?? 0) > 30 ? 1 : 0);
  z += W.farLead * ((f.leadDays ?? 0) > 14 ? 1 : 0);
  z += W.recentMiss * ((f.missesLast60d ?? 0) > 0 ? 1 : 0);
  return clamp(sigmoid(z));
}

// Fees that apply if you act now (after the cancel deadline the penalty applies).
function feesAt(nowMs, startMs, policy) {
  const inside = (startMs - nowMs) < policy.cancelWindowH * 3600e3;
  return {
    feeResched: inside ? (policy.feeLateCancel ?? policy.feeNoShow) : policy.feeResched ?? 0,
    feeCancel: inside ? (policy.feeLateCancel ?? policy.feeNoShow) : 0,
  };
}

function expectedCost(o, p) {
  return p.miss * (o.feeNoShow + o.strikeCost + o.delayCostPerDay * o.rebookDelayDays) + p.late * o.feeLate;
}

// mode 'checkpoint': keep | propose_reschedule | cancel.
// mode 'deadline':   keep | cancel only (rescheduling needs the owner's pick).
function decide(o) {
  const keep = expectedCost(o, o.p);
  const alt = (o.mode !== 'deadline' && o.alt)
    ? o.friction + o.feeResched + o.delayCostPerDay * o.alt.delayDays + expectedCost(o, o.alt.p)
    : Infinity;
  const cancel = o.allowCancel
    ? o.feeCancel + o.friction + o.delayCostPerDay * o.rebookDelayDays + (o.valueLost ?? 0)
    : Infinity;
  const margin = Math.max(o.minSavings ?? 5, 0.15 * keep);

  let action = 'keep', best = keep;
  for (const [a, c] of [['propose_reschedule', alt], ['cancel', cancel]]) {
    if (c < best) { action = a; best = c; }       // proposing a reschedule wins ties over cancelling
  }
  if (action !== 'keep' && keep - best <= margin) action = 'keep';
  return { action, keep, alt, cancel, margin };
}
// END decide.js
```

```js
// BEGIN deadline.js
const HOUR = 3600e3;
const pad = (n) => String(n).padStart(2, '0');
const key = (y, m, d) => `${y}-${pad(m)}-${pad(d)}`;

function partsInTz(ms, tz) {
  const f = new Intl.DateTimeFormat('en-US', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' });
  const o = Object.fromEntries(f.formatToParts(new Date(ms)).map((p) => [p.type, p.value]));
  return { y: +o.year, m: +o.month, d: +o.day, hh: +o.hour, mm: +o.minute, ss: +o.second };
}
function tzOffsetMs(ms, tz) {
  const p = partsInTz(ms, tz);
  return Date.UTC(p.y, p.m - 1, p.d, p.hh, p.mm, p.ss) - Math.floor(ms / 1000) * 1000;
}
function zonedToMs(y, m, d, hh, mm, tz) {                 // local wall time in tz -> epoch ms (DST-safe)
  const guess = Date.UTC(y, m - 1, d, hh, mm);
  const t0 = guess - tzOffsetMs(guess, tz);
  return guess - tzOffsetMs(t0, tz);
}

function nthWeekday(y, m, dow, n) {                       // day of month; n = 1..4, or -1 for the last one
  if (n > 0) {
    const first = new Date(Date.UTC(y, m - 1, 1)).getUTCDay();
    return 1 + ((dow - first + 7) % 7) + (n - 1) * 7;
  }
  const last = new Date(Date.UTC(y, m, 0));
  return last.getUTCDate() - ((last.getUTCDay() - dow + 7) % 7);
}
function observed(y, m, d) {                              // Sat -> Fri, Sun -> Mon
  const dt = new Date(Date.UTC(y, m - 1, d));
  const dow = dt.getUTCDay();
  if (dow === 6) dt.setUTCDate(d - 1); else if (dow === 0) dt.setUTCDate(d + 1);
  return key(dt.getUTCFullYear(), dt.getUTCMonth() + 1, dt.getUTCDate());
}
function federalHolidaysFor(y) {
  return [
    observed(y, 1, 1), key(y, 1, nthWeekday(y, 1, 1, 3)), key(y, 2, nthWeekday(y, 2, 1, 3)),
    key(y, 5, nthWeekday(y, 5, 1, -1)), observed(y, 6, 19), observed(y, 7, 4),
    key(y, 9, nthWeekday(y, 9, 1, 1)), key(y, 10, nthWeekday(y, 10, 1, 2)), observed(y, 11, 11),
    key(y, 11, nthWeekday(y, 11, 4, 4)), observed(y, 12, 25),
  ];
}
function isBusinessDay(y, m, d) {
  const dow = new Date(Date.UTC(y, m - 1, d)).getUTCDay();
  if (dow === 0 || dow === 6) return false;
  const k = key(y, m, d);
  return ![y - 1, y, y + 1].some((yy) => federalHolidaysFor(yy).includes(k));
}

function cancelDeadline({ startMs, noticeH = 24, tz = 'America/Los_Angeles', closeHour = 17 }) {
  const biz = (ms) => { const p = partsInTz(ms, tz); return isBusinessDay(p.y, p.m, p.d); };
  let t = startMs - noticeH * HOUR;
  let rule = `${noticeH}h`;
  if (!biz(t)) { t = startMs - (noticeH + 24) * HOUR; rule = `${noticeH + 24}h`; }
  while (!biz(t)) {                                       // safety walk-back to the last business close
    const p = partsInTz(t, tz);
    const prev = new Date(Date.UTC(p.y, p.m - 1, p.d - 1));
    t = zonedToMs(prev.getUTCFullYear(), prev.getUTCMonth() + 1, prev.getUTCDate(), closeHour, 0, tz);
    rule = 'walkback';
  }
  return { deadlineMs: t, rule };
}
function schedule(deadlineMs, { bufferMin = 60, vetoH = 2 } = {}, nowMs = Date.now()) {
  const sendAt = deadlineMs - bufferMin * 60e3;
  return { sendAt, decisionAt: Math.max(nowMs, sendAt - vetoH * HOUR) };
}
// END deadline.js
```

## 7. Autonomy and guardrails

| Level | Power |
|---|---|
| 0 Shadow | Decide silently, log only (default for the first 2 weeks; `/live` skips it) |
| 1 Suggest | Telegram card with a one-tap approve |
| 2 Auto-confirm | Confirm routine, verified appointments (iPhone addendum standing rules) |
| 3 Auto-cancel | Send the cancellation at the deadline per section 6, after the veto window |

**Rescheduling is never autonomous at any level.** It is always a proposal you tap.

**Rules:**
- **One-time opt-in per provider.** The first time a cancel would apply to a provider, the bot asks once: `[Auto-cancel for <provider>] [Ask me each time]`. Until answered, that provider is treated as "ask me." One tap per provider, and you stay in control of which providers (for example doctors or legal appointments) the engine may cancel for.
- **Cancel is a deferral, not a disappearance.** Every cancel card includes the best rebooking proposals (section 8), and the engine nudges you if nothing is rebooked within 7 days (3 days for health providers). This protects against the real risk of auto-cancel: a gap in care or a missed deadline that you never rebook.
- **Channel check.** The engine auto-cancels only through a channel it can use (SMS via the actuator). For portal-only or phone-only providers, it escalates at `decision_at` with a draft or script and a louder reminder.
- **Receipts.** Every cancellation is stored with timestamp and body. If the provider doesn't acknowledge within 2 business hours, you get a ping; the receipt supports a fee dispute.
- **Truthful messages only:** "Hi, this is <name>. I need to cancel my <date, time> appointment. Please confirm. Thank you." The engine never invents a reason.
- **Strike awareness:** if `cancel_counts_as_strike` is set, or the provider is within one strike of its limit, the engine prefers keep and asks you.
- **Rate limits:** at most 3 autonomous cancels per week overall, 1 per provider per month (both configurable).
- **Veto and undo:** the decision card at `decision_at` has `[Keep it]`. After sending, `[Undo]` re-requests the original slot where possible.
- **Kill switch:** `/pause` freezes all autonomy; `/shadow` returns to Level 0.
- **Earn promotion:** for the engine mode, move up a level only if the shadow decisions would have saved money versus "always keep" and the Brier score beats the baseline. Promotion is a card you approve. (`unless_confirmed` mode doesn't depend on the model.)

## 8. The daily loop and reschedule proposals

**Booking or offer arrives** (a text like "we have Tue 9:00 or Thu 3:00"): list the candidate slots, filter by calendar free/busy and travel, score each, and send you the **top 3 with reasons** as buttons. Tapping one sends the request through the actuator. If you don't tap, nothing is sent.

**Slot score** (lower is better): the expected cost of keeping that slot (from `p_miss` and `p_late`), plus a fragmentation penalty (small gaps and back-to-back appointments), plus an activity penalty for hours outside your usual responsive window or less than about 90 minutes after your typical wake time. Each option shows its reasons ("2 h after your usual wake time, free before and after").

**Checkpoints per commitment:**
1. **On booking:** compute `cancel_deadline`, `send_at`, `decision_at`, and the rule used (24h, 48h, or walk-back). Add the event to the calendar.
2. **T-72h and T-48h:** recompute risk. If it is high, send a reschedule proposal early, while the free-cancel window is still wide open.
3. **`decision_at`:** make the final keep-or-cancel decision (deadline mode). Post the veto card. Silence means proceed.
4. **`send_at`:** send the cancellation, store the receipt, and attach rebooking proposals.
5. **Wake-up (daily):** the Sleep "Wake Up" signal triggers a portfolio check. If today's load exceeds your predicted capacity, the engine **proposes** deferring the lowest-cost item that is still inside its free-cancel window.
6. **Alarms and reminders:** the engine sets tomorrow's wake alarm so that `wake = first_start - prep - travel - buffer` (the buffer comes from your own lateness history), via a `type: "alarm"` response from `/claim` handled with the Shortcuts "Create Alarm" action. Reminder ladder: T-90 min "get ready," T-leave "go now," T+5 min with no arrival signal: send a **late notice** ("Running about 10 minutes late") if you opted in for that provider.
7. **T+15 min:** outcome check-in. The answer updates the outcome, the strike ledger, and the model.

## 9. Phases and what is realistic

Build these *after* Switchboard Phases 0-3 work.

| Phase | Work | Time | Value on its own |
|---|---|---|---|
| S1 | Calendar read, Policy Ledger (hand-seeded), commitment tracker, **deadline calculator**, deadline alerts, outcome check-ins | 1-2 days | Saves fees through timely warnings; collects labels |
| S2 | Wake and bed signals, auto wake alarm, reminder ladder, late notice | 1-2 days | The "I just show up" part |
| S3 | Cancellation sender, receipts, per-provider opt-in, veto cards, `unless_confirmed` mode, shadow mode | 1-2 days | Automatic cancels from day one without needing a model |
| S4 | Rules-mode risk checks, prediction logging, weekly calibration report | 1 day | Honest probabilities |
| S5 | Offer parsing and top-3 reschedule proposals | several days | Removes the back-and-forth |
| S6 | Model-driven `engine` mode after promotion, portfolio proposals, geofence outcomes | later | The full "hedge desk" |

The risk model needs roughly 30 recorded outcomes before it earns trust, which can take weeks. Phases S1-S3 are rules and timing, so they are useful immediately.

## 10. Test scenarios

**Decision engine** (placeholder costs: no-show fee $50, late fee $10, strike cost $20, delay cost $2 per day, rebook delay 7 days, friction $5):

| # | Scenario | Expected |
|---|---|---|
| 1 | Checkpoint, `p_miss` 0.5, `p_late` 0.3; alt slot with `p_miss` 0.1, `p_late` 0.1, 3 days later; cancel not allowed | propose_reschedule |
| 2 | Same alt, `p_miss` 0.05, `p_late` 0.05 | keep |
| 3 | High risk, no alt, cancel not allowed | keep |
| 4 | Alt only slightly cheaper (within margin) | keep (no flip-flop) |
| 5 | Same as 1 but the reschedule fee is the $50 penalty | keep |
| 6 | High risk, cancel allowed, `value_lost` 15, no alt | cancel |
| 7 | Deadline mode, high risk, cancel allowed, alt slot offered | cancel (alt ignored) |
| 8 | Deadline mode, low risk, cancel allowed | keep |
| 9 | Deadline mode, high risk, provider not opted in | keep (and the engine escalates to you) |
| 10 | `baseRate({hits: 0, n: 0, globalRate: 0.2})` | 0.2 |
| 11 | `baseRate({hits: 3, n: 5, globalRate: 0.2})` | about 0.354 |
| 12 | `adjust(0.2, {sleepHours: 4})` vs `{sleepHours: 8}` | higher with less sleep |

**Deadlines** (all `America/Los_Angeles`, 24h notice, close at 17:00):

| # | Appointment | Expected deadline | Rule |
|---|---|---|---|
| a | Wed Oct 14, 2026 10:00 | Tue Oct 13 10:00 | 24h |
| b | Tue Oct 13, 2026 10:00 (Mon Oct 12 is a federal holiday) | Fri Oct 9 17:00 | walk-back |
| c | Thu Nov 12, 2026 10:00 (Wed Nov 11 is a federal holiday) | Tue Nov 10 10:00 | 48h |
| d | Mon Oct 19, 2026 09:00 | Fri Oct 16 17:00 | walk-back |
| e | Fri Nov 27, 2026 10:00 (Thursday is Thanksgiving) | Wed Nov 25 10:00 | 48h |
| f | Mon Jul 6, 2026 10:00 (Jul 4 is a Saturday, observed Fri Jul 3) | Thu Jul 2 17:00 | walk-back |
| g | Mon Nov 2, 2026 09:00 (DST ends Nov 1) | Fri Oct 30 17:00 | walk-back |

Also: `isBusinessDay` is false for Oct 12, 2026 and for Dec 31, 2027 (New Year's Day 2028 falls on a Saturday), true for Oct 13, 2026.

## 11. Privacy and limits

- Sleep, location, and appointment data are sensitive. Keep it in your own Cloudflare account, collect only what each phase needs, make location opt-in, and set retention (raw signals 90 days, aggregates longer).
- Auto-cancel protects fees and strikes but can also leave you without care or service you wanted. That is why every cancel includes rebooking proposals, why each provider is opted in once, and why the engine nags if nothing is rebooked.
- Some providers only accept cancellations by phone or portal. For those the engine can warn and draft, but not send.
- A scheduled-sleep signal is not measured sleep. Accuracy improves with a wearable or a third-party tracker.
- The engine optimizes attendance and fees; it does not explain why attendance is hard. If misses are a pattern, the outcome log is useful to bring to a provider.
- Expect early mistakes. That is why shadow mode, veto windows, rate limits, receipts, and the kill switch come first.
