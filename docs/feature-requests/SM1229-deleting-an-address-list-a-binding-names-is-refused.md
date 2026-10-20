---
id: SM1229
title: "SM1229: deleting an address list a binding names is refused"
subtitle: "SM1159's recorded residual: the list-delete guard read pages, access rules, groups and lazysite.conf but not a session binding's own address limit. It reads bindings now."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: SM1159 "Open" (the 2026-10-20 inbox triage, buildable item 4)
area: auth
status-note: "SHIPPED (PENDING) on n712: Lazysite::Auth::AddressRefs reads type-odoo records of handlers.conf; the manager and control API refuse (in-use) naming each binding; t/unit/manager/395. force as before."
---

# What happened

SM1159 let a session binding carry `signin_addresses` / `signin_addresses_deny`,
names of address lists, held on the binding's calls. Its filing recorded that
`Auth::AddressRefs`, the reader behind the delete guard (SM1141), did not read
handlers.conf. Confirmed in the code: `rules()` walked pages, acls.json,
groups-settings.json and four lazysite.conf keys, and nothing else. Deleting a
list a binding named succeeded, and the binding then refused every call (an
allow rule naming a deleted list admits nobody, SM1138).

# What shipped

- `Lazysite::Auth::AddressRefs::rules` reads the `type: odoo` records of
  `lazysite/forms/handlers.conf` and returns each list one names in
  `signin_addresses` (allow) or `signin_addresses_deny` (deny) as a rule with
  `where: binding` and the binding id as `ref`. A disabled binding counts.
  A handlers.conf that exists and cannot be read is a fault, so the delete is
  refused as "could not check", as for the other stores.
- The manager's Address lists page and the control API's `address-list-delete`
  (both run the users tool's guard) refuse with kind `in-use`, naming each user
  of the list, bindings as "Odoo binding stock"; `force` deletes anyway, as for
  every other user. `lazysite check` also sees the binding's names, so a missing
  or wrong-kind list in a binding is warned like one in lazysite.conf.
- There is no address-list rename action today, so there is no second door to
  guard; the delete is the only way a name stops resolving.

# Tests

t/unit/manager/395: refused while a binding names the list (allow key, deny key,
a comma list, a flow list, a disabled binding), each kind of user named in one
refusal (page, access rule, group, lazysite.conf, binding), allowed once the
binding names another list, a non-Odoo handler or an unrelated list not in the
way, force, and an unreadable handlers.conf. 9 of its 10 subtests fail on the
old code.
