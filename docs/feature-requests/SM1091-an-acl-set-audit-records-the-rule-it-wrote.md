---
id: SM1091
title: "SM1091: an acl-set audit row records the rule it wrote"
subtitle: "The after-state is the stored rule, the list form spells its paths as the single form does, and carries the read-without-write warning."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: edge-testing agent, 2026-10-16
area: audit
status-note: "SHIPPED on n602: Manager::Files dispatch_acl_set and _acl_set_many, Manager::AuditTrail _audit_implicit_target; t/unit/manager/344."
---

# What happened

From the 0.15.5 edge test plan results, row F7:

> DEFECT: every acl-set audit row records the after-state as "no restriction"
> though the rule restricts read - single and list form alike, e.g. "read: @g;
> owner: claude-code -> no restriction". Minor: the refused list attempt is
> audited with target ""; single form audits "/path", list form "path"; the
> list form drops the read-without-write warning.

SM465 wrote the after-state from the REQUEST. The request's lists arrive as an
array or as a string ("@g", "a, b"); the formatter reads arrays only, so a
string-sent list recorded as "no restriction". An owner kept from the old rule
was missing from the after-state too.

# What shipped

- The after-state, in both forms, is the rule `action_acl_set` stored (its
  `acl`), so it is what enforcement reads, owner included.
- A list form's rows target `/path` as the single form does, not `path`.
- A refused list attempt is audited with the paths it asked about (the first
  five, and the count of the rest), not an empty target.
- The list form's result carries the `warnings` its writes earned, once each,
  among them READ IS RESTRICTED AND WRITE IS NOT.

t/unit/manager/344.
