---
id: SM1276
title: "SM1276: a capability settles an Odoo write whose answer never came"
subtitle: "Ruling 10a: where OOM cannot read a change back, the run's own actor, or a holder of a new override capability, says whether it was made. The capability is settle_odoo_writes, declared by the Odoo extension, and every operator group holds it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "the release manager, rulings 10a-10c (2026-10-23)"
area: odoo
status-note: "SHIPPED (PENDING) on n733: settle_odoo_writes in @CAP_KEYS and the check's copy, described in the capability map, owned by plugins/odoo.pl; the SM645 top-up gives it to a manager group. Used by SM1275 (assume on another's run) and SM1278 (the manager's list, assume and dismiss). t/unit/odoo/105."
---

# What was asked

Ruling 10a (2026-10-23): resuming an unknown Odoo plan, OOM reads each change back
first. Where it cannot, "the run's own actor, or a holder of a new override
capability, may assume done or not done". The capability is new. It is named by the
repository's conventions and added to the manager-group top-up (SM645).

# What shipped

- **`settle_odoo_writes`**: a verb and its object, as `approve_accounts`,
  `read_submissions` and `run_jobs` are named. `manage_*` is for configuring, and this
  configures nothing.
- **Declared by the Odoo extension.** `plugins/odoo.pl` lists it under
  `owns.capabilities`, as the data plugin declares `manage_data`. It is mirrored in
  `@CAP_KEYS` and in `lazysite check`'s copy (t/lint/81). t/lint/76 holds the pair.
- **Described** in `Lazysite::Capabilities` (section Operations), so the capability
  map and `describe-capabilities` say what it grants. SM1278 adds the actions it
  unlocks.
- **Operator groups hold it.** It is in `@CAP_KEYS`, so a new site's manager group has
  it. A site seeded before it existed gets it from the SM645 top-up on the next use of
  the users tool, or from `lazysite repair` (SM1273). A declined 0 is never filled.
- **On the Groups and Users pages**, as "Settle Odoo writes", so an operator can grant
  it (t/lint/19).
- **Not in a role bundle.** No other role draws on it by default. A sysop grants it to
  a group on the Groups page.

# Tests

t/unit/odoo/105:

- `plugins/odoo.pl --describe` owns it, it is in `@CAP_KEYS`, and it is described;
- a new site's `sysops` holds it;
- with the entry removed, `group-reach sysops` grants it again;
- a declined 0 stays 0.

With `@CAP_KEYS` and the plugin's declaration reverted, all three subtests fail.
