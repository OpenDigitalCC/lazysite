---
title: "SM543: a recount uses the loaded ruleset"
subtitle: "A recount with apply reclassifies under the built-in rules, ignores classifiers.json, and reports its own misclassification as a repair."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-25 by the plugins structural review, PROVEN by probe tmp/plugins-probe-stats-recount-rules.pl; class: correctness; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. The recount block is dispatched at stats.pl 638 and re-enters export_stats(30) at 2586 before _compile_rules() runs at 604, so --recount --apply reclassifies under the BUILT-IN rules and ignores classifiers.json, reporting changed=1 for the damage it did. The probe shows the day file at version=test-1 human=0 bot=1 after --export, then ok=1 applied=1 changed=1 and a day file at version=built-in human=1 bot=0 after --recount --apply. The fix compiles the rules before the recount is dispatched."
---

# The finding

`--recount --apply` reclassifies under the built-in rules and ignores
`classifiers.json`: the recount block is dispatched at `plugins/stats.pl
638` and re-enters `export_stats(30)` (`plugins/stats.pl 2586`) before
`_compile_rules()` runs at `plugins/stats.pl 604`. It reports
`changed=1`, counting its own misclassification as a repair. The probe
output shows the day file at `version=test-1 human=0 bot=1` after
`--export`, then `ok=1 applied=1 changed=1` with the day file at
`version=built-in human=1 bot=0` after `--recount --apply`.

# Why it matters

Correctness: the operator's repair tool undoes the classification the
operator configured, and its report says the opposite. A recount run to
fix history rewrites it wrongly and marks the rewrite as a success.

# The proving test

NEW `t/unit/plugins/31-a-recount-uses-the-loaded-ruleset.t` with
`is($day->{classifier_version}, 'test-1')`;
`11-classifiers-are-loadable-data` 'the output names the ruleset' pins
the export path only.

# Fix shape

Run `_compile_rules()` before the recount dispatch at 638 so the recount
re-enters `export_stats` with the loaded ruleset in place.
