---
id: SM1344
title: "SM1344: the Files page limits a rule by address profile, each chosen Allow or Deny"
subtitle: "The release manager's request of 24 October 2026 (A-3, and ruling 107 for the Groups page): 'Limited by address' becomes 'Limited by address profile', one picker of profiles in place of the two kind-filtered pickers."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-24
raised-by: release manager (inbox 2026-10-24-address-profiles-replace-address-lists.md, A-3)
area: manager
status-note: "SHIPPED (0.16.5) on n750: starter/manager/files.md addressRows / addressBlock / chosenAddresses, starter/manager/groups.md groupAddressRows / chosenGroupAddresses / setGroupAddresses; t/unit/manager/360, 440, t/unit/users/60."
---

# What was asked

A-3: "The Files page's 'Limited by address' becomes 'Limited by address profile':
one picker of profiles, each chosen as Allow or Deny, in place of the two
kind-filtered pickers."

# What shipped

- The permissions card's address block is headed **Limited by address profile**
  and has one row per profile in the store, each with a choice of Not used, Allow
  or Deny. SM1139's two multi-selects ("Only these addresses", which offered only
  allow lists, and "Never these", only deny lists) are gone: a profile has no kind
  (SM1343), so each row offers every choice.
- A profile the rule allows shows Allow and one it denies shows Deny. A name the
  rule carries that the store does not hold is listed too, keeps its choice and is
  marked "no such profile" (ruling 234: saving a rule that carries it is refused, naming it,
  until it is set to Not used). A name a hand
  edit both allows and denies shows Deny, which is what decides for it.
- Saving sends the rows chosen Allow as `addresses` and those chosen Deny as
  `addresses_deny`; a card whose only content is a profile is still an `acl-set`,
  and one with nothing chosen anywhere still clears the rule. The server side is
  unchanged (SM1139's fields, checked by the same save).
- **The Groups page (ruling 107)** has the same picker under the group's operator-only
  settings, in place of SM1140's two rows of ticks ("Only from" / "Never from").
- **One request, one write.** A change is one `group-settings-set` with the new key
  `address_limit`, whose value carries both lists (`{ addresses: [...],
  addresses_deny: [...] }`). The users tool validates both and writes the group store
  once, under the store lock its dispatcher holds across every mutating verb. Sent as
  two settings, a profile moved from Deny to Allow was in neither list for a
  round-trip, and a group whose only limit it was counted from every address in that
  time. A half-update (one list missing, or a value that is not both) is refused,
  naming what it needs; a bad name in either list refuses the whole change. The
  single keys `addresses` and `addresses_deny` remain for the CLI.

# Tests

t/unit/manager/360, through the page's own JavaScript: the heading and the absence
of the old pickers, a row per profile, Allow / Deny / Not used shown from the rule,
a missing name kept and marked, both-slots shown as Deny, the read-back into the two
fields, and the save. On the old page it fails at the first subtest (no
`addressRows`). t/unit/manager/440 drives the Groups page the same way: rows,
choices, read-back, the one request carrying both lists, and a refusal; on the old
page it dies at the first extraction (no `groupAddressRows`). t/unit/users/60 holds
the server half: a Deny -> Allow move is one write of groups-settings.json and no
state of the store (each rename is snapshotted by a spy loaded into the tool) has the
profile in neither list; a half-update and a bad name are refused and change nothing;
it is the operator's. Sabotage: writing each list in its own write fails the one-write
test; accepting a half-update fails the refusal test; the page's earlier two-request
save fails 440.
