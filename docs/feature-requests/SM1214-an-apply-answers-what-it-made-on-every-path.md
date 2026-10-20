---
id: SM1214
title: "SM1214: an apply answers the ids it made and a hold's reason on every path"
subtitle: "The OOM Lab reported created: {} after an immediate write and a hold's reason missing from one app; every path already answers both, and one test now holds all four."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "OOM Lab HR apps on Odoo 18, L-21 (timesheet) and L-20 (attendance), inbox 2026-10-19-odoo-extension-findings-from-the-hr-apps.md"
area: odoo
status-note: "SHIPPED (PENDING) on n702: no engine change - the answer already carries both on all four paths. t/unit/odoo/85 holds them; docs say when created is empty."
---

# What happened

Two Lab findings (also filed as SM1215, which this closes):

- L-21 (timesheet): "An immediate write still returns no ids (`created: {}`, as
  L-10)."
- L-20 (attendance): "Whether a hold's `reason` reaches the page: the time-off
  agent saw it arrive, while the attendance agent reports only `counts` and
  `by_bucket`."

# What was found

[[SM1165]] (`created`, `written`) and [[SM1171]] (`changes`, with `reason`) built
the answer in `Lazysite::Odoo::_result_summary`, and every path that answers a
write goes through it: `_run` (immediate, in-process, Odoo.pm), `confirm`
(in-process), and for oomd `_applied_answer` (immediate in `_run_daemon`,
confirm in `_confirm_daemon`). OOM's Runner puts a `create` change's id in
`created` (t/vendor/oom/lib/Odoo/Ops/Runner.pm:222-225), including one with
`ref` and `unique_by`, which is the timesheet line's shape.

t/unit/odoo/85 runs one operation (a held change with a reason, and a create
with `ref` and `unique_by`) on all four paths and asserts the new id in
`created` and the reason on the held change, in the plan view and in the answer.
It passes on the engine at 0.15.14 with no change: the premise of both findings
does not hold there.

The Lab's own pages explain the reports: the timesheet page never reads
`created` (assets/timesheet.js re-reads the day), and the attendance page reads
`by_bucket` only (assets/attendance.js:80); the timesheet agent's finding 5
records the reason in `result.changes[].reason`, which is what is meant. The
attendance clock is a `custom` change that calls a web route: OOM lists a custom
change in `created`/`written` only when its handler returns `reported`
(Runner.pm:224-226), so a route-based clock has no id there, and that is OOM's
to offer, not lazysite's.

# What shipped

- t/unit/odoo/85 and its test pack t/lib/LazysiteTest/OdooMade.
- starter/docs/odoo.md says when `created` is empty (a reused record, a custom
  change that reports nothing) and that `result.changes[].id` names the record
  either way.

# Not done

- A first-class way for a custom (route) change to report the record it made is
  an ask of OOM.
