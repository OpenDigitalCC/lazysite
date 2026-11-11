---
id: SM1436
title: "SM1436: the compliance records cover 0.16.11"
subtitle: "The gate's compliance check refuses 0.16.11 with OBLIGATIONS.md and TECHNICAL-FILE.md at 0.16.10. Both are walked against the 0.16.11 line, the beta, and stamped 0.16.11; the two new register entries await the release manager."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-11
raised-by: "the compliance check, which refuses a release whose records are behind its version (SM1306 to SM1429); release manager, ruling 236 (2026-11-11)"
area: release
status-note: "SHIPPED (PENDING) on n813. OBLIGATIONS.md and TECHNICAL-FILE.md at 0.16.11, channel beta (ruling 236); SM1435's entry and the walk's entry (SM1430, SM1435's wording) drafted, no trigger, for the release manager's confirmation; one STRIDE row; trust boundary 11 restated; UPGRADE.md's one 0.16.11 section. Docs only."
---

# What was asked

The release gate runs the compliance check with the 0.16.11 release material written in.
With OBLIGATIONS.md `reviewed_at_version` and TECHNICAL-FILE.md `covers_version` at 0.16.10
it refuses, as the 0.16.2 to 0.16.10 gates did. The walk reads each record against what
0.16.11 changes: the CHANGELOG's `## Unreleased` section and `git log bc1d27efd..17c1edb13`,
14 commits (SM1430 on n811, SM1435 on n812 and SM1437 on n814, stacked). Ruling 236 (2026-11-11) makes 0.16.11
the beta: cut with `--beta` from 0.16.10 plus those two, the code the 0.17.0 stable is
promoted from (rulings 227, 228), with the feature freeze starting at the cut.

# What it carries

- docs/SECURITY.md, a new entry dated 2026-11-11 for SM1435: address profiles are chosen from
  those that exist (rulings 234, 235). A deny rule naming a missing profile excluded nobody,
  silently; a rule, a group's address limit or a page naming one is now refused at every door
  (the manager API's `acl-set`, MCP `set_permissions`, `lazysite acl set`, the Groups page and
  the users tool's `group-settings-set`, the manager save, the control API, MCP `write_file`,
  `create_page` and `preview_page`, WebDAV), and a profile a rule names cannot be deleted
  (no force). A hardening, no ADR 0007 trigger, drafted for the release manager.
- docs/SECURITY.md, an entry for SM1430, SM1437 and SM1435's remaining item (the Groups page
  wording), no trigger, for the release manager. The signed-in marker is display only and
  carries no authority, so SM1430 is in the walk entry and has none of its own; the server
  reads the marker only to clear it. One STRIDE row, for a rule naming a missing profile;
  trust boundary 11 restated with the same sentence.
- docs/compliance/OBLIGATIONS.md, stamped 0.16.11: the register, threat-model, SBOM,
  fired-trigger and vulnerability-handling rows; one operate-side row (correct a rule, limit
  or page naming a missing profile); the "what a person must confirm" section for 0.16.11,
  with what a beta needs. docs/compliance/TECHNICAL-FILE.md, stamped 0.16.11: the risk
  assessment current to 0.16.11, 1,808 test files. docs/POLICY.md: walked to 0.16.11.
- docs/architecture/security.md: a 0.16.11 section.
- UPGRADE.md: the 0.16.11 notes are one section in 0.16.10's shape, the beta stated first,
  then what to do, then "Smaller changes, nothing to do".

# The beta

- 0.16.11 is the beta (ruling 236), not security-critical: no change in it fixes a known
  vulnerability. The channel changes nothing in the compliance check beyond the edge cut:
  the same two version stamps block, and the Declaration of Conformity, the restore
  rehearsal and the bench baseline stay advisory below stable and certified. The details are
  in OBLIGATIONS.md's walked section.
- It is the release the stable promotion is drawn from, and the feature freeze starts at the
  cut (ruling 228).

# Tests

None. The records are docs. The gates are the lint dir, the precheck and the compliance check
run with `--channel beta`.

# Not covered

SM1435's own filing (SM1435-two-small-findings-from-the-01610-edge-run.md) still says, under
"Not covered", that a page's front matter `addresses:` is not refused on save. Ruling 235
and the n812 commits supersede that; the filing is n812's.
