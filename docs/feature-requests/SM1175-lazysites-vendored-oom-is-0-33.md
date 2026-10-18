---
id: SM1175
title: "SM1175: lazysite's vendored OOM is 0.33, with oomd's front door"
subtitle: "The pinned OOM snapshot moves from 0.32 to 0.33 and now carries bin/oomd, so the tests of SM1164 start the real daemon from the repository, never from the host."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-18
raised-by: "OOM agent, inbox 2026-10-18-oom-0.33-core-has-groups.md; release manager, 2026-10-18 (wave 2)"
area: odoo
status-note: "SHIPPED on n657 (first commit): t/vendor/oom is OOM 4bca049 (Package 0.33) by tools/vendor-oom.sh with both debs; the script now also takes bin/oomd. SM747's spec is re-filed (lint 207)."
---

# What happened

OOM 0.33 is built; it adds `core.has_groups` (L3's question "has this
person group X?", asked as the person). The release manager asked for the
snapshot to move to it in the same commit that gives the snapshot oomd's
executable, because SM1164's tests run the real daemon and SM1081 (lint 262)
forbids a test reading OOM from the host.

# What shipped

- **`t/vendor/oom` is OOM 4bca049, "Package 0.33"**, taken with
  `tools/vendor-oom.sh --deb libodoo-oom-perl_0.33_all.deb --deb
  odoo-oom-tools_0.33_all.deb 4bca049`. The script checked the library and
  the spec against the library deb, and `Odoo/Accounts.pm`, `Odoo/Tools/` and
  `bin/oomd` against the tools deb.
- **`bin/oomd` is vendored**, the only file taken from OOM's `bin/`, mode
  0755, held to its hash by the MANIFEST (lint 261). Its first lines are
  `use lib "$FindBin::RealBin/../lib"`, which resolves to
  `t/vendor/oom/lib`, so the vendored library comes first on `@INC`.
  `t/tools/155` covers the new file.
- **SM747's filed spec is re-filed** (the changed rows, the provenance and the
  sha256), lint 207. This filing was chosen over a note in SM1167 because the
  provenance table now names two adoptions on one day.
- **`core.has_groups`** is in the snapshot; nothing in lazysite calls it yet
  (L3 waits for it, SM1160).
