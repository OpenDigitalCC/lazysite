---
id: SM1105
title: "SM1105: the outbox list says an entry was sent"
subtitle: "An entry the job sent and could not remove is listed as sent, not queued, and the failed removal is logged."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: 0.15.6 test plan (edge.explore.lazysite.io), row R2
area: notifications
status-note: "SHIPPED on n614: Lazysite::Outbox _ledger_events, outbox_list, rule_states; t/unit/notify/07."
---

# What happened

The 0.15.6 test plan, row R2 (bell rule to zz56-bell, three events):

> the rule's counters show sent 3. Inconsistency: notify-outbox-list for that
> rule still listed the three as queued with job "refused" after they were sent.

The rule's counters come from the job's own tally; the list came from the
files in the outbox. The job sends, then removes the entry, and did not look
at whether the removal worked. An entry that stays (the directory is one the
job's account may read and not write) is found again on every run; the
ledger, which stops an event going twice, skips everyone already sent to, so
nothing is resent, but the list had no way to know and showed the entry as
queued, and the rule's row counted it as waiting.

# What shipped

- The ledger records the event id with each decision. The list reads it: an
  entry never retried that the ledger shows as sent is listed with state
  `sent` (or `handled` when every recipient was refused or folded into a held
  message), is not counted in the rule's queued total, and does not make the
  rule say it is waiting for the scheduler.
- When the job cannot remove a sent entry it logs a warning naming the rule,
  the event and the reason.
- The job block of the list carries `refused_at`, so a refusal is dated. A run
  replaces the job's record, so the `outcome` shown is the latest.

Ledger rows written before this carry no event id and say nothing about their
entry; those entries are listed as before.

t/unit/notify/07.
