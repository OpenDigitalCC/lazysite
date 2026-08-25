---
title: "SM550: the theme-mirror check never runs"
subtitle: "SM315's standing check in lazysite-check.pl opens a file named layout instead of reading the layout key, so an unmirrored theme is never reported."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-25 by the tools structural review, PROVEN by probe tmp/probe-check-theme-mirror/result.txt; class: operability; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. report_theme_assets_mirrored in tools/lazysite-check.pl calls conf_value('layout') with one argument, but conf_value takes ($file, $key), so it opens a file named layout, gets undef and returns at 1788 before checking anything. A site with a misplaced theme.css, no assets/ and no mirror produces no theme line in the check report; t/unit/manager/77 covers activation time only, so nothing exercises the standing check."
---

# The finding

`report_theme_assets_mirrored` in `tools/lazysite-check.pl` calls
`conf_value('layout')` with one argument. `conf_value` is
`($file, $key)`, so the call opens a file named `layout`, receives
undef and returns at `lazysite-check.pl 1788`. The probe drives a site
with a misplaced theme.css, no `assets/` and no mirror: the report
carries no theme line at all. The harness shows `conf_value('layout')`
returning undef where `conf_value($conf, 'layout')` returns `foo`.

# Why it matters

Operability: SM315 added this check so an operator would learn that a
theme's assets are unmirrored before visitors do. Since the check exits
before looking, the report is silent on exactly the condition it was
written to surface, and `t/unit/manager/77` covers activation time only.

# The proving test

NEW `t/tools/62-check-reports-an-unmirrored-theme.t` - the probe as a
test, with one assertion: `like /no mirrored assets/`.

# Fix shape

Pass the conf file: `conf_value($conf, 'layout')`, then let the check
run to its report line.
