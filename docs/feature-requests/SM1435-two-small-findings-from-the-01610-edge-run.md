---
id: SM1435
title: "SM1435: the settle panel is said to be on Extensions, and address profiles are predefined and selectable only"
subtitle: "Two findings from the 0.16.10 edge run (Y10, O-2): the Groups page gave no place for the Unknown Odoo writes panel, and set_permissions answered ok for a profile that did not exist. Ruling 234 settles the second: a rule names only profiles that exist."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-10
raised-by: "the 0.16.10 edge run (Y10, O-2), read by the lazysite developer agent on n812"
area: access
status-note: "SHIPPED (PENDING): the Groups page names the settle panel's card on Extensions - configure. Ruling 234: a rule, group limit or page naming a missing address profile is refused on every door, its carried names included; a profile a rule names cannot be deleted (no force). t/integration/730, t/unit/users/548, 53, t/unit/manager/974."
---

# What happened

Y10: the Groups page describes `settle_odoo_writes` with the capability's `grants` text,
which said "Held by the operator group by default" and named no page. n804 (SM1424) put
"its card on Extensions - configure" into `unlocks.ui` and the capability map, which the
Groups page does not draw.

O-2: `set_permissions` with `addresses: ["zz92-allow"]` answered `ok: true` while no
profile `zz92-allow` existed. The rule then refused every write to the path (a missing
profile allowed admits nobody), in the same words as a real rule.

# Ruling 234

Address profiles are predefined and selectable only. A rule that names a profile that
does not exist is refused. A profile in use cannot be deleted, and can be modified. This
reverses SM1139's accept-with-warning.

# What changed

- `extensions/odoo.pl`: the `grants` text says "The panel is the Unknown Odoo writes page,
  linked from its card on Extensions - configure." That declaration is the one source; the
  capability map's row is built from it, and a test holds the phrase equal in `grants`,
  `unlocks` and the map (t/unit/extensions/612).
- `Files::action_acl_set`, which the manager API, MCP `set_permissions` and `lazysite acl
  set` all run, refuses a rule that names an address profile the store does not hold,
  naming each one, and writes nothing (a list of paths is refused whole). The names an
  existing rule already carries are checked too, so a rule left naming a profile removed by
  hand is refused on its next save until the name is cleared. A store that cannot be read
  is a fault: the rule is refused and the fault named (t/integration/730, t/unit/mcp/489).
- A group's address limit (`group-settings-set`: `addresses`, `addresses_deny`,
  `address_limit`) is refused the same way (t/unit/users/548).
- `address-profile-delete` has no force: the CLI's `--force` is an unknown option, the
  API's `force` is not read and is no longer declared, and the Address profiles page lost
  "Delete anyway" and shows the refusal, naming the rules, with Close. MCP exposes no
  delete. Changing a profile in use stays allowed (t/unit/users/53, t/unit/manager/395
  and 974).
- The Files page's permissions card and the Groups page already offer a select of the
  existing profiles, never a free-text field. A name a rule carries that the store lacks is
  marked "no such profile" so it can be set to Not used. The CLI help, the MCP descriptions
  and the docs say to choose an existing profile.

# Not covered

A page's front matter `addresses:` is a file the author writes; `lazysite check` warns of a
name no profile carries (t/unit/tools/82). It is not refused on save.
