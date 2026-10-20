---
id: SM1218
title: "SM1218: a write with no answer is not known, and the page is told so"
subtitle: "A write whose request was sent and got no answer (a read timeout) was reported failed, though Odoo had done it, and a page told the person to try again. The answer now says the outcome is not known."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "the 0.15.11 edge walk (row Z7, finding G-1), and OOM's note of 2026-10-20"
area: odoo
status-note: "SHIPPED (PENDING) on n704: apply-incomplete carries unknown, counts.unknown and per-change outcome unknown with OOM's reason, in process and through oomd; a form is not delivered. t/unit/odoo/91, 92."
---

# What happened

The edge-testing agent's 0.15.11 results, "Finding":

> G-1, a write that timed out is reported as failed, though Odoo did it
> : In Z7 the submit call timed out on the transport, and the answer marks the change
> `outcome: failed`. The sheet was submitted all the same: its state read back
> `confirm`, and the next submit found it so. A page that believes "failed" may tell
> the person to try again, or a queue may give up on a change that happened.

OOM's note (inbox, 2026-10-20, "A call that timed out is reported failed, though Odoo
did it"): "Failed tells a caller the change did not happen. A page then tells the
person to try again ... For a call that is not idempotent, trying again can do it
twice." OOM 0.38 answers that case as unknown (`counts.unknown`, `unknown_changes`
with a `reason`), and [[SM1216]] vendored it.

# Cause

lazysite already passed the change's outcome `unknown` in `changes` (SM1171), but
nothing else of OOM's answer: no `unknown_changes`, no reason, and an answer whose
error sentence said "the plan did not apply completely", as for a refusal. A form
whose other change was done was delivered (SM1148's rule did not look at
`counts.unknown`).

# What shipped

- Kind stays `apply-incomplete` (207, `ok` 0), so no page that checks `ok` or `kind`
  changes; a new kind would have been a second thing every page had to learn. The
  answer gains `unknown: N`; `result.counts.unknown` is carried; each unknown
  change's entry has `outcome: unknown`, `unknown: 1`, `key`, `code`, `message` and
  OOM's `reason`, through SM1186's `_usage_text` (a path, a trace or a secret's name
  withholds the message whole, `withheld: 1`).
- `error` says it is not known whether Odoo made the change. Nothing advises a retry.
- A form is not delivered on an unknown change, and its `why` is that sentence.
- starter/docs/odoo.md says what a page does: read back before repeating.
- Both paths (in process, oomd), confirm and immediate.

Evidence: t/unit/odoo/91 (OOM's fake Odoo throws a sent, write transport error) and
92 (the real oomd, a test pack whose one change does the same) fail on the code as it
was and pass now. Nothing writes to a real Odoo.

# Not done

- A page that wants to read back needs a read binding for the record; lazysite does
  not choose one.
