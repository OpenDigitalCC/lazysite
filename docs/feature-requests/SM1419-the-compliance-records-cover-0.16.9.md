---
id: SM1419
title: "SM1419: the compliance records cover 0.16.9"
subtitle: "The gate's compliance check refuses 0.16.9 with OBLIGATIONS.md and TECHNICAL-FILE.md at 0.16.8. Both are walked against the 0.16.9 stack and stamped 0.16.9; the sixteen register entries the branches wrote are confirmed (ruling 225), and so are the walk's own entry, a restated boundary, the assets line and nine STRIDE rows (ruling 226)."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-10
raised-by: "the compliance check, which refuses a release whose records are behind its version (SM1306 to SM1415); release manager, ruling 225 (2026-11-10)"
area: release
status-note: "SHIPPED (0.16.9) on n796. OBLIGATIONS.md and TECHNICAL-FILE.md at 0.16.9; sixteen entries confirmed (ruling 225; seven fire, contained); the walk's entry (SM1418 and five more), boundary 15, the assets line and nine STRIDE rows confirmed (ruling 226); five operate-side rows; UPGRADE.md's 0.16.9 section; no code changes."
---

# What was asked

The release gate runs the compliance check with the 0.16.9 release material written in.
With OBLIGATIONS.md `reviewed_at_version` and TECHNICAL-FILE.md `covers_version` at
0.16.8 it refuses, as the 0.16.2 to 0.16.8 gates did. The walk reads each record against
what 0.16.9 changes: the CHANGELOG's `## Unreleased` section and `git log
8a2806723..63e8f1970`, 102 commits (SM1369 X4 to X7; SM1351; SM1352; SM1363; SM1364;
SM297; SM1357; SM1361; SM1416; SM1417; SM1418; T-112 to T-115; the n795 restack). The
release manager's ruling 225 (2026-11-10) confirms the register entries and names the
walk's closing list.

# What it carries

- docs/SECURITY.md, the sixteen entries written on their branches (SM1369 X4, X5, X6;
  SM1364; SM1351; SM297; CryptX; SM1352 passkeys; SM1363 web push and webhook; SM1363
  phone number; SM1357; SM1416; both SM1417 entries; SM1361/X7; T-115): each assessment
  line and verdict says it was confirmed by the release manager on 2026-11-10 (ruling
  225). Seven fire a trigger, each contained: X4, SM1351, passkeys, CryptX, web push and
  webhook, the phone number, SM1364 (ruling 190, as it stood). X6 records that the
  `/manager/` path is within the existing manager surface. The other nine fire none. No
  early third-party review: SM1351's and SM1352's verdicts say the OIDC grant mapping
  (ruling 186's first use) and the passkey paths are named in the scope of the
  engagement ADR 0007 already requires. The "(0.16.9, PENDING)" marks on the headings
  stay, as the 0.16.8 walk left its headings.
- docs/SECURITY.md, a new entry dated 2026-11-10 for SM1418, SM1407 (T-112), SM1404
  (T-113), SM1398 (T-114), the container's tooling and the restack's wording, no
  trigger, naming the rest of 0.16.9 and why each moves no control.
- docs/SECURITY.md, trust boundary 15 restated (the callers X4 to X7 added), the assets
  line, the "not yet code" line (OIDC is code) and nine STRIDE rows (an extension's
  identity provider; an outside OIDC provider's answer; its group claim reaching a
  capability group; a passkey sign-in; a web-push endpoint; the phone number; an
  identity written into the data endpoint's environment; code in a site's extensions
  directory on the shared engine; a sourced table's writes), confirmed (ruling 226).
- docs/compliance/OBLIGATIONS.md, stamped 0.16.9: the register, threat-model, SBOM
  (strict, exit 0, 495 components, the nineteen more listed; sbom-deps.json gains four
  entries), first-penetration-test (the scope), fired-trigger and vulnerability-handling
  rows; five new operate-side rows (a store the engine now refuses on; a provider's
  group map; passkeys, web push, the webhook route and phone numbers; a table's source;
  a shared container's sites); the "what a person must confirm" section for 0.16.9.
- docs/compliance/TECHNICAL-FILE.md, stamped 0.16.9: the risk assessment current to
  0.16.9, 495 SBOM components, 1,777 test files, the scope of the engagement.
  docs/POLICY.md: walked to 0.16.9.
- docs/architecture/security.md: a 0.16.9 section, with the cited functions and
  constants checked against the code.
- UPGRADE.md: the 0.16.9 notes as one section in 0.16.8's shape, what to do first and
  then "Smaller changes, nothing to do" (SM1407, SM1398, and new notes for SM1404 and the
  title check, SM1357); the two overlapping T-115 notes are one.
- CHANGELOG: the SM1419 entry; the SM1417, SM1352 and SM1363 entries say their register
  entries are confirmed; a stray half line (`SM1024 (PENDING) **A broken access store ...
  never worked`) before the SM1417 entry is removed.

# Found at the walk

- Ruling 226: 0.16.9 is edge, not security-critical (it fixes no known vulnerability;
  SM1417 and T-115 are hardenings).
- The SM1417 entry for items 1-8 said the Odoo sign-in refuses on a broken limiter "with
  its own 'rate' wording, left for the Odoo slice". Rulings 212, 223 and 226 changed
  that: the Odoo sign-in and the OIDC start answer cannot-tell, 503, in the limiter's own
  `fault_refusal` words (t/unit/odoo/260, t/unit/extensions/200). The entry now says so,
  and the walk's entry carries no note about it.
- The SM1369 filing's status-note was not updated: the 0.16.8 walk updated no filing's
  note but its own.

# Tests

None: docs only.
