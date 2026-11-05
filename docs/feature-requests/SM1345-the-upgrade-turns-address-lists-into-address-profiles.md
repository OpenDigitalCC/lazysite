---
id: SM1345
title: "SM1345: the upgrade turns each address list into an address profile, and no site changes behaviour"
subtitle: "The release manager's request of 24 October 2026 (A-4): an install.pl once-step converts lazysite/auth/address-lists.json to address-profiles.json, the same names and entries with no kind; every use keeps its effect."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-24
raised-by: release manager (inbox 2026-10-24-address-profiles-replace-address-lists.md, A-4)
area: install
status-note: "SHIPPED (0.16.5) on n750: install.pl convert_address_profiles_store, once-step address-profiles-converted; t/tools/315."
---

# What was asked

A-4: "Upgrade migration: each existing list becomes a profile with the same name
and entries, and every use keeps its effect (a use of an allow list becomes an
Allow use; a deny list a Deny use). Front matter keeps `addresses:` and
`addresses_deny:`, which now name profiles. No site changes behaviour."

# What shipped

- **The store is the whole conversion.** Every place a rule names a list already
  names it in the slot its kind meant: `addresses` for an allow list,
  `addresses_deny` for a deny list, on pages, access rules, groups, the
  lazysite.conf keys and session bindings, because every save refused the other
  slot (SM1189). With the kind gone (SM1343) the slot is the use's choice, so a
  use of an allow list is an Allow use and a deny list's a Deny use without any
  rule being rewritten.
- **install.pl, once** (`address-profiles-converted` in the install state, SM798):
  `convert_address_profiles_store` decodes `address-lists.json` with JSON::PP
  (the installer loads no Lazysite module, SM767), drops each record's `kind`,
  writes `address-profiles.json` with the old file's mode and owner, and only then
  renames the old file to `address-lists.json.converted`, a record of what it
  held. Reported: "converted 2 address list(s) to address profiles of the same
  names: blocked (was deny), office (was allow); every rule keeps its effect".
- **Idempotent.** No old file: nothing to do, the step is recorded (so a new site
  records it at provision). A profile store already there is never overwritten;
  the summary says both exist and leaves them for the operator. An old file that
  will not read or decode is left where it is and the step is not recorded: the
  engine reads that site as unconverted and refuses every rule naming a profile
  (SM1343), the summary warns, and the next upgrade tries again. An empty store
  would instead have let every deny rule block nobody.

# Tests

t/tools/315 upgrades a site as 0.16.4 left it with the real install.pl: an allow
list (`office`) and a deny list (`blocked`) named by a page (both), a folder rule
(the allow list), a group (the deny list), the manager's and sign-in's keys, and
asked by a binding's membership. The profile store has the same names and entries
and no kind; the answers of the one module every gate asks match a table of what
0.16.4 answered, for an office address, the scanner inside the office range and an
outside address; no rule file changed; the summary; the once-step; a second run;
both stores present; an undecodable old store. Sabotage (the conversion taken out
of the once-step): 5 of 8 fail.

# Open

- A rule that named a list of the wrong kind (only by a hand edit; SM1189 refused
  it at every save and `lazysite check` has named it since 0.15.10) refused every
  visitor until now. Converted, it applies in the slot it is in. It is not
  rewritten or reported by the upgrade (that needs the rule walk the installer
  cannot load). Ruling wanted on whether the upgrade must find and report them.
