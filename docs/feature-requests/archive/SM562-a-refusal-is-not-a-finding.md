---
title: "SM562: a refusal is a refusal, a finding is a finding"
subtitle: "lazysite-cli.pl labels every non-zero child exit with findings, so a check that could not check at all is reported as a site finding and the fleet exits 2."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): run_tool_per_site in lazysite-cli.pl carries a child's exit 2 into its own 'could not check' bucket - the summary reads 'N ok, N with findings, N could not check.' with a 'could not check:' line beside 'findings on:' - and the worst-status exit is unchanged. Proving test t/tools/63-a-refusal-is-not-a-finding.t registers a checkable site and a bare docroot, runs check --all, and requires the bare one under 'could not check' and never under 'findings on'; it was labelled a finding before the fix. FOUND 2026-08-25 by the tools structural review, PROVEN by probe tmp/probe-cli-findings-label/result.txt; class: operability; recommended timing: later. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. run_tool_per_site in tools/lazysite-cli.pl (360) labels any non-zero child exit 'with findings'. lazysite-check.pl exits 1 for FAIL and 2 for could-not-check, so a site with no engine tree is summarised as a finding: the child says 'no engine tree for ... Is this a lazysite docroot?' and the fleet summary reads '0 ok, 2 with findings. findings on: good.example, plain.example'. The finding-versus-failure split lives today only in the shell layer, installers/hestia/lazysite-hestia-update-all.sh, pinned by t/tools/42-rollout."
---

# The finding

`run_tool_per_site` (`lazysite-cli.pl 360`) labels every non-zero
child exit `with findings`. `lazysite-check.pl` distinguishes exit 1
(FAIL) from exit 2 (could not check), so a check that refuses to run is
reported as a site finding. The probe's child says `no engine tree for
... Is this a lazysite docroot?` and the summary reads `0 ok, 2 with
findings. findings on: good.example, plain.example`. The fleet exits 2
on that basis. Review row TOM-7 lists the exit contracts across the
five tools; the shell layer (`installers/hestia/lazysite-hestia-update-all.sh`,
pinned by `t/tools/42-rollout`) already keeps the split.

# Why it matters

Operability: a fleet operator reading 'findings on: good.example' goes
looking for a content or configuration problem on a site whose real
state is that the tool could not look at it, and a fleet-wide tooling
fault reads as a run of site defects.

# The proving test

NEW `t/tools/63-a-refusal-is-not-a-finding.t`: rc 2 from the child
yields 'could not check', not 'findings' (`t/tools/42-rollout` pins
this contract for the shell layer only).

# Fix shape

Carry the child's rc 2 through as a distinct 'could not check' bucket in
the per-site summary, mirroring the split the Hestia rollout script
already makes.
