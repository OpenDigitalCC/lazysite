---
id: SM1424
title: "SM1424: the 0.16.9 edge findings were wording, and the wording is fixed"
subtitle: "Four findings from the 0.16.9 edge run (Z10 twice, Z19, O-1) were the design. Three of them misled the tester because the words around them were loose; those words now say what the code does."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-10
raised-by: "the 0.16.9 edge run (Z10, Z19, O-1), read by the lazysite developer agent on n804"
area: docs
status-note: "SHIPPED (0.16.10): panel link said to be on Extensions - configure; UPGRADE note holds to the layer roles' conditions; a write refused by an address rule says the rule limits changes; check and validate_page say description: is not read. t/unit/extensions/381, users/317, mcp/258, tools/591, integration/281."
---

# What was asked

Four rows of the 0.16.9 edge results read as defects: no link to the Unknown Odoo
writes page on the Odoo card, a body `csrf` field answered 403, `analysts` and
`lead-readers` absent after the Groups page was opened, and `delete_page` answered
`ok: false` in a folder with an address rule.

# What was found

All four are the design. The card with the link is on Extensions - configure
(`/manager/extension-config`), not the enable/disable page; the endpoint kit reads the
header `X-CSRF-Token` or the body field `token` (odoo.md says so); the layer roles need a
shipped bundle group (`_adopt_layer_roles`); an address rule has no operator bypass
(SM1139).

# What changed

- The Odoo capability's description and the generated capability map name Extensions -
  configure.
- UPGRADE.md says when the two roles arrive: an operator group and a shipped bundle
  group, a role the site lacks and has not had, none where the operator group carries
  the `seeded` mark, and no members.
- A change refused by an address rule says the rule limits changes to its allowed
  addresses and the change must be made from one. It names no address and no profile;
  `kind: address`, `retryable: false` and the read sentence are unchanged.
- A page with `description:` is told, by `lazysite check` and `validate_page`, that the key
  is not read (the engine reads `meta_desc`, else `subtitle`) and which two are. No third
  spelling is added.
