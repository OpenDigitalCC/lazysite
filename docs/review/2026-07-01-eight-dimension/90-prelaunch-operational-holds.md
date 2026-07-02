---
title: "Pre-launch operational holds - lazysite eight-dimension review"
subtitle: "Operational items deliberately HELD from the current dev cycle; to be addressed before formal launch"
brand: plain
---

## Status

Decision of 2026-07-02: the eight-dimension review's actions are split into
application (dev) work, proceeding now, and the operational items below, which
are **held** and will be addressed together before formal launch. Nothing here
is forgotten; each item names its review dimension and what it needs.

## The holds

1. **SLO / RTO / RPO / error-budget declaration** (D5 - the current refusal).
   Held because the declared values must reflect real hosting commitments made
   at launch, not placeholder numbers. Starting values proposed in
   `dimension-5-reliability.md` (99.9 per cent page-serve monthly, manager API
   99.5 per cent / p99 under 2 s, RTO 4 h, RPO 24 h content / 0 code). Needs: a
   launch-time hosting decision by the operator. Effort S once decided.

2. **Scheduled content snapshots across sites** (D5). Cron per site invoking
   the existing `action_backup_create` path, deployed on the Hestia hosts.
   The in-application restore half (SM084) is dev work and proceeds now; this
   hold is the scheduling + fleet deployment. Needs: operator cron deployment.
   Effort S per site once the restore lands.

3. **Log rotation on live hosts** (D5). A logrotate snippet for
   `lazysite/logs/` (the audit reader is already rotation-aware, so config
   only) deployed across the fleet. Removes a slow disk-full vector on hosts
   that have actually hit ENOSPC. Needs: operator deploy. Effort S.

4. **Monitoring and alerting** (D5, D7). `docs/MONITORS.md` registering the
   monitors that already exist (stats error surface, `lazysite-check.pl`,
   audit review) with cadence; `lazysite-check.pl` under cron with failure
   notification over the existing XMPP channel; an external uptime probe per
   site. Needs: operator choice of probe service + cron deploy. Effort S-M.

5. **Dependency vigilance tooling** (D6). A debsecan-based CVE check keyed
   off the `debian_pkg` fields in `dist/config/sbom-deps.json`, run at
   release and periodically; gitleaks host-wide with a one-off full-history
   sweep, then kept in the release path. Needs: operator installs the
   `debsecan` and `gitleaks` packages (no sudo available to the agent).
   Wrapper scripts are dev work once the packages exist. Effort S each.

6. **Pentest gate + first engagement** (D6 - half of the current refusal).
   Declare the gate block (shape given in `dimension-6-security.md`:
   annual cadence, significant-change triggers, CREST-CRT/OSCP third party,
   remediation SLAs) and commission the first external test. Note that
   SM070/071/072 were each unfired significant-change triggers. Needs:
   operator budget/engagement decision. Effort S to declare, L to execute.

7. **Support-period commitment** (D8). Decide the supported period (framework
   default five years) and record it in `docs/POLICY.md` and `SECURITY.md`,
   replacing the rolling-latest wording the CRA does not accept. Needs: a
   business decision. Effort S once decided.

8. **Launch compliance artefact set** (D8). Release signing (Sigstore/cosign
   with a key-management decision, `.sig` beside tarballs, verify note in
   `UPGRADE.md`); Declaration of Conformity template populated for the first
   stable release (legal review before external use); per-release VEX
   (`vex.json` beside `sbom.json`); Annex VII technical-file index (gated on
   the threat model, which is dev work proceeding now); OpenChain 5230/18974
   policy transcriptions; CE-readiness checklist against 11 December 2027.
   Needs: operator key + legal decisions. Effort S-L per item, per the
   schedule in `dimension-8-policy.md`.

## Trigger

Revisit this list as a block when formal launch planning starts. Items 5 can
be unblocked earlier at zero risk by installing the two packages; item 1 can
be drafted early and confirmed at launch.
