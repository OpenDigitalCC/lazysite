---
id: SM1343
title: "SM1343: address lists become address profiles, allowed or denied where they are used"
subtitle: "The release manager's request of 24 October 2026 (A-1, A-2, A-5): a named set of addresses has no allow or deny kind; each rule that names it chooses. Renamed outright (ruling 56); a profile in use is not deleted (ruling 57)."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-24
raised-by: release manager (inbox 2026-10-24-address-profiles-replace-address-lists.md, rulings 56-58 of 2026-11-04)
area: auth
status-note: "SHIPPED (0.16.5) on n750: Lazysite::Auth::AddressProfiles (auth/address-profiles.json, no kind; the slot a rule names a profile in decides), /manager/address-profiles, actions address-profile(s|-set|-delete), MCP list_address_profiles, the users tool; old names refused naming the new. t/unit/auth/63, t/unit/users/52, t/integration/266, t/lint/320."
---

# What was asked

> 'Limited by address' on files (and anywhere else) should not be addresses -
> that would be unmanageable to add to each page etc. Instead, named IP address
> profiles to be created (inc v4 & v6), then the selected profiles can be allowed
> or denied in replacement to the address lists.

SM1134's address lists each carried a kind fixed at creation, so one office range
allowed on one page and denied on another had to be kept twice. Rulings 56 (rename
outright, no aliases, as SM1142 did), 57 (a profile in use cannot be deleted, as
SM1229 for lists) and 58 (the Odoo binding's key is already `address_profile`).

# What shipped

- **A-1, the profile.** `Lazysite::Auth::AddressProfiles` replaces
  `Lazysite::Auth::AddressLists`, and `lazysite/auth/address-profiles.json` replaces
  `address-lists.json`: a name and entries (IPv4 and IPv6 addresses and CIDR
  ranges, each with a note), and no kind. A `kind` a hand edit leaves on a record
  is ignored, and the next write drops it. The users tool remains the one writer,
  for the operator only; every change is audited.
- **A-2, every use chooses.** The slot a rule names a profile in is the whole of
  its meaning: `addresses` allows, `addresses_deny` denies, in page front matter,
  per-file and folder rules, groups, `manager_addresses` / `signin_addresses` and
  their `_deny` keys, and a session binding's sign-in keys. `decide` lost the
  SM1189 "wrong kind" refusal with the kind; deny still wins, and every layer of a
  folder and its page must still admit. The save-time kind refusals (the Files
  rule, the group setting, the Config keys, the validator's
  `address-list-wrong-kind` issue) and `lazysite check`'s wrong-kind warning go
  with it. The membership check stays in one place: `decide` and `in_profile`,
  called by the processor, `Auth::Acl`, `Auth::AddressScope` and the Odoo
  endpoint; `Auth::AddressRefs` is still the one walk of where rules name a
  profile.
- **The Odoo binding (ruling 58).** `address_profile` reads a profile through
  `in_profile` (membership only, the operation decides what inside means), and
  counts as in use.
- **The template test.** `visitor.in_list` / `visitor.in_any` answer membership of
  a profile; the method names are kept (see the question below).
- **A-5, the names, renamed outright (ruling 56).** The manager page is Access,
  Address profiles (`/manager/address-profiles`); the actions are
  `address-profiles`, `address-profile-set`, `address-profile-delete`; the MCP tool
  is `list_address_profiles`; the users tool's commands are `address-profiles`,
  `address-profile-set NAME [--entry CIDR[=note] ...]` and
  `address-profile-delete NAME [--force]`; the reply's key is `profiles`. A caller
  still sending an old action, tool or command is answered "unknown ... use
  'address-profile-set' (SM1343)". The users tool refuses `--kind` (and a `kind`
  in its API request) by name, `field: kind`, so nobody believes they made an allow
  or a deny list; the manager API reads no `kind` and answers none. The docs,
  the briefing pages, the manager guide and the generated references say profile.
- **Ruling 57.** A profile a rule names is refused deletion naming where, as
  before; `force` deletes it after a second confirmation.
- **Unconverted fails closed.** A site where `address-lists.json` is still there
  with no profile store is a store fault (`unconverted`): every rule naming a
  profile refuses, the writer refuses to start a profile store beside it, and
  `lazysite check` names it with the remedy. An absent store would have let every
  rule that denies one block nobody. The conversion itself is SM1345.

# Tests

- t/unit/auth/63: one profile allowed by one rule and denied by another, a kind
  left by hand ignored, deny wins in one rule, unconverted fails closed.
- t/unit/users/52: the store has no kind, `--kind` and an API `kind` are refused,
  the old commands are told the new names.
- t/integration/266: the old actions (cookie and token) and the MCP tool are refused naming the new ones.
- t/unit/lib/205, t/unit/tools/85, t/unit/auth/67: a page, the check and the Config
  keys accept a profile in either slot; the check names an unconverted store.
- t/lint/320: the rename invariant (old spellings only in history, the old store's
  name, a line dating the rename, and the listed old-address-name regions).
- The SM1134 suites (pages, files, groups, sign-in, the delete guard, the template
  test, the Odoo binding) run unchanged in meaning on profiles.

# Open

- The template methods `visitor.in_list` / `in_any` kept their names: renaming
  them would break site templates with no conversion. Ruling wanted.
