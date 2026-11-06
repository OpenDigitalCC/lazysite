---
id: SM1330
title: "SM1330: the compatibility tier tests the OOM it names"
subtitle: "tools/ext-compat.sh failed every night on both targets for reasons in lazysite's test harness, not in OOM: the host's packs, the snapshot's root and the snapshot's daemon reached into each run, and the failing files were never named. Each target now runs alone, and the line and the note say what failed."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-05
raised-by: "release manager, 0.16.5 batch (n745), from a read-only diagnosis of the nightly advisory notes (tmp/extcompat-diag/)"
area: odoo
status-note: "SHIPPED (0.16.5) on n745: OdooTest names no host packs in any mode and gives the tier's daemon tests the target's oomd (LAZYSITE_OOMD); tools/ext-compat.sh passes each target its oomd and data root and names the failing files; t/unit/odoo/78 compares the first data root with the target's. t/tools/154. The snapshot is not changed (OOM 0.44 awaits the release manager)."
---

# What happened

The advisory compatibility tier (SM1081) runs the Odoo tests against the
installed deb (0.42) and OOM's tree (0.44). It failed every night on both, and
the inbox notes said only `prove exit 1`. A read-only diagnosis
(`tmp/extcompat-diag/`) found four faults, all in lazysite's harness:

1. **The host's packs.** `t/lib/OdooTest.pm` pointed `ODOO_OOM_PACK_DIRS` at no
   packs (SM1185) and `ODOO_OOM_SHARE` at no share root (SM1216) *unless*
   `LAZYSITE_OOM_LIB` was set, so under the tier OOM's registry read
   `odoo-oom-packs`, whose `shop` pack claimed `shop.basket` beside the suite's
   `LazysiteTest::OdooOps::Basket` ("operation 'shop.basket' claimed by both").
   52 files failed on each target: the fault SM1185 fixed for the gate.
2. **t/unit/odoo/78** asserted the first behaviours and profiles root is
   `t/vendor/oom` in every mode (line 65; its later checks were guarded).
3. **The daemon.** `t/lib/OdooDaemonTest.pm` started `t/vendor/oom/bin/oomd`
   whatever the target. bin/oomd begins `use lib "$FindBin::RealBin/../lib"`,
   ahead of `PERL5LIB`, so under the tree target the daemon ran the snapshot's
   0.42 (t/unit/odoo/62: got 0.42, expected 0.44).
4. **The file names.** `tools/ext-compat.sh` matched `^ *t/.*\(Wstat`, but prove
   names each file by the absolute path it was given (`$ROOT/t/...`), so no
   failing file was ever named in the FAIL line or the note.

# What shipped

- **Each target runs alone: its library, its test doubles, its daemon, its
  data, and the suite's own operations.**
  - Packs: `OdooTest` names no packs in every mode now; the exception for
    `LAZYSITE_OOM_LIB` is gone. Chosen over `ext-compat.sh` exporting a
    non-existent directory because the suite's test operations are the only
    operations any mode tests, so the rule belongs where the suite's
    environment is built, once: a hand-run `LAZYSITE_OOM_LIB=... prove` is then
    the tier as it runs at night, and the tier needs no knowledge of OOM's
    variable names for it. A test that wants a pack still passes `pack_dirs`.
  - Data: `ODOO_OOM_SHARE` is empty unless the caller sets it, in every mode
    too. `ext-compat.sh` sets it for the deb target to the deb's data directory,
    which is where the deb's behaviours, profiles and `matrix.yaml` are (beside
    its library there are none). The tree target's data is beside its lib, so it
    is given no share root and reads none of the deb's 0.42 data. Only
    `ext-compat.sh` names that directory (t/lint/262).
  - Daemon: `OdooTest::oomd_bin` is `LAZYSITE_OOMD` when set, else the
    snapshot's, and is REFUSED, naming the variable, when `LAZYSITE_OOM_LIB` is
    set without it, rather than run the snapshot's daemon under another OOM.
    `ext-compat.sh` passes the tree's `bin/oomd` and the deb's `/usr/bin/oomd`
    (odoo-oom-tools).
- **t/unit/odoo/78** compares the first root with the target's under the tier:
  the tree beside its lib, else the share root the tier named. Its comparison of
  the host's directory with the snapshot (SM1204's rule 2) is the gate's, and is
  passed under the tier, where that directory is the deb target's own data: once
  the host's deb was 0.44 it holds `res.users` and three other models the 0.42
  snapshot lacks, as it should. The check that the pack directories are
  OdooTest's now holds under the tier too.
- **The FAIL line and the note name the failing files**, from `t/`, matched with
  or without the `$ROOT/` prefix: the line the first ten, the note the first
  twenty one per line and how many failed in all, each with "and N more".
- **Not changed:** the gate (the snapshot run); the snapshot itself (adopting
  OOM 0.44 with `tools/vendor-oom.sh` awaits the release manager); `lib/`.

# Tests

- t/tools/154: the broken-OOM run's FAIL line names `t/unit/odoo/...` files, not
  absolute paths, bounded with "and N more"; the note lists at most twenty,
  counts the rest and the total. The broken OOM writes down the environment it
  was loaded in, and every load saw the tree's `bin/oomd`, OdooTest's no-packs
  directory and an empty share root. A new subtest holds `oomd_bin`: the
  snapshot's in the gate, the named one under the tier, a refusal naming
  `LAZYSITE_OOMD` when only the library is named.
- t/unit/odoo/78 under the tier (proved by the tier run below).
- Sabotage: each fix reverted on its own fails its check (the report of n745
  lists each).
