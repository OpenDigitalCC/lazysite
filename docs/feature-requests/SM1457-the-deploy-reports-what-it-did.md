---
id: SM1457
title: "SM1457: the deploy reports what it did, and a test holds it to that"
subtitle: "The 0.17.1 quiet rollout printed about a hundred lines of findings for 32 clean updates, most of them each site's standing content warnings. A deploy reports what it changed, what failed and what needs a human; the rest is one line and a file. A line budget in a test keeps it so."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-16
raised-by: "the release manager, on the 0.17.1 deploy ('the deploy is very verbose again')"
area: tools
status-note: "OPEN. Target 0.17.x edge. Tools only (tools/lazysite-cli.pl rollout's quiet report); no engine change. The third time: SM701 (0.11.9), SM889 (2026-09-15)."
---

# What happened

The 0.17.1 rollout updated 32 sites with 0 failed. Its quiet report (no `--verbose`) printed the
summary table, five summary lines, and then about a hundred lines under "findings": 45 distinct
messages, one per line with its sites. Most were each site's own standing `lazysite check`
warnings, the same before and after the upgrade and none caused or fixable by the deploy: pages
with no description or title, shared titles, data tables naming no domain, `| html` on `db:`
values, an account called "manager", the `trusted_proxies` reminder on 31 sites, a shadowed
`/docs` manual, undeclared `sites/` roots, no app icons.

The lines the release manager acts on after a deploy were a handful among them:

- opendigital.info: the upgrade could not read or move under a root-owned private store (six
  messages, one cause: run the upgrade as root).
- three sites: a private-store directory owned by www-data could not be read (one cause).
- darts4all.co.uk and opendigital.info: the site root did not answer.
- oca-odoo.com: the last content-history commit failed.
- the probe: 19 clean, 0 exposed, 13 could not run - eleven of them the cache-residue verdict the
  rollout misreads (SM1453).

SM701 made the rollout a table where it was a transcript; SM889 restored that after checks added
since had ignored it. Both fixed the output and left nothing that measures it, so each new check
that reports through the rollout grows the quiet report again.

# The requests

R1 - the quiet findings are the deploy's
: The quiet report's findings list only what the deploy did or could not do: a failure, a
  repair that needs a human, a probe that found an exposure or could not run (with SM1453's
  verdict read right), a site that did not answer, a step refused for permissions (once per
  cause, with the command that fixes it), and a check result that CHANGED from the site's last
  rollout. A site's standing check warnings are one summary line, "N standing check warnings on
  M sites - unchanged since the last rollout; full list: FILE", the file the report already
  writes.

R2 - one cause, one finding
: Messages with one cause are one finding: the six opendigital.info lines (one unreadable
  root-owned directory, read by six walks, and the probe that could not move into it) are one
  line naming the directory, the owner and "run the upgrade as root". The `trusted_proxies`
  reminder, true of every site that has not probed it, is one line with a count.

R3 - a test holds the budget
: A test runs the quiet report on a fixture fleet of 32 sites carrying the standing warnings
  above and two real faults, and fails when the report after the summary table exceeds a fixed
  budget (to settle: 15 lines), or when either fault is missing from it. A new check that
  reports through the rollout either fits the budget or goes to the file.

# To settle when built

- What "changed since the last rollout" compares against: the findings file of the previous run
  per site, or the check's own last record.
- Whether `--verbose` keeps today's full findings (it should: the verbose report is the
  transcript, and nothing is lost).
