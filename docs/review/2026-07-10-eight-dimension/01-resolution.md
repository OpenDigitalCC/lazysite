---
title: "Eight-dimension review - resolution record"
subtitle: "v0.6.10 findings resolved for the 0.7.0 stable cut, 2026-07-10"
brand: plain
---

# What this is

The same-day resolution cycle for the 2026-07-10 review: each refusing
dimension's "path back" executed and re-verified, plus the WARN-level
refusal residue. Work landed as three batches; every commit cites the
dimension it clears. The gates were re-run on the final tree (full suite,
bench, and the full coverage gate at the new floors).

# Refusals cleared

```datatable
columns: Dim | Refusal basis | Resolution | Evidence
widths: 0.9cm | 3.6cm | X | 4.2cm
bold: 1
tone: medium
text: 3
---
D5 | No SLO/RTO/RPO/error budget | docs/RELIABILITY.md declares the reference targets (99.9% page-serve, RTO 4 h, RPO 24 h content / 0 code), error budgets + policy, per-implementation ownership, and maps every target to passing failure-mode tests. The first timed full-system disaster rehearsal ran at this cut: shipped-tarball install, full backup, docroot destroyed, --restore-full --domain onto a new docroot - content/auth/conf intact, mechanical restore ~1 s. | cf0e4d0 + rehearsal commit; docs/RELIABILITY.md
D6 | Pentest gate absent; triggers unassessed | ADR 0007 carries the framework-shaped pentest declaration with a dated deferral waiver (expiry: first engagement or 2026-12-31); the significant-change register in docs/SECURITY.md records dated assessments for SM070-072/128/136/137/140. Technical residue fixed: auth readers :raw (fail-open closed, red-green tested), notify-xmpp.conf 0660 + check probe, SM140 visitor-key salt. | bdb4c86, cf0e4d0; docs/adr/0007, docs/SECURITY.md
D7 | SM138 rot in security-tier docs; FEATURES.md stale; systemic cause unaddressed | Sweep executed across root SECURITY.md, architecture/security.md, the Hestia runbook, DEVELOPER.md and the starter docs; FEATURES.md brought current to 0.6.10. The systemic cause now has a mechanical answer: t/lint/08-retired-terms.t fails the build on any retired term taught as current (found 22 lines on creation; green after the sweep). Man pages generated and shipped by the release flow. | 7393d6c; t/lint/08-retired-terms.t
D8 | DoC + support period absent; SBOM licence wrong | Support period declared (five years from 0.7.0, security fixes on the stable channel; POLICY.md + SECURITY.md aligned). docs/DECLARATION-OF-CONFORMITY.md populated for signature at this cut (draft status until signed; legal review before external use). SBOM product licence corrected to MIT. | bdb4c86, cf0e4d0; docs/POLICY.md, docs/DECLARATION-OF-CONFORMITY.md
```

# WARN residue addressed

```datatable
columns: Dim | Finding | Resolution
widths: 0.9cm | 5cm | X
bold: 1
tone: medium
text: 3
---
D1 | Six :utf8 user-settings readers fail auth gates OPEN on non-ASCII | Re-paired to :raw; t/unit/auth/11-non-ascii-settings.t verified red on the unfixed tree, green after
D1/D2 | Vacuous secrets-lint private-key check; no gate self-tests | git grep -e + a planted-fixture self-test per pattern; shellcheck -S error is now a lint gate; release.sh refuses when gate tooling is absent
D3 | mcp/oauth outside the gate; oauth below branch floor; silent skip on unmeasured | oauth branch coverage 79.0/58.9 -> 99.3/94.6 (51 behavioural assertions); eight CGIs gated; floors ratcheted to 75/62 (three documented per-file overrides at the previous floor of 60, none weaker than before); an unmeasured CGI now fails the gate
```

# Deliberately not done at this cut (tracked)

- The actual third-party pentest engagement (waived per ADR 0007, expiry
  recorded).
- docs/MONITORS.md and the dev-server operational exemplar (D5 "worth
  doing"; backlog).
- Release signing, VEX, OpenChain conformance, the Annex VII technical
  file (D8 open items beyond the two unconditional ones; backlog).
- Bench breadth ops and the 0.6.6 install.pl ownership-repair test (D3/D4
  recommendations; backlog).
- The DoC signature itself - a human act at the cut; the document is
  draft-status until the responsible person signs.

# Verdict for the 0.7.0 cut

With the above landed and the gates green on the final tree, no
per-dimension refusal condition of the 2026-07-10 review remains
structurally unmet for the Commercial regime as the reports' own "path
back" sections define it - D5/D6/D7/D8 move to WARN-or-better pending the
next full review, and 0.7.0 ships as the first stable-channel release.
