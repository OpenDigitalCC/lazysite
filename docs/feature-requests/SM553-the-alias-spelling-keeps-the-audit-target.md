---
title: "SM553: the alias spelling keeps the audit target"
subtitle: "theme-activate with theme=sky audits target / rather than sky, so the audit trail loses which theme or layout was activated."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): _audit_implicit_target gains a theme-activate|layout-activate branch reading the theme/layout parameter; t/unit/manager/56 runs the real dispatcher for both alias spellings and asserts the audit target is the name. FOUND 2026-08-25 by the manager-api structural review, PROVEN by probe tmp/mapi-probe-audit-target.t; class: operability; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. theme-activate&path=sky audits target sky; theme-activate&theme=sky and layout-activate&layout=grid (the SM261 alias spellings) audit target /. _audit_implicit_target in lazysite-manager-api.pl has no theme or layout branch, and the chain's alias resolution (1498, 1502) is local to the dispatch branch, so the audit block never sees the name. Fix from the report: a theme-activate|layout-activate branch in _audit_implicit_target reading the theme or layout parameter."
---

# The finding

`lazysite-manager-api.pl _audit_implicit_target` derives the audit target
per action and has no theme or layout branch. The probe shows
`theme-activate&path=sky` audits target `sky`, while
`theme-activate&theme=sky` and `layout-activate&layout=grid` - the SM261
alias spellings - audit target `/`. The chain's alias resolution
(`lazysite-manager-api.pl 1498, 1502`) is local to the dispatch branch,
so the audit block never sees the resolved name.

# Why it matters

Operability: the audit row for an activation is the record of what
changed. With the target reading `/`, an operator reading the log cannot
tell which theme or layout went live.

# The proving test

t/unit/manager/56-activate-accepts-the-obvious-parameter.t: the audit
line target is the name.

# Fix shape

A `theme-activate|layout-activate` branch in `_audit_implicit_target`
reading `$params->{theme}` / `$params->{layout}`.
