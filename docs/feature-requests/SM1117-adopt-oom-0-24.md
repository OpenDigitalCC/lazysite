---
id: SM1117
title: "SM1117: lazysite adopts OOM 0.24"
subtitle: "The pinned OOM snapshot moves from 0.09 to 0.24, and a two-factor Odoo account is refused by OOM's own category instead of by its message."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: release manager, 2026-10-17
area: odoo
status-note: "SHIPPED on n620: t/vendor/oom (OOM fc3b3bb, Package 0.24), lib/Lazysite/Odoo/Session.pm, SM747 re-filed spec; t/unit/odoo/25, 27."
---

# What happened

The release manager, 2026-10-17: "OOM - review currently installed version
.24 - its also on the lazysite host, is it ready to start to be used, whats
the gap? there are local odoo instances to test against."

The host has `libodoo-oom-perl` and `odoo-oom-tools` 0.24. lazysite's tests
ran on a pinned snapshot of OOM 0.09 (SM1081), and the advisory tier
(`tools/ext-compat.sh`) had reported every newer OOM as breaking lazysite's
Odoo tests since 0.11.

Measured against the installed 0.24, the gap was 2 of 236 tests in 34 files,
both one case: **a two-factor Odoo account was refused as an internal error
(500) instead of by name (403, `two-factor`).** lazysite told a two-factor
account apart by OOM's message ("authentication did not establish a
session"), behind a credential-fault test, and had asked OOM for a category.
OOM 0.24 answered it: "Odoo::Error gains is_no_session and the fault category
second_factor, set where Odoo::Transport::Session authenticate throws
'accepted, no session opened' (it was credential), so a consumer tells a
two-factor account from a wrong password without reading the message." No
longer a credential fault, it fell through to `internal`.

# What shipped

- `Lazysite::Odoo::Session::_classify` reads `is_no_session` or the
  `second_factor` category first, and keeps the message test for an OOM
  before 0.24. The plugin's dependency floor is unchanged.
- `t/vendor/oom` is OOM commit fc3b3bb ("Package 0.24"), the code the
  installed deb carries, by `tools/vendor-oom.sh` (205 files; t/lint/261's
  MANIFEST).
- SM747's filed copy of the mapper specification is re-filed from it:
  sections 7 to 10 and the spec's Open list, the recorded sha256, the
  provenance rows (t/lint/207).

The Odoo tests (t/unit/odoo, t/integration/170-174) pass on the new snapshot
and on the installed deb. t/unit/odoo/25 and 27 fail with the classification
before this change.

# What 0.24 makes possible (not built here)

- `core.whoami` reports the signed-in identity with its groups
  (`groups_readable`, `own_web_session`): the per-user group read SM747's
  per-user path was waiting on.
- HR modules, `core.import` ambiguity reporting, empty fields read as null on
  every surface, and the account, two-factor and API-key operations in
  `core.user`.

Each is for a ruling and a slice of SM747, explored first on a local rig.
