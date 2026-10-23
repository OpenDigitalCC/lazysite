---
id: SM1269
title: "SM1269: the compliance records cover 0.16.1"
subtitle: "The 0.16.1 edge gate refused on OBLIGATIONS.md and TECHNICAL-FILE.md, both at 0.16.0. Both are walked against the 0.16.1 batch and stamped 0.16.1; the threat model and the significant-change register take in the batch's changes, as drafts for the release manager to confirm."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "the 0.16.1 edge gate (tools/gate-main.sh --version 0.16.1, tmp/release-gate/0.16.1/gate-main.log): two blocking compliance findings"
area: release
status-note: "SHIPPED (0.16.1) on n730: docs only. OBLIGATIONS.md reviewed_at_version and TECHNICAL-FILE.md covers_version 0.16.1; five register entries dated 2026-10-23, drafts; threat model boundary 14 and two STRIDE rows; architecture/security.md and POLICY.md follow. content_sha is left for the release manager to stamp at sign-off."
---

# What was asked

The 0.16.1 edge gate's compliance check refused:

    FAIL obligations register: reviewed_at_version is 0.16.0, cutting 0.16.1 - walk docs/compliance/OBLIGATIONS.md and update it
    FAIL technical file: covers_version is 0.16.0, cutting 0.16.1 - walk docs/compliance/TECHNICAL-FILE.md and update it

A walk reads each record against what changed between 0.16.0 (3ada57d74) and main
(658d08b2d): the CHANGELOG's `## Unreleased` section and `git log 3ada57d74..main`.

# What it carries

- docs/compliance/OBLIGATIONS.md, walked row by row and stamped 0.16.1: the register,
  threat model, SBOM (455 components, strict, on the 0.16.1 tree) and technical-file rows
  anchored on 0.16.1; the restore rehearsal row names the 0.16.0 stable as the last stable
  cut; an operate-side row for SM1219 (the people who sign in are told the visitor log
  records their account); the list of what a person must confirm, for 0.16.1.
- docs/compliance/TECHNICAL-FILE.md, walked row by row and stamped 0.16.1: the Docker
  Compose package as a product form, the risk assessment current to 0.16.1, OOM 0.42's
  place in the SBOM (the Debian package declared; the vendored snapshot for the tests),
  1,550 test files, and SM1226's threat table among the review records.
- The significant-change register in docs/SECURITY.md: five entries dated 2026-10-23,
  each a developer-agent draft for the release manager to confirm - the warm-forked Odoo
  endpoint (SM1226, a new local interface), a page's stem rule on move and delete
  (SM1257, SM1242, SM1258), the Odoo extension's options and OOM 0.42, the Docker Compose
  package (SM1233), and the access, rollout and channel changes with no trigger. The
  SM1219/SM1118 entry records that both landed in 0.16.1.
- The threat model: trust boundary 14 (the warm-fork parent), two STRIDE rows, and in
  docs/architecture/security.md the warm-forked endpoint, the Odoo idempotency, sizes and
  downloads, the stem rule, MCP remove_permissions, bundle adoption, Permissions-Policy,
  the rate counter and the Docker package; the "Held for 0.16.1" section is now the
  0.16.1 section.
- docs/POLICY.md: the declaration and technical-file rows say 0.16.0 and 0.16.1.

# What it does not carry

The Declaration of Conformity (stamped 0.16.0, unsigned) and the restore rehearsal:
both are blocking only at a certified cut and are left as they are. `content_sha` in
both records is left for the release manager to stamp at sign-off, as at the 0.16.0
walk, so the gate reports the content as changed. Docs only; nothing in the code
changes.
