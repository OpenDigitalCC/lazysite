---
id: SM946
title: "SM946: Prose caps for status notes, changelog entries and commit messages; older changelog sections archived"
subtitle: "Average status-note 2.8 KB on one line, changelog entry 2.2 KB, commit message 3.4 KB; CHANGELOG.md is 1 MB."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-07
raised-by: release manager, from the development-cost analysis on WORK-PLAN-0153 (2026-10-07)
area: docs
status-note: "Filed 2026-10-07 at the release manager's direction, from the development-cost analysis. Size S. Planned in WORK-PLAN-0153 group E."
---

# Measured

Measured 2026-10-07: filing status-notes average 2,804 bytes on a single line; 0.15.2's 35 changelog entries are 77 KB (2.2 KB each); the last 60 commit messages average 3,428 bytes. CHANGELOG.md is 15,619 lines and 1 MB, which the lints parse and edits navigate.

# Proposal

Status-note at most ~400 characters (the detail goes in the filing body); a changelog entry at most ~8 lines (the detail in the commit message); a commit message about 1.5 KB. Released sections older than the current minor move to `docs/releases/CHANGELOG-<minor>.md`, with the lints that read the changelog taught to read the archive.

# Done when

Lint 09 caps status-note length; the working CHANGELOG holds the current minor only; nothing that a lint checks is lost.
