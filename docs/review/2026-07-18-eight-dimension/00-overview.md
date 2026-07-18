---
title: "Eight-dimension non-functional review - lazysite - aggregated overview"
subtitle: "0.8.0-stable candidate (0.7.28 tree, 6780878), 2026-07-18, Commercial regime - four independent assessors, eight reports"
brand: plain
standard-margins: true
---

## What this is

The third full eight-dimension non-functional review of lazysite, run against
the framework in `/srv/projects/toolchain-development/TOOLCHAIN.md` (the eight
dimensions in signoff order, per-dimension refusal conditions keyed to the
declared regime). lazysite declares the **Commercial** regime in
`docs/POLICY.md`. Four independent assessors each covered two dimensions and
wrote a standalone report in this directory; each verified the 2026-07-10
review's findings as fixed or open rather than assuming, cited file:line and
command evidence, and assessed the work shipped since the 0.7.0 stable cut
(SM110/151 multi-site, SM155 delegation, SM165 domain access, SM175 content
history, SM179 multilingual P1-P8, the cache-correctness fixes, the
alias-entity retirement).

This review is the gate for the planned **0.8.0 stable** cut.

## Verdicts (as assessed) and resolution in this cut

```datatable
columns: # | Dimension | Assessed | Prior | Resolution in-cut
widths: 0.8cm | 3.4cm | 1.6cm | 1.4cm | X
bold: 3
tone: medium
text: 5
---
1 | Correctness and groundedness | PASS | WARN | The six :utf8 fail-open readers are :raw with a regression test; new work grounded and fails closed
2 | Code quality | PASS | PASS | perlcritic sev-3 clean across ~12,800 new lines; lint gates grew 6 -> 12 (shellcheck, retired-terms)
3 | Test coverage | PASS | WARN | mcp/oauth now IN the coverage gate (fail-closed on unmeasured); new SM179/SM165 modules branch-tested
4 | Performance | PASS | PASS | All ops within tolerance; conf-mtime cache = one stat/request; i18n/lang paths off the hot path
5 | Reliability and resilience | PASS | REFUSE | RELIABILITY.md declares SLO/error-budget/RTO(4h)/RPO, each mapped to a passing failure-mode test + restore rehearsals
6 | Security | REFUSE -> cleared | REFUSE | F6.10 stored-XSS via front-matter lang FIXED + test; F6.11 domain-add CRLF FIXED; F6.2 change register written
7 | Documentation | WARN -> cleared | WARN | FEATURES.md timeline swept to 0.7.28 (the D7 stable-gate item); multilingual/config docs current
8 | Policy compliance | WARN | WARN | Prior refusals (DoC, support period, SBOM licence) all cleared; DoC stamped 0.8.0 - signature is the operator action at the cut
```

## Overall

The assessors refused at the audited tree on **D6 (security)** for one serious,
reproducible defect - a stored-XSS / header-injection path through a page's
front-matter `lang:` (F6.10), reachable by a content-only partner - plus a stale
significant-change register (F6.2). Both, and the WARN-level `domain-add` CRLF
gap (F6.11), were **fixed within this cut** (see `01-resolution.md`), with
regression tests. The two documentation/policy stable-gate items (FEATURES.md
currency, the DoC 0.8.0 stamp) were also cleared here; the DoC's physical
signature and place/date remain the responsible person's action at the cut.

The texture continues 2026-07-10's trajectory: every prior refusal (D5 SLOs,
D6 pentest gate, D7 doc rot, D8 DoC/SBOM licence) is verified cleared, and the
one new refusal was a code defect the review existed to catch - now closed. With
the in-cut fixes applied and the gate re-run green, a Commercial signoff clears
on all eight dimensions bar the operator's DoC signature.
