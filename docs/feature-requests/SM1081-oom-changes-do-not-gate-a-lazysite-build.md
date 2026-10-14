---
id: SM1081
title: "SM1081: OOM's changes do not gate a lazysite build"
subtitle: "The release gate failed three times on 2026-10-13 and 14 for changes in OOM's working tree and in the OOM a host happened to have. The Odoo extension's tests now run on a pinned snapshot of OOM inside the repository, and a compatibility tier looks at the host's OOM without ever failing anything."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-14
raised-by: the release gate (lint 207, three failures), ruled by the release manager 2026-10-14
area: odoo
status-note: "SHIPPED (PENDING): t/vendor/oom pins OOM 0.09 (commit 2edc3db) under a MANIFEST (lint 261); every Odoo test runs on it; lint 207 compares SM747's spec with it; lint 262 keeps the gate off OOM's tree and the host; tools/vendor-oom.sh adopts a newer OOM; tools/ext-compat.sh is the advisory tier."
---

# The ruling

The release manager, 2026-10-14:

> "we do need to separate the oom work from lazysite, as it isn't intended that oom
> changes will prevent a lazysite build. maybe oom is just a deb dependency, but we need
> some separation, otherwise we will never get a build. certainly we can't be testing
> against odoo to run a lazysite, it's just an extension, not core."

# What happened

`t/lint/207` compared the mapper specification filed into SM747 with OOM's working tree.
OOM's developers edit that tree all day. The lint failed the release gate on 2026-10-13
(the tree moved at 13:37, then at 17:35 and 17:44) and again at 21:04 after the freeze,
although nothing was wrong in lazysite. Separately, the Odoo tests loaded whichever OOM
the host had, so `t/unit/odoo/04` and `05` failed on main when OOM's tree moved past the
version they had assumed, and every apply failed when OOM added its approval gate. A first
attempt, to compare with the installed deb's copy instead, tied the gate to host state, and
the deb was about to change: it was rejected before it landed.

# What is built

| Piece | What | Where |
| --- | --- | --- |
| The snapshot | OOM 0.09, commit `2edc3db`: its library (byte-identical to the deb's, checked), its test doubles, its behaviours and profiles, its mapper specification (sha256 `8231bb2f...`), its licence notice. About 1.1 MB, 101 files | `t/vendor/oom/` |
| Held to its hashes | a MANIFEST names the source (commit, date, subject, deb) and a sha256 per file; nothing may be added, missing or changed without it | `t/vendor/oom/MANIFEST`, `t/lint/261` |
| The tests run on it | `OdooTest::oom_lib` defaults to the snapshot's library and its test doubles to the snapshot's `t/lib`. `LAZYSITE_OOM_LIB` and `LAZYSITE_OOM_TEST_LIB` remain, for the compatibility tier only | `t/lib/OdooTest.pm`, `t/lib/OdooInject.pm`; `t/tools/154` shows every Odoo module a test loads comes from the snapshot, even with a poisoned OOM first on `PERL5LIB` |
| The filing's copy | `t/lint/207` compares SM747's filed spec with the vendored one. The snapshot is always there, so the "source not readable" skip is gone | `t/lint/207` |
| Nothing reaches past it | no file under `t/`, `lib/` or `tools/` names OOM's tree or the deb's directories, except the two tools below | `t/lint/262` |
| Adopting a newer OOM | one command refreshes the snapshot from a commit (and checks a deb was built from it), rewrites the MANIFEST and prints what the SM747 filing must now say; the commit that does it updates the filing too, and lint 207 enforces both | `tools/vendor-oom.sh`, `t/tools/155`, `docs/DEVELOPER.md` |
| The compatibility tier | the Odoo tests against the INSTALLED deb and against OOM's tree, one line per target. Advisory: it always exits 0, never touches the gate, and a failure files one inbox note | `tools/ext-compat.sh`; `tools/overnight.sh` calls it once after the nightly suite and discards its result |
| Live Odoo | never in any automatic run; `tmp/live/odoo-live.pl` is manual, read-only unless `--writes` and the config says `test_database: yes` | `docs/DEVELOPER.md` |

# Packaging

The lazysite Debian packages do not depend on OOM at all: `debian/control` names
`libodoo-oom-perl` in no `Depends`, `Recommends` or `Suggests`. The dependency is the Odoo
extension's own declaration (`owns.deps`, OOM 0.03 or newer), checked when the extension is
enabled, so a host without OOM installs and runs lazysite and refuses only the extension,
by name.

# Not done

- The snapshot is 0.09. OOM's tree is already ahead of it (0.10: `session_groups` and the
  no-session fault). Adopting it is `tools/vendor-oom.sh` and a re-filing of SM747, when the
  release manager decides.
- The advisory tier's inbox note is one short line; it does not open a filing.
