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
status-note: "BUILT, not yet released (n842). Target 0.17.x edge. Tools only (the rollout's quiet report); no engine change. The third time: SM701 (0.11.9), SM889 (2026-09-15). t/tools/684 holds the budget; see Settled when built."
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

# Settled when built

- WHAT "CHANGED" COMPARES AGAINST: a per-site record the rollout writes and reads, the check
  findings it saw at that site's last rollout, one per line under a header
  (`# lazysite rollout record: ...`), in `.rollout-check-findings` beside `.install-state.json`
  in the site's engine tree (`lazysite_dir`: where install state lives, so no new location). It
  is written as the site's own user (`sudo -n -u`, never root: SM139), only for a site whose
  repair came back clean (its check was read in full), and replaced whole. Why a record and not
  the previous findings file: the findings file is a temporary file of the run and is removed;
  the full-list file is for people. Why not the check's own record: the check keeps none, and a
  new store in the engine for this would be an engine change.
- FIRST ROLLOUT, NO RECORD: every warning is standing, never new, and the line says how many
  sites had no record. A clean site is given a record with a header and no lines, so its first
  warning later is new. A record with no header is a damaged store (ruling 206): named with its
  path and the remedy (remove it; the next rollout starts a new baseline), and that site's
  check findings are all shown that time. Nothing guesses.
- HOW A DEPLOY FINDING IS TOLD FROM A STANDING ONE: by source, never prose. Findings are labelled
  where they are collected: the repair and probe phases print the check's lines; the deploy's
  transcript is install steps until the heading the deploy prints before its final check
  (`==> verifying install ...`, pinned by t/tools/684 against the deploy script), the check's
  after it. Two designated markers stay the deploy's whichever phase printed them: a check
  `[ FAIL ]` and `ROUTING CHECK SKIPPED` (the site root or an asset did not answer: the deploy
  could not verify the site), the second pinned against lazysite-check.pl. NOISE_RE is
  unchanged and t/tools/80 still pins that it does not match prose.
- R2: one cause is one line. A directory the upgrade could not read, named by the check's
  walks, the installer's address-profile walk and a move beneath it, is one line naming the
  directory, its owner (read from the directory) and `run the upgrade again as root or as
  OWNER`; the full-list file keeps every original line. The `trusted_proxies` reminder is a
  check warning, so it is counted in the standing line, one count for all 31 sites; when it is
  new it is the existing one grouped message with its sites, as any check finding.
- R3 is t/tools/684: 32 sites carrying the filing's standing warnings (323 distinct site and
  message pairs), the permission refusal (six messages, one cause) and the root that did not
  answer. It runs the rollout's own deploy loop, repair and probe phases, summary and verdict,
  extracted from the script, and fails when the report after the summary table is over 15 lines
  (13 now), when either fault is missing, or when the standing line is. It also runs the second
  and third rollout over the same fleet: a changed warning is reported alone, a fifth walk
  naming the same directory is still one line, a damaged record is named. Verified failing on
  the 0.17.1 script (118 lines after the table).
- `--verbose` keeps today's output: it prints every phase and neither reads nor writes the
  records, so a verbose rollout does not move the baseline.
