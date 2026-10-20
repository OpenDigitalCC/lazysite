---
id: SM1207
title: "SM1207: a custom change of a site pack applies through oomd"
subtitle: "The OOM Lab's finding L-1 (a custom change of a pack operation dies 'no operation' at apply) was fixed for the in-process path by SM1170. Through oomd it already worked: the daemon starts with the site's packs. t/unit/odoo/79 holds it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "the OOM Lab, oom-pick FINDINGS.md L-1 (apps/oom-pick, Validate.pm _teach_the_runner)"
area: odoo
status-note: "SHIPPED (0.15.14) on n695: verified, no code change. oomd starts with ODOO_OPS_NAMESPACES from odoo_packs and pack_dirs in its config, so its Runner finds the class. t/unit/odoo/79 applies a pack custom change through oomd."
---

# What was asked

The lab's L-1: a `custom` change of a pack operation cannot apply through the
extension unless `ODOO_OPS_NAMESPACES` is set at apply as well as plan time; the
Runner calls `Odoo::Ops::Registry->new->class_for_handler(...)` with no arguments
and the apply ends `apply-incomplete` with "no operation". The lab works round it
in `Validate.pm` (`_teach_the_runner`).

# What was found

- In process: fixed by [[SM1170]] (`with_site_ops` around `Runner->apply`,
  lib/Lazysite/Odoo.pm), held by t/unit/odoo/56.
- Through oomd: the Runner is oomd's, in a process that is not the request's, and
  reads its own environment and config. The service starts oomd with
  `ODOO_OPS_NAMESPACES` set to the site's `odoo_packs` (lib/Lazysite/Daemon/Service/Oomd.pm
  `_start`), and `pack_dirs` is in the config lazysite writes for it
  (lib/Lazysite/Odoo/Daemon.pm). The vendored OOM 0.36 resolves the class from
  those: Runner.pm line 652 `Registry->new->class_for_handler`, Registry.pm
  `new` reads `$ENV{ODOO_OPS_NAMESPACES}` and the config's pack directories.
  No code change was needed.

# What shipped

t/unit/odoo/79, through the real oomd: a custom change of a test pack operation
(t/lib/LazysiteTest/OdooCustom/Mark.pm, and a pack in a pack directory) is planned,
confirmed and applied, and the operation leaves the daemon's pid in a file.
Sabotage: starting oomd with no namespaces, or leaving `pack_dirs` out of its
config, fails it with "no operation".

The lab can drop `_teach_the_runner` for the daemon path. Its note that "the apply
dies" holds only for a process started without the site's packs.
