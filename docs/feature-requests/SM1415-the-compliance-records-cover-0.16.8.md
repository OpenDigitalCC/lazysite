---
id: SM1415
title: "SM1415: the compliance records cover 0.16.8"
subtitle: "The gate's compliance check refuses 0.16.8 with OBLIGATIONS.md and TECHNICAL-FILE.md at 0.16.7. Both are walked against the 0.16.8 stack and stamped 0.16.8; the thirteen register entries the branches wrote are confirmed (ruling 177), and one entry, a restated boundary and three STRIDE rows are drafted."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-08
raised-by: "the compliance check run alone for 0.16.8 (tmp/n777-compliance-check.sh): two blocking findings, as the 0.16.2 to 0.16.7 gates had (SM1306, SM1337, SM1367, SM1368, SM1380, SM1394); release manager, rulings 177-180"
area: release
status-note: "SHIPPED (0.16.8) on n777. OBLIGATIONS.md and TECHNICAL-FILE.md at 0.16.8; thirteen entries confirmed (ruling 177; SM1414, SM1355, SM1396 fire, contained); rulings 178-180 folded in; the walk's entry (SM1400 and five more), boundary 15, the assets line and three STRIDE rows confirmed (ruling 182); four operate-side rows; UPGRADE.md's 0.16.8 section; no code changes."
---

# What was asked

Run alone, as the gate runs it on a fresh clone with the 0.16.8 release material
written in, the compliance check refused:

    FAIL obligations register: reviewed_at_version is 0.16.7, cutting 0.16.8 - walk docs/compliance/OBLIGATIONS.md and update it
    FAIL technical file: covers_version is 0.16.7, cutting 0.16.8 - walk docs/compliance/TECHNICAL-FILE.md and update it

Those two rows are the check's only blocking findings below certified. The walk reads
each record against what 0.16.8 changes: the CHANGELOG's `## Unreleased` section and
`git log 130e04b6c..d092a5b8c`, 63 commits in two waves (SM1369 X2, X3 and X5's asset
part; SM1395-SM1402, SM1404, SM1405, SM1412, SM1413, with SM1403 and SM1406 withdrawn;
SM1354-SM1357; SM1407-SM1411; SM1414; the n776 restack). The release manager's rulings
177-180 (2026-11-08) were given before the walk, so the walk records them.

# What it carries

- docs/SECURITY.md, the thirteen entries written on their branches (SM1369 X2, X3 and
  X5's asset part, SM1396, SM1395, SM1413, SM1412, SM1354, SM1355, SM1356, SM1357,
  SM1407, SM1414): each assessment line and verdict says it was confirmed by the
  release manager on 2026-11-08 (ruling 177). SM1414 fires new-external-interface, as
  drafted. SM1355 (rows' earlier values in the row history, 90 days, rulings 170, 175)
  and SM1396 (the offline kit keeps a person's data in their browser) are recorded as
  firing new-processing-of-restricted-data - ADR 0007's name for the trigger ruling 177
  calls new processing of personal data - each threat delta and verdict rewritten:
  SM1355 contained by the daily `row-history-prune` job with the write path's prune,
  SM1396 by the purge at sign-out keyed to the login. The other ten fire none; X2
  exercises the trigger X1 recorded (ruling 134). SM1355, SM1396 and X3 gain a
  "walked" note against the code on the tip. The "(0.16.8, PENDING)" marks on four
  headings stay, as the 0.16.7 walk left its headings.
- Folded in: ruling 178 (the Odoo handler type stays on `manage_connectors` until X4,
  C-14) in the X2 and X3 entries; ruling 179 (the schedule-exceptions sweep's removals
  are audited, not in the row history, not undoable) in SM1356's residual risk; ruling
  180 (the schedule wizard ships as an example in `/docs/data-tables`, a `date` step,
  opens and closes optional) in the SM1355 and SM1356 entries.
- docs/SECURITY.md, a new entry dated 2026-11-08 for SM1400, SM1402, SM1404, SM1405,
  SM1409 and SM1411 (a backup snapshot is not a layout; a conf for no form refused; a
  listing's pickers; a notice mail's shape; a mixed pair not mirrored; the editor's
  lock), no trigger, written at the walk and confirmed (ruling 182), naming the rest of 0.16.8 and why each moves
  no control: SM1397, SM1398, SM1399, SM1401, SM1408, SM1410, the withdrawn SM1403 and
  SM1406, n776's test fix-ups, and this walk.
- docs/SECURITY.md, trust boundary 15 restated (the loader's three callers from
  0.16.8), the assets line restated (rows' earlier values; the kit's browser storage)
  and three STRIDE rows (the member content door; rows' earlier values kept; the kit's
  storage on a shared browser), confirmed (ruling 182); the STRIDE row X3 wrote is confirmed with its
  entry.
- docs/compliance/OBLIGATIONS.md, stamped 0.16.8: the register, threat-model, SBOM
  (strict, exit 0, 476 components, the thirteen more listed; sbom-deps.json unchanged)
  and technical-file rows; the fired-trigger and vulnerability-handling rows (0.16.8
  edge, not security-critical, ruling 182); four new operate-side rows (rows'
  earlier values and the kit's storage; every public page in the sitemap and
  `llms.txt`; `write_content` and `publish_copies`; a rule whose owner is no account)
  and the SM1362 row restated for SM1412 and SM1413; the "what a person must confirm"
  section for 0.16.8.
- docs/compliance/TECHNICAL-FILE.md, stamped 0.16.8: the risk assessment current to
  0.16.8, 476 SBOM components, 1,711 test files. docs/POLICY.md: walked to 0.16.8.
- docs/architecture/security.md: a 0.16.8 section.
- UPGRADE.md: the 0.16.8 notes as one section in the 0.16.7 section's shape, what to do
  first and then "Smaller changes, nothing to do", with notes for SM1400-SM1402,
  SM1404, SM1405, SM1408 and SM1409, which had none.
- CHANGELOG: the SM1415 entry; the X3, SM1395 and SM1414 entries say their register
  entries are confirmed.

# Found at the walk

- What ruling 177 calls the logout purge is the kit's wrapper of the Odoo helper's
  `signOut`: it empties the kept reads stored under the signing-out login's owner label
  and keeps that owner's queued changes, which are sent for that owner alone. A session
  ending another way (the site's own `/logout`, an expiry, a closed browser) leaves the
  kept reads under the label, shown to no other login. The entry, its walked note and
  its STRIDE row say so. Ruling 183 keeps the purge as built.
- SM1396's drafted verdict said the identity cookie's contents changed by one key;
  rulings 161 and 163 left it unchanged, as its "what changed" says. The confirmed
  verdict says unchanged.
- The `row-history-prune` job runs only where the daemon is enabled with a usable job
  account; elsewhere the write path's prune is the bound, as SM1355's residual risk
  says.
- No change that moves a control was without an entry: the six in the walk's entry move
  one a little (a listing, a refusal, a mail's content, a mirror, a lock).

# Tests

None: docs only. The compliance check run alone on the branch
(tmp/n777-compliance-check.sh): with the records at 0.16.7 it refuses on the two rows
above, and passes with them at 0.16.8. The SBOM strict check on the same stage exits 0
with 476 components; sbom-deps.json is unchanged in the range.
