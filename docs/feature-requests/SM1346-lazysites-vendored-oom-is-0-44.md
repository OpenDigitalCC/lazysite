---
id: SM1346
title: "SM1346: lazysite's vendored OOM is 0.44"
subtitle: "The pinned OOM snapshot moves from 0.42 to 0.44, skipping 0.43. No change of the two releases needs a lazysite change; one, a write Odoo did not keep, is not yet shown to a page."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-05
raised-by: "ruling 82 (Q14, inbox triage 2026-11-05 T-37): adopt OOM 0.44 (commit f32c444, checked against its debs) in 0.16.5, after n745's harness fixes"
area: odoo
status-note: "SHIPPED (PENDING) on n751: t/vendor/oom is OOM f32c444 (Package 0.44), taken by tools/vendor-oom.sh with the 0.44 library and tools debs. SM747's spec is re-filed. Every Odoo test dir passes on it with no lib/ change."
---

# What happened

OOM 0.44 is released (OOM commit f32c444, "Package 0.44"). lazysite vendored 0.42
([[SM1247]]). This takes 0.44 and skips 0.43. OOM's `debian/changelog` for 0.43 and
0.44, and its notes to lazysite of 2026-11-04, were read entry by entry against
lazysite's code, and every OOM module lazysite loads was diffed between the two
releases.

# What shipped

- **`t/vendor/oom` is OOM f32c444, "Package 0.44"**, taken with
  `tools/vendor-oom.sh --deb libodoo-oom-perl_0.44_all.deb --deb
  odoo-oom-tools_0.44_all.deb f32c444` (351 files). The library, the spec and
  `bin/oomd` were checked against the debs. [[SM1206]] held: every file it wrote is
  group-writable, and every directory keeps the setgid bit.
- **SM747's filed spec is re-filed.** Section 9 of MAPPER-SPEC.md gained the 0.43
  and 0.44 probe rows: activities marked done, quiet writes and the assignment
  mail, deleting a user, access rows on an existing group, the records a create
  brings into being, the revert guards, a group change read back, and the Discuss
  channels. Sections 7, 8 and 10 and the Open list are unchanged. The same
  transformation reproduces the 0.42 filing byte for byte. The recorded sha256 is
  `cb1b8d97...fa16` (lint 207).
- **Two test comments that named the 0.42 snapshot** now name no version
  (t/lib/OdooTest.pm's header, t/unit/odoo/78).

# Each change of 0.43 and 0.44, against lazysite

| OOM | Change | Reaches lazysite? |
| --- | --- | --- |
| 0.43 | one quiet context (`Odoo::Ops::Quiet`), now with `mail_auto_subscribe_no_notify`; `core.make` takes `quiet` | No code change. A binding whose operation is `core.make` may now name `quiet` among its parameters |
| 0.43 | many2many as ids or names in `core.set` and `core.make`; `[]` and `false` clear a field | No. These are new values of existing parameters; a binding passes what its declaration admits |
| 0.43 | `--set` text is decoded as UTF-8 once | No: that is `oom-ops`'s command line. lazysite calls the library with Perl strings |
| 0.43 | `refused/access` from `core.get` and `core.set` for a record the user may not read; `missing` only when it does not exist | No code change. lazysite's `%REFUSED_KIND` names neither `access` nor `missing`, so both answer the page `refused`, "the call was refused before Odoo answered", and the code goes to the event log. See *Found, not changed* |
| 0.43 | `core.user delete`; activities marked done through `core.action`; `core.action` and `core.wizard` give the URL of an `act_url` answer | No: new operations and fields of `custom` answers, reached only by a binding that names them |
| 0.43 | revert guards (`template-groups-propagate`, the hash seal) | No: lazysite runs no revert |
| 0.43 | a create names the records Odoo made beside it | No change needed. They arrive in the result's `custom` as `made alongside`, which lazysite does not pass; the change's own entry is unchanged |
| 0.44 | **a write is verified against what it asked**: a field Odoo dropped or changed makes the change `not_verified`, with `not_held` (field, asked, found) in the journal and a `not held` entry in the result's `custom`; the change stays `done`; fields that cannot be compared are listed in `unchecked` | **Not shown yet.** See *Found, not changed* |
| 0.44 | the mapping transform `datetime:FORMAT:ZONE` | No: a `core.import` mapping is the operation's, not lazysite's. `Odoo::Ops::Source` now loads DateTime and DateTime::TimeZone, which the 0.44 deb Depends on |
| 0.44 | `quiet` on `core.set` and `core.action` | No code change, as `core.make`'s in 0.43 |
| 0.44 | the Discuss pack (`discuss.channel_create`, `members`, `pin`, `leave`); `id_ref` on a plan change | No: new operations. A plan lazysite holds is OOM's own, so `id_ref` needs nothing of lazysite |
| 0.44 | input over `max_input_bytes` (64 MiB) is `refused/input-too-large` | No. lazysite caps a request well below it (a 64 KB JSON part, at most 20 MiB for one file, `$FILE_CEILING_KB`), and does not set the key |
| 0.44 | `doctor`'s `config.deps`; `dist/sbom-<version>.json` | No: lazysite does not run OOM's doctor |

Of the modules lazysite loads, `Odoo::Error`, `Odoo::Ops::Service`, `Result`,
`Runs`, `Journal`, `Blob`, `Registry`, `File`, `Daemon::Path`, `Client::Daemon` and
`bin/oomd` are byte-identical between 0.42 and 0.44. `Odoo::Ops`, `Config`,
`Context`, `Plan` and `Rows` gained the input bound, `Plan` the `id_ref` change, and
`Runner` the verification. No verb lazysite uses was renamed or removed, and no
return shape it reads changed.

# Tests

On the 0.44 snapshot, with no lazysite change:

- t/unit/odoo/ passes.
- t/unit/daemon/ passes.
- The Odoo integration files 170, 171, 172, 174, 325 and 326 pass.
- t/tools/154 and 155 pass.

t/lint/207 fails if the SM747 re-file is left out. t/lint/261 holds the snapshot to its
MANIFEST.

# Found, not changed

- **A write Odoo did not keep reaches a page as `done`.** From 0.44 OOM compares
  each field written with the row after the write. lazysite's result passes
  `verified` and, per change, the journal's `outcome`; it passes neither
  `not_verified` nor the change's `not_held`, so a page cannot tell a write Odoo
  dropped from one it kept. Whether to show it, and how much (the asked value is the
  caller's, the found value is Odoo's record), is a product decision and is asked,
  not built. The unknown-run settle ([[SM1275]] to [[SM1279]]) is not affected: OOM
  reads a formerly unknown change back as made or not made and does not compare its
  fields; the changes a resume carries are applied as any apply, with the same gap.
- **The gate host needs libdatetime-perl and libdatetime-timezone-perl**, which are
  installed here. lazysite lists no dependency that only the vendored OOM has
  (XML::LibXML, which OOM has needed since before SM1081, is not listed either):
  `debian/control` names libodoo-oom-perl nowhere, and the deb carries its own
  Depends. So nothing is added.
- **`refused/access` reads to a page as "refused before Odoo answered".** OOM 0.43
  tells a record the user may not read (`access`) from one that does not exist
  (`missing`). lazysite answers both with the generic refusal, whose sentence is
  wrong for `access`: Odoo did answer. Naming the two codes in `%REFUSED_KIND` is a
  small follow-up and is asked, not built.
