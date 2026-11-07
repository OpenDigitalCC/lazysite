---
id: SM1394
title: "SM1394: the compliance records cover 0.16.7"
subtitle: "The gate's compliance check refuses 0.16.7 with OBLIGATIONS.md and TECHNICAL-FILE.md at 0.16.6. Both are walked against the 0.16.7 stack and stamped 0.16.7; the seven register entries the branches wrote are walked against the code, and one entry, a restated boundary and four STRIDE rows are drafted."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "the compliance check run alone for 0.16.7 (tmp/n767-compliance-check.sh): two blocking findings, as the 0.16.2 to 0.16.6 gates had (SM1306, SM1337, SM1367, SM1368, SM1380)"
area: release
status-note: "SHIPPED (0.16.7) on n767. OBLIGATIONS.md and TECHNICAL-FILE.md at 0.16.7; seven entries walked (SM1383 confirmed, ruling 146; six drafts); SM1385/SM1389/SM1391 entry, boundary 12 restated and four STRIDE rows drafted; four operate-side rows; UPGRADE.md's 0.16.7 section; no code changes."
---

# What was asked

Run alone, as the gate runs it on a fresh clone with the 0.16.7 release material
written in, the compliance check refused:

    FAIL obligations register: reviewed_at_version is 0.16.6, cutting 0.16.7 - walk docs/compliance/OBLIGATIONS.md and update it
    FAIL technical file: covers_version is 0.16.6, cutting 0.16.7 - walk docs/compliance/TECHNICAL-FILE.md and update it

Those two rows are the check's only blocking findings below certified. The walk reads
each record against what 0.16.7 changes: `git log 7028b983c..58d5d6e26`, 19 commits on
four branches (SM1369 X7 part one, SM1381, SM1382-SM1384, SM1390, SM1391,
SM1385-SM1389, SM1393 and SM1392).

# What it carries

- docs/SECURITY.md, the seven entries written on their branches (SM1369 X7 part one,
  SM1381, SM1383, SM1390, SM1387, SM1393, SM1392), walked against the code on the tip,
  each with a "walked" note. SM1383 fires new-external-interface in a narrow form and is
  confirmed contained (ruling 146); SM1381 fires it (the renewal step, a tokenless GET on
  the Odoo endpoint) and is its assessment, a draft; the other five fire none, drafts.
  The "drafted ... for confirmation" wording stays: the release manager confirms after
  the walk's report, and a follow-up commit records the rulings.
- docs/SECURITY.md, a new entry dated 2026-11-07 for SM1385, SM1389 and SM1391 (a theme
  deleted by its path; the check's walk past the history repository; a schedule entry
  under the floor), no trigger, drafted at the walk.
- docs/SECURITY.md, trust boundary 12 restated (Odoo's modules in the extension's
  payload lib; the renewal step), the assets line restated (a session cookie as a format
  an outside process may verify) and four STRIDE rows (an Odoo module found in the wrong
  place; the renewal step reached with no token; one key signing three payloads; a group
  deleted while something names it), drafts.
- docs/compliance/OBLIGATIONS.md, stamped 0.16.7: the register, threat-model, SBOM
  (strict, exit 0, 463 components, the one more being `lib/Lazysite/Auth/GroupRefs.pm`;
  Odoo's fifteen modules renamed, counted as before; sbom-deps.json unchanged) and
  technical-file rows; the fired-trigger and vulnerability-handling rows (0.16.7 edge,
  not security-critical; SM1390 a hardening by ruling 147); four new operate-side rows
  (an edited old Odoo module copy; an account named `v1`; a schedule entry under the
  floor; an outside process holding the key) and the SM1371 row restated for SM1393 and
  SM1392; the "what a person must confirm" section for 0.16.7.
- docs/compliance/TECHNICAL-FILE.md, stamped 0.16.7: the risk assessment current to
  0.16.7, 0.16.7 edge and not security-critical, 463 SBOM components, 1,663 test files.
- docs/POLICY.md: the technical file is walked to 0.16.7.
- docs/architecture/security.md: a 0.16.7 section (the payload lib and the renewal
  step, the cookie contract and the three verifier rules, group deletion and the
  reference walk, the roles on a pre-mark site, a form's conf in the editor and over
  MCP, the smaller changes).
- UPGRADE.md: the four branches' Unreleased (0.16.7) notes as one section in the
  0.16.6 section's shape, what to do first (an edited old Odoo copy; the renewal path
  and `auth_redirect`; a group's deletion; an account named `v1`; a schedule entry under
  the floor; what appears on an older site; a form's conf; the check line that goes
  away) and then what needs nothing, each point checked against the code.

Sections with nothing to change: the Declaration of Conformity (unsigned, 0.16.0),
signed releases, OpenChain, the bench baseline, the restore rehearsal, CE marking and
the support period. The hooks proposal's "X7, part one" section says what shipped.

# Found at the walk

- No register entry was missing for a change that moves a control. SM1385 widens where
  a destructive action reaches (a theme under any layout, with the same refusals) and
  SM1389 narrows what a check reports (the history repository alone), so both are in the
  walk's entry with SM1391; SM1382 and SM1384 are a recipe and a filing, SM1386 a warning,
  SM1388 a sentence.
- SM1387's entry leaves ADR 0007's new-external-interface "to be weighed". The walk
  reads a new action on an existing authenticated door, under the existing gate, as no
  new interface, as the actions of SM1332-SM1334 and SM1240 were recorded; the release
  manager says which, and the entry's assessment holds either way.
- SM1390 against the vulnerability-handling row: the preview cookie that verified as a
  session for an account named `v1` is minted only for a signed-in manager, no site is
  known to hold such an account, and a holder of the key can mint at will, so it is a
  hardening, as ruling 147 named it: 0.16.7 stays edge and not security-critical.
- The SBOM strict check's note that six OOM entries in sbom-deps.json have no `use` in
  code predates the move (the 0.16.6 walk's log carries the same six) and is not a
  finding of X7.

# Tests

None: docs only. The compliance check run alone on the branch
(tmp/n767-compliance-check.sh): with the records at 0.16.6 it refuses on the two rows
above, and passes with them at 0.16.7. The SBOM strict check on the same stage exits 0
with 463 components; sbom-deps.json is unchanged in the range.
