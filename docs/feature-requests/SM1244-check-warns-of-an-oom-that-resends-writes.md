---
id: SM1244
title: "SM1244: lazysite check warns of an OOM that can resend a write"
subtitle: "OOM 0.37 and earlier can send a write again when its answer timed out, so a change can be made twice in Odoo. The check now warns when the Odoo extension is on and the OOM the site loads, or oomd runs, is older than 0.38."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: "the release manager (task #376, part 1)"
area: odoo
status-note: "SHIPPED (PENDING) on n725: report_odoo_oom_version names the version and the file the site loads OOM from, and WARNs below 0.38 with the fix; report_odoo_daemon does the same for the OOM a running oomd reports. t/tools/214. Part 2 (a page resuming an unknown plan) is not built."
---

# What happened

OOM 0.38 (runs-38, [[SM1216]], [[SM1218]]) calls a write whose request was sent and
whose answer never came `unknown`, and it does not send it again. OOM 0.37 and earlier
can resend it, so the change can be made twice in Odoo. A site whose host still has an
older OOM gets no sign of this from lazysite.

# How the site finds OOM

The site loads OOM the way any Perl program does, with `require Odoo::Ops` on its
`@INC`. That is the installed `libodoo-oom-perl`, unless `PERL5LIB` names another copy.
The vendored `t/vendor/oom` (SM1216) is the test suite's copy and is never on a site's
path. `ODOO_OOM_SHARE` names where OOM's data is (behaviours, profiles, `matrix.yaml`),
not its code, so it does not decide the version. A call that oomd answers runs in
oomd's own OOM, which is the version its health answer reports.

# What shipped

- **`report_odoo_oom_version`** (tools/lazysite-check.pl) runs only while the Odoo
  extension is on. It asks the same question the site asks, in the same way:
  `Odoo::Ops::Version`, then `Odoo::Ops->VERSION`.
  - Below 0.38 it gives a WARN: "the Odoo extension is on and the OOM it loads is 0.37
    (FILE): OOM older than 0.38 can send a write again when its answer timed out, so a
    change can be made twice in Odoo". The fix is "install OOM 0.38 or later
    (libodoo-oom-perl >= 0.38, and odoo-oom-tools for oomd)".
  - At 0.38 or later it gives an OK line naming the version and the file.
  - Where OOM cannot be loaded it gives a WARN saying so, because every Odoo call is
    then refused.
- **`report_odoo_daemon`**: when oomd is running and reports an OOM older than 0.38,
  the same WARN is given for oomd, with "restart oomd" added to the fix.

# Tests

t/tools/214 runs the real check with `PERL5LIB` naming a stand-in OOM:

- 0.37: a WARN naming the version, the file, the risk and the fix;
- 0.31: warned;
- 0.38: no warning, and the OK line;
- extension off: nothing about OOM.

With the change reverted, all three extension-on subtests fail. The oomd line is not
covered by a test, because that needs a running oomd of an old version.

# Not done: part 2, a page resuming an `unknown` plan

This was not built. Here is what it would take:

- **OOM already has the mechanism.** `Odoo::Ops::Runner->resume_plan($ctx, $journal,
  assume_done => [...], assume_not_done => [...])` (and `Calls->resume`, and the CLI's
  `--assume-done` / `--assume-not-done`) reads each `unknown` change back first, by its
  own evidence:
  - a create by `unique_by`;
  - a write by the fields it wrote;
  - an unlink by the record's absence;
  - a call by its `verify`.

  It journals what it finds and refuses `unknown-outcome` for a change it cannot read
  back, unless the caller decides. The decision is journalled with the actor. The result
  is a new plan to apply.
- **lazysite would need:**
  1. A run handle a page can name again. Today the reply carries the counts and the
     `unknown` changes (SM1218), but no identifier of the run. The journal path is
     withheld on purpose (`_applied_changes` drops the host path).
  2. A new endpoint action (lazysite-odoo.pl), `resume`, taking the run id and the
     optional assume lists by change key. It would be refused unless the caller is the
     run's own actor or holds an override capability (OOM already refuses another
     login's apply), and refused for a public binding. It needs the same CSRF token
     rule as apply, the same rate limits, and an audit line naming the decision.
  3. The resumed plan applied through the same path as a first apply (in-process or
     oomd), with its result mapped by the existing `_add_unknown` and
     `_add_failed_changes`.
  4. A front-end affordance in the binding's page script to show the `unknown` changes
     and offer "read back and finish", plus, only for an operator, "it was made" or "it
     was not made".
  5. Tests against OOM's fake transport for each verdict: found made, found not made,
     no evidence refused, and each assumed.
- **Decisions for the release manager first:** who may assume an outcome (a visitor,
  never?); whether a page may resume at all or only the manager's Odoo page may; and how
  long a run stays resumable (OOM's `Runs->refuse_closed`).
