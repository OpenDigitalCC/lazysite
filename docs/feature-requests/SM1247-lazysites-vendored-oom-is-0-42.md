---
id: SM1247
title: "SM1247: lazysite's vendored OOM is 0.42"
subtitle: "The pinned OOM snapshot moves from 0.38 to 0.42, skipping 0.39 to 0.41. One change of the four reaches lazysite: oomd's config `namespaces` and its `reload` verb, which SM1248 adopts."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: "supervisor brief, task #373 (OOM 0.42 installed on the host; lazysite vendors 0.38, SM1216)"
area: odoo
status-note: "SHIPPED (PENDING) on n727: t/vendor/oom is OOM b91d5e2 (Package 0.42), taken by tools/vendor-oom.sh with the 0.42 library and tools debs. SM747's spec is re-filed. Every Odoo test dir passes on it unchanged; the one change lazysite adopts is SM1248."
---

# What happened

OOM 0.42 is released (OOM commit b91d5e2, "Package 0.42") and installed on the host.
lazysite vendored 0.38 ([[SM1216]]). This takes 0.42 and skips 0.39, 0.40 and 0.41.
OOM's `debian/changelog` for 0.39 to 0.42 was read entry by entry against lazysite's
code. Every OOM name lazysite calls was then looked for in `lib/`, `plugins/`,
`lazysite-odoo.pl` and `tools/`.

# What shipped

- **`t/vendor/oom` is OOM b91d5e2, "Package 0.42"**, taken with
  `tools/vendor-oom.sh --deb libodoo-oom-perl_0.42_all.deb --deb
  odoo-oom-tools_0.42_all.deb b91d5e2` (328 files). The library, the spec and
  `bin/oomd` were checked against the debs. [[SM1206]] held: every file it wrote is
  group-writable, and every directory keeps the setgid bit.
- **SM747's filed spec is re-filed.** Section 9 of MAPPER-SPEC.md gained the 0.39
  to 0.42 probe rows: the plain-text part of a mailing, mailing slices, the
  accounting, credit and reconciliation rows, and the stock profile row for 18.
  Sections 7 to 10 and the Open list are copied again, with dashes, arrows and the
  ellipsis made ASCII. The same transformation reproduces the 0.38 filing byte for
  byte. The recorded sha256 is `f3df9c5a...fb80` (lint 207).

# Each change of 0.39 to 0.42, against lazysite

| OOM | Change | Reaches lazysite? |
| --- | --- | --- |
| 0.39 | oomd reads `namespaces` from its config; SIGHUP and the new `reload` verb swap the workers with no gap | **Yes.** lazysite restarted oomd to change its namespaces. [[SM1248]] uses the config key and the verb instead |
| 0.39 | the plain-text part of a mailing (`mailing.preview`, `mailing.test`) | No: lazysite calls no `mailing.*` operation |
| 0.40 | `core.group`; `core.read` takes `offset` and `total`; `account.reconcile` and others; `core.mail`; the recon and credit packs | No. These are new parameters and operations. A binding names an operation and the parameters a request may set, so a binding gets them only by naming them. `core.read` without `offset` or `total` answers as before |
| 0.41 | `mailing.status` with no `mailing=`; mailing slices | No: not called |
| 0.42 | `doctor`'s `tls.chain` judges expiry against the certificate's lifetime | No: lazysite does not run OOM's doctor (`lazysite check` is its own) |
| 0.42 | a stock profile for Odoo 18 | No. It is in the snapshot's `profiles/`, and t/unit/odoo/78 still finds every profile there and none on the host |
| 0.42 | an unknown run id is `refused/unknown-run`, not `usage`, in `Odoo::Ops::Runs` `record`, `approve`, `withdraw`, `close_run` and `mark_reverted` | No. lazysite calls `approve_plan`, `idem_claim` and `request_digest` only. A confirm through oomd sends the run id to the daemon's `approve` phase, which finds the plan by path (`Odoo::Ops::Service::_plan_path`), not through `Runs->approve`. A probe on the 0.42 snapshot is described under *Found* |
| 0.42 | `mailing.status` takes `limit` | No: not called |

No verb lazysite uses was renamed or removed. No return shape it reads changed:
`Odoo::Ops::Service`, `Plan`, `Runner`, `Result`, `Wire`, `Daemon::Path` and
`Odoo::Error` are byte-identical between 0.38 and 0.42. `health`
gained `generation` and `namespaces`, which are additions.

# Tests

On the 0.42 snapshot, with no lazysite change:

- t/unit/odoo/ (81 files) passes.
- t/unit/daemon/ (16) passes.
- The Odoo integration files 170, 171, 172, 174, 325 and 326 pass.
- t/tools/154, 155, 180, 181 and 188 pass.

t/lint/207 fails if the SM747 re-file is left out. t/lint/261 holds the snapshot to its
MANIFEST.

# Found, not changed

- **A confirm whose daemon run folder is gone is answered `config`.** This is the same
  on 0.38. Probe: a plan made through oomd, its folder
  `lazysite/odoo/runs/<run_id>` removed, then confirmed. The daemon's `approve` phase
  fails in `Odoo::Ops::Plan->load` with "cannot read plan ...: No such file or
  directory", kind `config`. The page is told "the Odoo connection is not configured
  correctly - see the event log". The plan record in lazysite's own `plans/` is still
  there. The release manager ruled on 2026-10-22 that it answers `not-found`, saying to
  make the plan again: [[SM1261]].
