---
title: "Eight-dimension non-functional review - lazysite - aggregated overview"
subtitle: "v0.5.35 (de12238), 2026-07-01, Commercial regime - four independent assessors, eight reports"
brand: plain
---

## What this is

The full eight-dimension non-functional review of lazysite, run against the
updated framework in `/srv/projects/toolchain-development/TOOLCHAIN.md` (the
eight dimensions in signoff order, with per-dimension refusal conditions keyed
to the project's declared regime). lazysite declares the **Commercial** regime
in `docs/POLICY.md`. The review was run manually - the framework's `projkit
signoff` runner is not yet built - by four independent assessors, each covering
two dimensions and writing a standalone report in this directory:

- `dimension-1-correctness.md` and `dimension-2-code-quality.md`
- `dimension-3-test-coverage.md` and `dimension-4-performance.md`
- `dimension-5-reliability.md` and `dimension-6-security.md`
- `dimension-7-documentation.md` and `dimension-8-policy.md`

Every mechanical gate was executed for real at this tag (full suite, coverage
probe, benchmark gate, secrets lint, SBOM strict gate, perlcritic at both the
project and framework bars); findings cite command output and file:line
evidence. Each report ends with ranked, actionable recommendations.

## Verdicts

```datatable
columns: # | Dimension | Verdict | One-line basis
widths: 0.8cm | 4.2cm | 1.9cm | X
bold: 3
tone: medium
text: 4
---
1 | Correctness and groundedness | WARN | 36/36 files compile; features grounded; but a four-way divergent capability read (with a utf8/octets inconsistency), no compile gate, stale architecture docs
2 | Code quality | WARN | Project gate (severity 4) genuinely clean; framework bar is severity 3 (1,518 hits, 79 per cent one policy) and there is no perltidy gate
3 | Test coverage | WARN | Suite green (139 files, 2,003 tests); floor declared but the gate is not wired into release.sh, no branch threshold, evidence stale (pre-0.5.x)
4 | Performance | WARN | Bench gate passes in 5 s but is unwired; the render op silently measures the cache-hit path; baseline lacks provenance; 3x tolerance refuses only catastrophe
5 | Reliability and resilience | REFUSE | No SLO / RTO / RPO / error-budget declaration anywhere - non-waivable for a Commercial runnable service; content RPO unbounded (SM084 restore open)
6 | Security | REFUSE | All mechanical gates green when run; but no STRIDE/ASVS threat model and no pentest gate, with SM070/071/072 each an unfired significant-change trigger
7 | Documentation | WARN | Strong corpus, clean CHANGELOG; systemic SM095 currency rot (ten locations), and ADRs / threat model / MONITORS / ACCESSIBILITY / man pages absent
8 | Policy compliance | WARN | Claimed-met CRA obligations genuinely evidenced; but POLICY.md cites the wrong regulation number for the CRA and the support-period posture is self-contradictory
```

Overall: **a strict Commercial signoff would refuse today**, on Dimension 5
(no reliability targets declared) and Dimension 6 (no structured threat model,
no pentest gate). Everything else is WARN: real substance with specific,
mostly-small gaps between "green when run by hand" and "unskippable by design".

## What a strict signoff refuses today

1. **No SLO / RTO / RPO** (D5). One documentation section clears the refusal:
   declared availability targets, recovery objectives and an error budget. The
   underlying machinery already exists and passes its tests.
2. **No STRIDE/ASVS threat model** (D6). The 594-line security narrative is
   most of the raw material; it needs restructuring into the framework shape,
   starting from five named entries (forged X-Remote-* headers, hostile
   layout.tt as template-code execution, secrets under the docroot, partner
   write-boundary bypass, CGI denial-of-service).
3. **No pentest gate** (D6). A declaration block plus, eventually, a first
   third-party engagement.
4. **Refusal-pending** (D1): the undocumented four-way capability read - route
   two of the copies through the shared resolver and ADR-record the third, or
   the next signoff refuses on `divergent-implementation`.

## Aggregated actions, ranked

Deduplicated across the eight reports; each names the dimensions it clears.

### A. Clear the refusals (do first)

1. Declare SLO/RTO/RPO + error budget in `docs/POLICY.md` (or a linked
   `docs/RELIABILITY.md`). Starting values proposed in the D5 report (99.9
   per cent page-serve, RTO 4 h, RPO 24 h content / 0 code). Effort S. Clears
   the D5 refusal.
2. Author the STRIDE + ASVS L1 threat model in `docs/SECURITY.md`,
   restructuring `docs/architecture/security.md` and covering the five named
   entries. Effort M. Clears half the D6 refusal; feeds D7 and the D8
   technical file.
3. Declare the pentest gate (`project.yml` block per the D6 report) and plan
   the first engagement. Effort S to declare, L to execute. Clears the other
   half of the D6 refusal.
4. Resolve the four-way capability read: route `lazysite-auth.pl` and
   `Acl.pm` through `Lazysite::Auth::Settings`, ADR the processor's
   self-contained copy, settle utf8-vs-octets one way. Effort M. Clears the
   pending D1 refusal.

### B. Make the green gates unskippable (cheap, high leverage)

5. Wire into `tools/release.sh`: `coverage.sh --check`, `bench.pl --check`
   (5 s), and add `t/lint/04-compile.t` (perl -c sweep) plus
   `perlcritic --theme security` as lint gates. Effort S each. Converts four
   hand-run PASSes into by-design prevention (D1, D3, D4, D6).
6. Declare a branch floor (`branch_floor=60`) and re-measure coverage at the
   current tag, refreshing the recorded baseline. Effort S. (D3)
7. Fix the bench render op (split cache-hit vs render-miss, record host/date
   provenance in the baseline, then tighten tolerance per-op). Effort S. (D4)
8. De-flake `03-login-rate-limit.t` (window-rollover guard). Effort S. (D3)

### C. Correct the posture of record (small edits, outsized risk if wrong)

9. `docs/POLICY.md`: cite the CRA as Regulation (EU) 2024/2847 (currently
   the AI Act's number), update seven- to eight-dimension, un-misfile the
   threat model, and soften the Art. 13 "floors in place" claim to reference
   the live signoff state. Effort S. (D8)
10. Decide and record the support period (framework default five years),
    replacing SECURITY.md's rolling-latest wording. Effort S. (D8)
11. SM095 documentation currency sweep: ten stale locations across
    `docs/FEATURES.md`, `docs/IMPLEMENTOR.md`, `docs/DEVELOPER.md`,
    `docs/architecture/code-quality.md` and four starter docs (capability
    table from `@CAP_KEYS`, groups-only resolution, retired manager_groups
    field, removed raw log download). Effort M. (D1, D2, D7)

### D. Structural debt (schedule)

12. Create `docs/adr/` with the five retrospective ADRs (uncommitted-tree
    release contract; channel x action capability model; code/seed install
    classification + provenance stamp; edge/stable channels; raw-mode
    reserved for artifacts). Effort M. (D7; ADR 0002 also closes D1's
    divergence record.)
13. Bound the content RPO: SM084 restore + scheduled snapshots, with a
    round-trip test. Effort M. (D5)
14. Failure-mode tests: disk-full injection (this host has hit ENOSPC),
    concurrent DAV writers; ship a logrotate snippet. Effort M/S. (D5)
15. `docs/MONITORS.md` + minimal alerting (uptime probe + lazysite-check
    under cron). Effort S-M. (D5, D7)
16. Dependency vigilance: debsecan-based CVE check keyed off
    `sbom-deps.json` `debian_pkg` fields; gitleaks host-wide (both need an
    operator package install). Effort S each. (D6)
17. Release signing (Sigstore/cosign + .sig in dist/), DoC template, VEX
    per release, Annex VII technical-file index, OpenChain policy
    transcriptions, CE-readiness checklist. Effort S-L per the D8 report's
    schedule. (D8)
18. Code-quality trajectory: decide `RequireExtendedFormatting` (one
    decision removes 79 per cent of the severity-3 delta), burn down the
    mechanical remainder, add `.perltidyrc` + tidy gate, then raise the
    project gate to severity 3. Effort S+M+M. (D2)
19. Small removals: delete dead `_user_analytics`; give `payment-demo.pl` a
    minimal `--describe` or exclude it from discovery, recorded. Effort S.
    (D1, D2)

## Method and limitations

- Manual run of the framework (no `projkit`); four independent assessors on
  isolated dimension pairs, findings not shared between them before writing.
- Coverage was probed but not fully re-measured (4.6x instrumented slowdown
  put the full run past the review's time box); the coverage verdict rests on
  the declared floor, the gate's existence, and the 2026-06-24 recorded
  evidence, which predates the 0.5.x line - refreshing it is action 6.
- The benchmark gate ran on this host only; the baseline carries no host
  provenance (action 7).
- One infrastructure note: the first run of three assessors stalled on a
  transient harness fault and was relaunched; the D1/D2 reports are from the
  first run, the rest from the relaunch. All eight assessed the same pinned
  tree (v0.5.35, de12238).
