---
id: SM1435
title: "SM1435: the settle panel is said to be on Extensions, and a rule naming a missing address profile is refused"
subtitle: "Two small findings from the 0.16.10 edge run (Y10, O-2): the Groups page gave no place for the Unknown Odoo writes panel, and set_permissions answered ok for a profile that did not exist."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-10
raised-by: "the 0.16.10 edge run (Y10, O-2), read by the lazysite developer agent on n812"
area: access
status-note: "SHIPPED (PENDING): the Groups page's label for settle_odoo_writes names its card on Extensions - configure; a rule naming an address profile the store lacks is refused on every door, naming it. t/unit/extensions/612, t/unit/mcp/489, t/integration/730; 145 and 281 updated."
---

# What happened

Y10: the Groups page describes `settle_odoo_writes` with the capability's `grants` text,
which said "Held by the operator group by default" and named no page. n804 (SM1424) put
"its card on Extensions - configure" into `unlocks.ui` and the capability map, which the
Groups page does not draw.

O-2: `set_permissions` with `addresses: ["zz92-allow"]` answered `ok: true` while no
profile `zz92-allow` existed. The rule then refused every write to the path (a missing
profile allowed admits nobody), in the same words as a real rule.

# What changed

- `extensions/odoo.pl`: the `grants` text says "The panel is the Unknown Odoo writes page,
  linked from its card on Extensions - configure." That declaration is the one source; the
  capability map's row is built from it. A test holds the phrase equal in `grants`,
  `unlocks` and the map.
- `Files::action_acl_set`, which the manager API, MCP `set_permissions` and `lazysite acl
  set` all run, refuses a rule that names an address profile the store does not hold,
  naming each one, and writes nothing (a list of paths is refused whole). It was accepted
  with a warning, on the reasoning that a profile may be created later. A store that cannot
  be read is a fault: the rule is refused and the fault named. Only the names a request
  gives are checked; a name an existing rule carries is left alone.

# A profile deleted after a rule names it

Already covered, and unchanged: `address-profile-delete` refuses while a rule names the
profile (`--force` deletes and the audit row says what still names it), and
`lazysite check` warns of a rule naming a profile the store lacks, by name and place
(t/unit/tools/82).
