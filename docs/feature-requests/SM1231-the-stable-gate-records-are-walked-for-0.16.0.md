---
id: SM1231
title: "SM1231: the stable gate's records are walked for 0.16.0"
subtitle: "The threat model, the significant-change register, OBLIGATIONS.md and TECHNICAL-FILE.md are brought to the code of 0.15.15 (which is 0.16.0's), the register entries are confirmed by the release manager, and the Declaration of Conformity is an unsigned draft."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "the release manager's stable-gate plan rulings, 2026-10-20 (tmp/rulings-2026-10-20.md, \"Stable gate (218) and coverage (337)\"), and the sign-off of 2026-10-21 (\"Stable 0.16.0 sign-off\")"
area: release
status-note: "SHIPPED (PENDING) on n720: docs only. Threat model, register entries (confirmed 2026-10-21), OBLIGATIONS.md and TECHNICAL-FILE.md at 0.16.0, an unsigned declaration draft, SIGNOFF signoff_required yes. Signed releases and the vulnerability register stay for the certified release."
---

# What was asked

The release manager's ruling of 2026-10-20 ("Stable gate (218) and coverage (337)"):
the threat model, the significant-change register, the obligations and technical
file, and the declaration draft start now on a docs-only branch; signed releases
and the vulnerability register "stay for certified release" and are recorded open
for the certified cut.

The sign-off of 2026-10-21 ("Stable 0.16.0 sign-off"): the eight drafted register
entries for 0.16.0's code are confirmed and accepted; SM1219 and SM1118 ("Confirm
now") are accepted now and stay held for 0.16.1; the 0.15.3-0.15.7 gate-tightening
fixes fired no trigger, and 0.15.16 carries no code change. The developer agent
stamps the records, sets the sign-off flag and records the confirmations dated
2026-10-21; the declaration stays unsigned until certified.

# What it carries

- The threat model (docs/architecture/security.md, docs/SECURITY.md) takes in the
  trust changes since 0.11.
- The significant-change register in docs/SECURITY.md: the entries for 0.16.0's code
  and their confirmation by the release manager on 2026-10-21 (still drafted by the
  developer agent); SM747 as accepted on 2026-10-20; SM1219 and SM1118 accepted and
  held for 0.16.1; a 2026-10-21 entry that no trigger fired for the gate-tightening
  fixes and 0.15.16.
- docs/compliance/OBLIGATIONS.md and TECHNICAL-FILE.md, walked row by row against
  the code and stamped 0.16.0 with their content_sha; the restore rehearsal, the
  declaration's signature at certified and the bench re-capture stay listed as what
  a person must still do.
- The Declaration of Conformity as an unsigned draft for 0.16.0, saying so at its
  top.
- docs/compliance/SIGNOFF.md: signoff_required yes.

# What it does not carry

Signed releases and the vulnerability register (the certified release), and any
signature of the declaration. Docs only; nothing in the code changes.
