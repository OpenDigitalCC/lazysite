---
id: SM1239
title: "SM1239: NOT SERVICEABLE is the verdict of the check after the repair"
subtitle: "The 0.16.0 rollout said sumaya.fund and opendigital.cc were NOT SERVICEABLE, and in the same run that the repair found 32 sites clean. The rollout's verdict is now the last check's: a site whose repair passes is updated, and one whose repair does not is still NOT SERVICEABLE."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: "the release manager, following up the 0.16.0 stable rollout"
area: installers
status-note: "SHIPPED (0.16.1) on n724: settle_after_repair in the updater's repair loop; the lists print after it. t/tools/239."
---

# What happened

The 0.16.0 rollout reported sumaya.fund and opendigital.cc NOT SERVICEABLE, and the
same run's summary said `repair: 32 clean, 0 need a human`. A later
`lazysite-cli.pl repair --domain` on each found 0 failures.

# Where the verdict came from

Not from install.pl's exit 4. Since SM1205 the deploy carries on past install.pl's 4
(the permission pass, then its root `check --fix`), and exit 5 comes only from that
final check: `perl $DOM/tools/lazysite-check.pl --docroot ... --fix` exiting non-zero.
That check runs straight after the install, the permission pass and the worker
restarts. The updater's repair runs later, on every in-scope site, with the stage's
copy of the check. Two sites failed the first check and passed the second. The
summary kept the first verdict.

The code does not say why those two sites failed the deploy's check. The deploy's
whole output is printed in the quiet report on a failure, so the failing lines were
in that run's report.

# What shipped

- In the repair loop, a site whose repair exits 0 and whose deploy said NOT
  SERVICEABLE becomes `updated (repaired)`. It is counted as updated, taken off the
  NOT SERVICEABLE list, and gets a finding: the deploy's final check named a failure
  (its output is above) and the repair after it left none.
- A site whose repair does not pass stays NOT SERVICEABLE, and the rollout exits 2.
- The SKIPPED / FAILED / NOT SERVICEABLE lists print after the repair, so they say
  what the summary says.
- A failed install is not touched: a clean repair does not make it updated.
