---
id: SM947
title: "SM947: Landing keeps the branch's SHAs, so refs need no stamping pass"
subtitle: "98 of 529 commits since 2026-09-01 (18%) are stamping, pre-cut or post-release bookkeeping."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-07
raised-by: release manager, from the development-cost analysis on WORK-PLAN-0153 (2026-10-07)
area: release
status-note: "Filed 2026-10-07 at the release manager's direction, from the development-cost analysis. Size M. Planned in WORK-PLAN-0153 group E."
---

# Measured

vcs-review lands by rebase, which gives every commit a new SHA, so any ref written on a branch is wrong after landing: `(PENDING)` placeholders, a stamping commit per release (37 since 2026-09-01), and lint 199's torn-entry artefact. A branch handed off is almost always already on main's tip, where a fast-forward would keep the SHAs.

# Proposal

vcs-review fast-forwards when the branch is on main's tip and rebases only when it must; or, after a rebase, rewrites `(PENDING)` refs to the landed SHAs itself. Either removes the stamping round-trip. Needs the toolchain (vcs-review is a toolchain tool); brief filed to its inbox.

# Done when

A branch on main's tip lands with its SHAs unchanged; a changelog entry can name its commit at write time.
