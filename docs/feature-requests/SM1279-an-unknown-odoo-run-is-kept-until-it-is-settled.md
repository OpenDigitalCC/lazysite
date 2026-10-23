---
id: SM1279
title: "SM1279: an unknown Odoo run is kept until it is settled or dismissed"
subtitle: "Ruling 10c: no expiry. The plan store pruned a plan after seven days, the daemon's run folders on the same schedule, and a confirmed plan's file bytes once it applied. A run left unknown and still open now keeps all three, because a resume reads them."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "the release manager, ruling 10c (2026-10-23)"
area: odoo
status-note: "SHIPPED (PENDING) on n733: _prune_plans skips an open unknown run and keeps the daemon run folder it names; _plan_spent holds the bytes of an apply that left a change unknown; resume purges them once settled, and SM1278's dismiss does the same. t/unit/odoo/109."
---

# What was asked

Ruling 10c (2026-10-23): "a run stays resumable until it is settled or dismissed (no
expiry)".

# What stood in the way

- **The plan store's days.** `_prune_plans` removed `plans/<id>/` once its
  `created` was older than `$PLAN_KEEP_DAYS` (7), and `_prune_runs` removed a daemon run
  folder older than that. Those folders hold the run's plan and journal, and
  `Runner->resume_plan` needs both.
- **The file bytes.** SM1162 purges a plan's `blobs/` once the plan is spent, and an
  apply that ended unknown counted as spent. A change carried by a resume (one read back
  or assumed as not made) is resolved from those blobs, so a file it sends had no bytes
  left.

# What shipped

- **`_open_unknown($meta)`**: a plan that ended unknown and is not settled, dismissed
  or withdrawn.
- **`_prune_plans`** skips such a plan, whatever its age. It passes the daemon run ids
  such plans name to **`_prune_runs`**, which skips them too.
- **`_plan_spent`** answers no for an apply whose result counts an unknown change, so a
  confirm keeps the plan's bytes.
- **On settle** (SM1275's resume): the settled run's bytes are purged. So are the
  resumed plan's, once that plan is spent itself. SM1278's dismiss purges them too.
- A settled or dismissed run then goes on the ordinary schedule, by the age it was made.

# Tests

t/unit/odoo/109:

- **A file write that ended unknown keeps its bytes.**
  - A confirmed `core.attach` whose create got no answer keeps `blobs/`.
  - Assumed not made, the resume sends the attachment with its bytes.
  - Once settled, the bytes go.
- **An open run outlives the store's days.**
  - With the plans aged 37 days, the next plan's prune keeps the open run and the daemon
    run folder it names.
  - It removes the settled run, an ordinary plan, and a run folder nothing names.
  - The open run is still resumable.

With Odoo.pm at SM1275, both subtests fail: the bytes are gone, so the resume cannot
send the file, and the open run and its daemon folder are pruned.
