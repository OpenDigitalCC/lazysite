---
id: SM1216
title: "SM1216: lazysite's vendored OOM is 0.38"
subtitle: "The pinned OOM snapshot moves from 0.36 to 0.38, skipping 0.37. The suite now reads none of the host's OOM data, and a refusal's code through oomd is an ordinary assertion."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "release manager, 2026-10-20 (skip OOM 0.37, adopt 0.38); OOM agent, inbox 2026-10-20-oom-0.37-code-share-rows-shop-helpdesk.md"
area: odoo
status-note: "SHIPPED (0.15.15) on n703: t/vendor/oom is OOM 8ccf2ae (Package 0.38), taken by tools/vendor-oom.sh with both 0.38 debs. OdooTest sets ODOO_OOM_SHARE empty, and t/unit/odoo/78 asserts the host's directory is not searched. t/unit/odoo/77's TODO is now a plain assertion. SM747's spec is re-filed. The has_groups change is SM1217."
---

# What happened

The release manager ruled on 2026-10-20: skip OOM 0.37 and adopt 0.38. 0.38 is
released (OOM commit 8ccf2ae, "Package 0.38") and installed on the host. The OOM
agent's note for 0.37 (inbox 2026-10-20-oom-0.37-code-share-rows-shop-helpdesk.md),
OOM's `debian/changelog` for 0.37 and 0.38, and lazysite's tests on the new snapshot
name these changes that reach lazysite:

1. `ODOO_OOM_SHARE` (0.37, lazysite's SM1202 ask): "names the installed share root
   that behaviours, profiles and `matrix.yaml` fall back to ... empty names none".
2. `core.has_groups` answers `{ groups => { XMLID => 1|0 } }` only (0.37). This is
   [[SM1217]].
3. `failed_changes` carries a refused change's `code` (0.37).
4. A rows `str` may hold newline, carriage return and tab, and a key may declare its
   own `max` (0.37).
5. A change whose answer never came is `unknown`, not `failed` (0.38, runs-38).

# What shipped

- **`t/vendor/oom` is OOM 8ccf2ae, "Package 0.38"**, taken with
  `tools/vendor-oom.sh --deb libodoo-oom-perl_0.38_all.deb --deb
  odoo-oom-tools_0.38_all.deb 8ccf2ae` (315 files). The library, spec, tools and
  `bin/oomd` were checked against the debs. [[SM1206]] held: every file and
  directory it wrote is group-writable.
- **The suite reads none of the host's OOM data.** `t/lib/OdooTest.pm` sets
  `ODOO_OOM_SHARE=` beside `ODOO_OOM_PACK_DIRS`, under the same rule: unless the
  caller set it, or `LAZYSITE_OOM_LIB` names the host's library
  (`tools/ext-compat.sh`). t/unit/odoo/78 now asserts the following with an OOM that
  honours the variable (0.37 and later):
  - no host root is in `core_dirs` for behaviours or profiles;
  - no `matrix.yaml` comes from the host;
  - `OdooTest` set the variable empty.

  [[SM1204]]'s rule still holds an OOM that does not honour it, and the advisory
  tier. With 0.38 on the host, 78 reports no TODO. Lint 262's notes say where the
  host's data is turned off.
- **A refusal's code through oomd is an ordinary assertion.** t/unit/odoo/77 held
  "and its code" as a TODO for 0.36 ([[SM1198]]). On 0.38 it passes, so it is now a
  plain `is`.
- **SM747's filed spec is re-filed.** Section 9 of MAPPER-SPEC.md gained the 0.37
  and 0.38 probe rows (mailing domains, mailing on Odoo 18, the shop basket,
  helpdesk). Sections 7 to 10 and the Open list are copied again, with dashes,
  arrows and the ellipsis made ASCII. The recorded sha256 is `5ef4c94b...c048`
  (lint 207).

# What was checked and needed no change

- **Rows text (item 4).** lazysite's own row check (`Binding::_rows`, SM1166 and
  SM1198) runs OOM's `Odoo::Ops::Rows->check` first. It then applies lazysite's
  plain-value rule (`_plain_problem`) to each value, and that rule already admits
  tab, newline and carriage return. A probe on the 0.38 snapshot gave these results:
  - `"line one\nline two\tx\r\n"`: accepted;
  - a bell character: refused, in OOM's new words.

  No lazysite refusal duplicates OOM's old rule.
- **t/unit/odoo/ whole (69 files) passes**, with t/unit/daemon/, the Odoo
  integration tests 170, 171, 172 and 174, and t/tools/154, 155 and 181. Only
  t/unit/odoo/63 broke, on item 2 ([[SM1217]]).

# Not done

- **lazysite's per-value cap overrides a key's own `max`.** `_plain_problem` holds
  every request value, row values included, to `$MAX_VALUE` (1,000 characters). So
  a rows key an operation declares `max => 5000` is still refused by lazysite past
  1,000 characters, though OOM alone accepts it. That is lazysite's bound on what a
  visitor may send. Whether a declared `max` should raise it is the release
  manager's decision.
- **An `unknown` change (0.38) reaches the page only as its outcome.** OOM's result
  now has `counts.unknown` and `unknown_changes` (a write sent with no answer), and
  `ok` is false. lazysite answers `apply-incomplete` with the counts. The change's
  journal outcome `unknown` is in `changes`, but the `reason` in `unknown_changes`
  is not passed on as `failed_changes` is (SM1193). No lazysite test exercises it.
- **The advisory tier's first assertion in 78** ("the snapshot's tree is searched
  first") fails when `LAZYSITE_OOM_LIB` names the host's library, because the tree
  beside that library is not the snapshot. This is the same before and after this
  change.
- 0.37 and 0.38's other additions (helpdesk, the mailing pack on 18, chunked
  sends, shop 1.1.0, `resume` reading before it repeats) are not used by lazysite.
