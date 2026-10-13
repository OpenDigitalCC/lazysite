---
id: SM1071
title: "SM1071: a notice over the cap is folded into the next message"
subtitle: "SM1010 R1. The notify-outbox job refused an event past a rule's per-recipient cap; Q7 was ruled as recommended - later events within the hour are folded into the next message. Now they are held and sent as one."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-13
raised-by: SM1010 R1, ruled 2026-10-12 (Q7 "as this brief recommended")
area: notifications
status-note: "SHIPPED (PENDING): past per_recipient_hour an event is held in notify/folds/ (audited `held`), and every later one while something is held joins it; when the cap next allows, the job sends one message carrying them in order, counted against the cap. 50 events a fold; a cap of 0 still sends nothing. t/unit/lib/93, t/unit/notify/03."
---

# The ruling

The release manager, 2026-10-12 (SM1010 "Ruled"): "Everything else as this
brief recommended ... Q7 (per event, one message per recipient per hour per
rule) ... stand[s] as recommended." The recommendation (SM1010 Q7): "per event,
with one message per recipient per post per hour; later comments within the
hour are folded into the next message. A daily digest is phase 3."

# What was wrong

Phase 1 (SM1020) built the cap as a refusal: `Lazysite::Outbox::_process`
audited the recipient as failed and marked the ledger `refused`, so a member
following a busy thread was told of the first comments in each hour and never
of the rest (SM1010 R1: "a recipient over the cap is refused and audited;
later comments are not folded into the next message").

# What was built

- **Held, not refused.** Past `per_recipient_hour`, the event is added to a
  fold - one file per rule, channel and recipient under `notify/folds/`, named
  by a hash of the three - and audited `held` (the audit row's status: neither
  sent nor refused). The ledger marks the event `folded`, so a retry of the
  entry does not fold it twice.
- **In order.** While a fold exists for a recipient, every later event for
  that recipient joins it even if the cap would allow it alone, so nothing
  overtakes what is waiting. Outbox entries are now named by the microsecond,
  so two events of the same second are taken in the order they came (an entry
  named by the second, from before, is read as such).
- **One message.** At the end of each run the job sends every fold whose
  recipient's cap now allows it: each held event composed as it would have
  been sent alone, joined in order, the Subject the first one's with "(and N
  more)", one unsubscribe line and the `List-Unsubscribe` header. The bell
  folds the same way ("N updates: ..."). The message counts against the cap
  like any other. A transport failure retries with the entry back-off; after
  five attempts the fold moves to `notify/failed/`.
- **Bounds.** A fold holds 50 events; past that an event is refused and
  audited by name. A cap of 0 sends nothing and holds nothing, as before. A
  fold whose rule has gone, changed type or been switched off is given up,
  kept in `notify/failed/` and audited.
- **What a fold holds**: the events' bounded fields and actors, and for an
  address recipient the address - as an outbox entry holds its fields - only
  until it is sent.

Templates need no change: each event is rendered with the rule's template as
before. The per-member digest preference (SM1034 phase 3) is not this.

# Tests and sabotage

- `t/unit/lib/93` - the events past the cap arrive in the next message, in
  order, with one footer, on email and the bell; the folded message counts
  against the cap; a later event joins the fold rather than overtaking it; a
  retry does not fold twice; another recipient is not held up; a cap of 0; a
  fold whose rule has gone; the fold's size.
- `t/unit/notify/03` - its cap case now expects `held`.

| Ref | Sabotage | Caught by |
| --- | --- | --- |
| S1 | the cap refuses again (no fold) | 93 |
| S2 | a later event no longer joins an existing fold | 93 |
| S3 | the flush ignores the cap | 93 |
| S4 | the folded message carries only the last event | 93 |
| S5 | main's `Outbox.pm` (the reproduction) | 93 |
