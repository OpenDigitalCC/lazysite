---
id: SM1261
title: "SM1261: a confirm whose daemon run is gone is not-found"
subtitle: "A plan the daemon made, confirmed after its run folder or plan file has gone, answers `not-found` (404) and tells the visitor to make the plan again. It used to answer `config` (503), \"the Odoo connection is not configured correctly\"."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: "release manager, 2026-10-22 (ruling on SM1247's open question)"
area: odoo
status-note: "SHIPPED (0.16.1) on n727: Lazysite::Odoo confirm maps a daemon `config` failure with the run's plan file absent to refused/run-gone, kind not-found. t/unit/odoo/104."
---

# What was asked

[[SM1247]] found it while checking OOM 0.42's `unknown-run`. A plan made through oomd
is confirmed by its run id (`_confirm_daemon`: `approve`, then `apply`). The daemon
finds the plan by path, `lazysite/odoo/runs/<run_id>/plan.json`
(`Odoo::Ops::Service::_plan_path`). When that folder or that file is gone, OOM fails
in `Odoo::Ops::Plan->load` with "cannot read plan ...: No such file or directory",
kind `config`. lazysite told the page "the Odoo connection is not configured
correctly - see the event log", status 503. The connection was fine, and the
visitor was not told what to do. This was the same on OOM 0.38.

The release manager ruled on 2026-10-22: such a confirm answers kind `not-found`, with
a message telling the visitor to make the plan again.

# What shipped

- **`not-found`, "this plan is no longer held by the Odoo daemon - make the plan
  again".** In `Lazysite::Odoo::confirm`'s daemon branch, a failure of kind `config`
  is checked by `_daemon_run_gone`: if the run's `plan.json` is not in the daemon's
  runs directory (`Lazysite::Odoo::Daemon::runs_dir`), the failure is raised again as
  refused/`run-gone`. `%REFUSED_KIND` maps `run-gone` to `not-found`.
  - The message names no path.
  - The call record says `kind: not-found`, outcome `refused`.
  - Any other `config` failure, with the plan file present, is answered as before.
- **The status is 404.** It comes from the one map every surface uses
  (`Lazysite::Manager::Common::refusal_status`). So the page endpoint
  (lazysite-odoo.pl), the control API and MCP's `odoo_confirm` all answer 404, the
  same as for a plan lazysite does not hold.
- **The page script needs no change.** `lazysite-odoo.js` reacts to two kinds only:
  `csrf` (fetch a new token and send again) and `signin-required` (ask the person to
  sign in). Every other answer reaches the page as `{ status, data }`, with
  `data.error` the sentence. It is not retried, as `config` was not.
- **The Odoo guide's kind table** (starter/docs/odoo.md) names the case under
  `not-found`.

The plan stays in lazysite's own `plans/` and can still be withdrawn. It is not
treated as spent.

# Tests

t/unit/odoo/104, new, runs the real oomd (as 77 does). It checks three cases:

- **The run folder is removed:** the confirm answers `not-found`, the sentence says to
  make the plan again, no path is named, the status is 404, and the call record says
  `not-found` and `refused`.
- **Only the plan file is removed:** the same.
- **The run is still there:** the plan confirms as before.

On the code before this change, the first two cases answer `config` with status 503,
and 104 fails on kind, sentence, status and record.

# Not changed

- `last_via` stays undefined for a confirm the daemon refused, as for every daemon
  refusal.
- A confirm that falls back in-process (`odoo_daemon: on`, the daemon down) still
  applies lazysite's own copy of the plan. That path does not read the daemon's run
  folder.
