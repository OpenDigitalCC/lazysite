---
id: SM1170
title: "SM1170: a custom change of a site's own pack applies"
subtitle: "Plan and apply see the same operations: the site's packs and pack directories are in OOM's environment for the apply as well as the plan."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-18
raised-by: OOM Lab stock and picking apps findings (inbox 2026-10-17-oom-lab-stock-and-picking-apps-findings.md, L-12)
area: odoo
status-note: "SHIPPED on n659 (base n655); t/unit/odoo/52-a-custom-change-of-a-site-pack-applies.t. Also closes the same flaw in SM1164 D0's odoo_pack_dirs."
---

# What happened

Inbox L-12 (the lab's two apps, every validate and every stock move):

> **Defect.** A `custom` change of a SITE pack cannot be applied through the
> extension. `Lazysite::Odoo::registry()` sets `ODOO_OPS_NAMESPACES` with
> `local` while it looks the operation up and plans; `Odoo::Ops::Runner->apply`
> (Lazysite/Odoo.pm, near lines 831 and 921) builds a fresh registry without the
> site's namespaces, cannot find the operation's class, and the apply ends
> `apply-incomplete` with "no operation 'lab.stock.move'". The CLI works because
> it sets the env for the whole process. Both apps work around it by setting the
> env inside their own `plan` (which only helps an immediate binding, where plan
> and apply share a process). Fix: hold the namespaces across apply too (or pass
> them to the Runner).

OOM's Runner carries out a `custom` change by finding the planning operation's
class again: `Odoo::Ops::Registry->new->class_for($handler)`, with no
arguments, so the registry it builds reads the process environment alone. The
extension set that environment only inside `registry()`. A pack from
`odoo_pack_dirs` (SM1164 D0) had the same flaw: its directories and cache were
passed to the one registry, never to the Runner's. A confirm is a separate
request from its plan, so nothing carried over.

# What shipped

- One helper, `Lazysite::Odoo::with_site_ops($conn, $code)`, sets with `local`
  everything OOM's registry reads from the environment for this site:
  `ODOO_OPS_NAMESPACES` (odoo_packs), `ODOO_OOM_PACK_DIRS` (odoo_pack_dirs) and
  `XDG_CACHE_HOME` (the site's own cache beside the store, as `registry()` already
  gave it), and runs the block inside them.
- `registry()` and both `Odoo::Ops::Runner->apply` calls (confirm, and
  `apply: immediate`) run inside it, so plan and apply see the same operations.
  Nothing is set process-wide; the test checks the environment is bare before and
  after. The extension has no revert or resume call of its own to cover.
- Test `t/unit/odoo/52-a-custom-change-of-a-site-pack-applies.t`, on OOM's fake
  Odoo with a fixture pack whose plan has a `custom` change: a pack from
  `odoo_packs` and one from `odoo_pack_dirs`, each planned in one call and
  confirmed in another, and each as an immediate binding. On the base all three
  subtests end `apply-incomplete`; with the fix they pass.

# Left to OOM

OOM could take the registry as an argument to `Runner->apply` (and to
`revert_plan`) instead of building its own from the environment. Lazysite's fix
does not need it.
