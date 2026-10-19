---
id: SM1202
title: "SM1202: the gate holds that OOM's behaviours and profiles come from the snapshot"
subtitle: "OOM searches the deb's data directory after its own tree and offers no way to remove it; a test now holds that the host's copy can never be the one that answers."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-19
raised-by: "SM1185's report (behaviours and profiles still searched under the host's odoo-oom); coordinator, 2026-10-19"
area: odoo
status-note: "SHIPPED on n672 (third commit): t/unit/odoo/78. OOM cannot be told to leave the host directory out, so the test holds that it never answers; the gate cannot exclude it."
---

# What happened

SM1185 found the suite reading the host's installed packs and fixed it with
`ODOO_OOM_PACK_DIRS`. The same fault is possible for OOM's behaviours and
profiles (SM1081: the gate never reads OOM from the host; t/lint/262).

# What is true in OOM

`Odoo::Ops::Behaviour->core_dirs` and `Odoo::Ops::Profile->core_dirs` search
`$ENV{ODOO_OOM_BEHAVIOURS}` / `ODOO_OOM_PROFILES` (a root ADDED in front), the
`behaviours/` / `profiles/` beside `lib/` (the snapshot's own), and then the
hard-coded host directory when it exists. There is no variable or setting that
removes it, so it cannot be poisoned or excluded from lazysite's tests; setting
the variables to the snapshot would change nothing, as the snapshot is already
searched first. `Odoo::Ops::Matrix` has the same shape and its `matrix.yaml` is
not in the snapshot, but lazysite loads no Matrix.

# What shipped

`t/unit/odoo/78`, in a fresh perl on the snapshot's library: the snapshot's tree
is first in both searches; every model and pack the host's directory holds is
also in the snapshot, so the host root never answers (a newer deb on the host
fails the test and says to re-vendor); the pack directories are the ones
`OdooTest` set. Lint 262 already forbids a test from naming the host directory,
and OOM's own fallback is invisible to a text scan, so it is not extended.
Open for OOM: a variable that drops the host root (to be asked of the OOM agent).
