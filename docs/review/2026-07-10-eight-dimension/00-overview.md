---
title: "Eight-dimension non-functional review - lazysite - aggregated overview"
subtitle: "v0.6.10 (5aa6f27), 2026-07-10, Commercial regime - four independent assessors, eight reports"
brand: plain
---

## What this is

The second full eight-dimension non-functional review of lazysite, run against
the framework in `/srv/projects/toolchain-development/TOOLCHAIN.md` (the eight
dimensions in signoff order, per-dimension refusal conditions keyed to the
declared regime). lazysite declares the **Commercial** regime in
`docs/POLICY.md`. Four independent assessors each covered two dimensions and
wrote a standalone report in this directory; every mechanical gate was
executed for real at this tag (full suite 162 files / 2,504 tests, fresh
instrumented coverage run, benchmark gate, secrets + security lints, strict
SBOM gate, perlcritic at both bars). Each report verifies the 2026-07-01
review's findings as fixed or open rather than assuming, cites file:line and
command evidence, and ends with ranked, effort-sized recommendations.

This review is the gate for the planned **0.7.0 stable** cut: 0.7.0 does not
ship until the refusals below are cleared.

## Verdicts

```datatable
columns: # | Dimension | Verdict | Prior | One-line basis
widths: 0.8cm | 3.6cm | 1.9cm | 1.6cm | X
bold: 3
tone: medium
text: 5
---
1 | Correctness and groundedness | WARN | WARN | Gates green and wired; all sampled features grounded; but six `:utf8` readers in lazysite-auth.pl open account_disabled / token_expired / account_expired / mfa_enrolled FAIL-OPEN on any non-ASCII in user-settings.json (reproduced), and the secrets lint's private-key check is vacuous
2 | Code quality | PASS | WARN | Severity-3 perlcritic clean (31 documented deviations) and the tidy gate wired into release.sh; both prior gaps closed and mechanically enforced
3 | Test coverage | WARN | WARN | All prior machinery landed (60/60 floors, gate in release.sh, fresh run green); but lazysite-mcp.pl / lazysite-oauth.pl sit outside the gate (oauth 58.9 branch would FAIL today) and "not measured" is a silent skip
4 | Performance | PASS | WARN | All ops 0.96-1.09x of a provenance-carrying baseline at 2x tolerance, gate wired; the SM140 recorder's negligible-cost claim substantiated; residual is bench breadth only
5 | Reliability and resilience | REFUSE | REFUSE | No SLO / RTO / RPO / error-budget declaration anywhere, a third deferral - while the underlying failure-mode tests and restore machinery all shipped and pass
6 | Security | REFUSE | REFUSE | The STRIDE/ASVS threat model CLEARED (all five named entries); the pentest gate remains structurally absent and four significant-change triggers since 07-01 fired unassessed; notify-xmpp.conf perms + SM140 empty-secret visitor key flagged
7 | Documentation | REFUSE | WARN | SM138 retirement missed the security-tier docs (root SECURITY.md, architecture/security.md, hestia runbook still teach the retired key) and FEATURES.md stops at 0.6.1; the 07-01 systemic cause (no doc-currency release step) recurred in eight days
8 | Policy compliance | REFUSE | WARN | Declaration of Conformity and support-period statement still absent (unconditional Commercial items); NEW: the shipped SBOM misdeclares lazysite's own licence as Artistic-1.0-Perl (211/213 components) vs MIT
```

Overall: **a strict Commercial signoff refuses at v0.6.10** on D5, D6, D7 and
D8. The texture is very different from 2026-07-01, though: the prior review's
machinery asks are essentially all delivered and verified (compile/tidy/
coverage/bench gates wired and refusing, threat model written, ADRs, branch
floors, baseline provenance), two dimensions moved to PASS, and every refusal
has a short, concrete path back - the outstanding work is declarations,
documentation currency, and a handful of S-effort code fixes, not
architecture.

## What blocks 0.7.0 stable

1. **SLO/RTO/RPO + error budget** (D5) - write `docs/RELIABILITY.md`, map
   targets to the already-passing failure-mode tests, time one restore
   rehearsal. Effort S.
2. **Pentest gate declaration** (D6) - the `pentest:` block + a dated
   deferral waiver ADR with expiry, plus recorded significant-change
   assessments for SM070-072, SM128, SM136, SM137, SM140. Effort S.
3. **SM138 security-tier doc sweep** (D7) - root SECURITY.md,
   docs/architecture/security.md, installers/hestia/INSTALL-RUNBOOK.md,
   DEVELOPER.md residue. Effort S.
4. **FEATURES.md catch-up** for 0.6.2-0.6.10 (D7). Effort M.
5. **Support-period statement** (D8) - POLICY.md + SECURITY.md. Effort S.
6. **Declaration of Conformity** (D8) - populated for the 0.7.0 cut; 0.7.0
   must not ship without 5 and 6. Effort M.

## Refusal-level residue to fix alongside (correctness/security)

7. **auth.pl encoding fail-open** (D1, cross-flagged D6) - six `:utf8`
   readers of user-settings.json -> route through Lazysite::Auth::Settings or
   re-pair to `<:raw`; non-ASCII regression test. Effort S.
8. **notify-xmpp.conf permissions** (D6) - the XMPP password file sits
   outside every mode-checked directory; relocate or 0660 + a lazysite-check
   probe. Effort S.
9. **SBOM own-licence -> MIT** (D8) - manifest-to-sbom.pl. Effort S.
10. **SM140 empty-secret visitor key** (D6) - on auth-less sites `.secret`
    is absent and the daily HMAC degrades to IPv4-brute-forceable; mint a
    salt when no secret exists. Effort S.

## Gate-integrity actions (make the green trustworthy)

11. `coverage.sh --check`: a "not measured" CGI is a FAILURE, not a skip
    (D3). Effort S.
12. Gate lazysite-mcp.pl + lazysite-oauth.pl - oauth needs branch tests
    first; it is factually below the branch floor today (D3). Effort M.
13. Secrets lint: fix the vacuous private-key check (`git grep -e`) and add
    planted-fixture self-tests for every lint gate (D1/D2). Effort S.
14. shellcheck as a lint test; release.sh asserts its gate tooling exists
    instead of skipping silently (D2). Effort S.
15. Floors ratchet to 75 stmt / 62 branch once 12 lands, so the regime floor
    is the enforced floor (D3). Effort S.
16. Doc-currency mechanics (D7): a retired-terms lint (seeded with
    manager_groups), a doc-currency step in the release flow, and wire
    gen-manpages.pl into release.sh (the 0.5.40 claim is otherwise unmet).
    Effort S/M.

## Worth doing, not blocking

- ADR 0001 updated to enumerate both processor local copies (D1).
- A test pinning the 0.6.6 install.pl ownership repair (twice field-hit)
  (D3).
- Bench breadth: manager-API users-page op, DAV PROPFIND/PUT op, scan-heavy
  render variant (D4).
- Complexity-policy deliberate-keep ADR (D2).
- docs/MONITORS.md register + the promised dev-server operational exemplar
  (D5).
- Threat-model currency rows for the 0.6.x surface (D6).

## Sequencing to 0.7.0

Batch 1 (code, S-effort): items 7-11, 13, 14 - one review branch, full gates.
Batch 2 (declarations + docs): items 1-6, 16 - RELIABILITY.md, pentest ADR,
doc sweeps, support period, DoC.
Batch 3 (coverage scope): items 12 + 15.
Then: re-verify the four refusing dimensions against their reports' "path
back" sections, cut 0.7.0 as the first stable-channel release, and record it
in the DoC.
