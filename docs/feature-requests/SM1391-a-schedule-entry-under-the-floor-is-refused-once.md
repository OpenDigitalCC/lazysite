---
id: SM1391
title: "SM1391: a schedule entry under the floor is recorded as refused, once"
subtitle: "Ruling 148: a hand-written schedule entry below the 300-second floor was passed over in silence, which reads exactly like a job with nothing to do. The daemon now records one refusal naming the floor, and lazysite check names the entry."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "release manager (ruling 148)"
area: forms
status-note: "SHIPPED (PENDING) on n763, ruling 148: Daemon::Jobs::schedule_run records a refusal (outcome refused, naming the 300 s floor) in schedule-runs.json the first time it meets an enabled entry under the floor, logs it then, and writes nothing on later ticks; lazysite check names such entries. t/unit/daemon/17, t/tools/332."
---

# What happened

The SM1382 spike wrote `every: 60` into `schedule.conf` by hand - the save path
refuses it, so by hand is the only way one gets there - and drove the scheduler
through two ticks. The entry never ran, `schedule-runs.json` held nothing for
it, and the log said nothing: `due_entries` passed over it. An entry that never
runs and says nothing is indistinguishable from a job with nothing to do, which
is the rule the scheduler's own identity refusals were written to.

# What was built

- `Lazysite::Handlers::below_floor_entries`: the enabled, valid-payload entries
  whose `every` is not a number or is under `$SCHEDULE_FLOOR`.
- `Lazysite::Daemon::Jobs::schedule_run`: for each, the first tick that meets it
  writes `{ outcome: refused, refused_at, refusal_reason }` against the entry
  in `lazysite/daemon/schedule-runs.json`, the reason naming the value, the
  floor and that the entry was written by hand, and logs a WARN
  (`schedule entry refused`). A later tick that finds the same reason already
  recorded writes nothing, so the record is not rewritten every five minutes.
  The refusal is in the job's `detail.refused` list that tick. An entry raised
  to the floor runs on the next tick.
- `lazysite check` (`report_schedule_floor`): a text scan of `schedule.conf`
  naming each enabled entry under the floor with its value, and the remedy; OK
  when every entry is at or above it. A disabled entry is off on purpose and
  is not named.

Tests: `t/unit/daemon/17` (recorded and logged once; unchanged on the next
tick; runs when raised) and `t/tools/332` (named, with a non-numeric value,
without the entry at the floor or the disabled one; OK and silent otherwise).
Each fails with its part reverted. `t/integration/360`'s floor subtest now
asserts the refusal.
