---
id: SM1453
title: "SM1453: the rollout reads the probe's cache verdict as a verdict"
subtitle: "When the ACL probe finds only front-end cache residue, the rollout reports that the probe could not run, though it ran and answered."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-16
raised-by: "the 0.17.0 rollout, read by the developer"
area: tools
status-note: "BUILT, not yet released (n842). Target 0.17.x edge. Tools only; no engine change, no new exposure. The cache verdict counts with the verified (exit 0), said apart; t/tools/683 builds it from the check's text."
---

# What happened

The 0.17.0 rollout's summary read `probe: 19 clean, 0 exposed, 13 could not run`. On 11 of the 13
sites the probe had run and given its cache verdict (SM368, SM377):

> a file the engine refuses is still being served to anonymous visitors: .png, .pdf, .txt, .css,
> .gz served, .dat refused - but a file created AFTER the gate and never requested is refused, so
> this is a front-end cache still holding descriptors for files fetched while the folder was
> public, not a routing rule

The rollout listed each of those sites as `probe could not run: the check gave no probe verdict
(exit 0): N ok, M warning(s), 0 failure(s)`.

# Why

`cmd_acl_probe` in `tools/lazysite-cli.pl` matches two of the check's three probe verdicts: the
FAIL (`a file the engine refuses is served to anonymous visitors`) as exposed, and the OK
(`protected content is not reachable anonymously`) as verified. The cache WARN reads `is still
being served`, which matches neither, so the site falls to not confirmed, and
`_probe_unconfirmed_reason` (SM1237) finds no skip marker and says the check gave no verdict.

# What it costs

An operator reading the summary is told the probe could not run on a third of the fleet and goes
looking for a cause. The real answer was there: nothing reaches past the gate, and the files still
served are the probe's own, held by the front end's cache, which clears itself (SM331). The exit
code is 3 (not measured) where the probe measured.

# The requests

R1
: The rollout recognises the cache verdict as a third outcome, reported as such
  (`cache residue, clears itself`) and counted apart from verified, exposed and could not run.
  Exposure stays exit 1 only (SM912).

R2
: t/tools/41 pins the cache wording in both tools, as it does the other two, so the check's
  wording and the rollout's match move together.

# Settled when built

- The cache verdict counts toward exit 0, with the verified: the probe ran and nothing is exposed,
  and a fourth exit would give the fleet script, which reads the exit code only (SM912 P2), a
  status it has no column for. It is said apart in words: `lazysite probe` prints `cache residue,
  clears itself` per site and a line counting them, and the rollout's summary reads `N clean (K
  cache residue, clears itself)`. Exposure stays exit 1 only; not measured stays exit 3.
- R2 is t/tools/683, which builds the check's verdict from lazysite-check.pl's own source text
  rather than pinning a copy, so the check's wording and the CLI's match cannot drift.
