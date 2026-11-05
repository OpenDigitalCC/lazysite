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
status-note: "SHIPPED (0.16.5) on n750: starter/manager/files.md addressRows / addressBlock / chosenAddresses, starter/manager/groups.md groupAddressRows / chosenGroupAddresses / setGroupAddresses; t/unit/manager/360, 440."
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
  marked "no such profile yet", so saving the card does not drop it. A name a hand
  edit both allows and denies shows Deny, which is what decides for it.
- Saving sends the rows chosen Allow as `addresses` and those chosen Deny as
  `addresses_deny`; a card whose only content is a profile is still an `acl-set`,
  and one with nothing chosen anywhere still clears the rule. The server side is
  unchanged (SM1139's fields, checked by the same save).
- **The Groups page (ruling 107)** has the same picker under the group's operator-only
  settings, in place of SM1140's two rows of ticks ("Only from" / "Never from"). A
  change sends both settings (`addresses_deny` first, so a profile moved to Deny is
  refused before it leaves Allow, then `addresses`); a refusal of the first stops the
  second and reloads what the server holds.

# Tests

t/unit/manager/360, through the page's own JavaScript: the heading and the absence
of the old pickers, a row per profile, Allow / Deny / Not used shown from the rule,
a missing name kept and marked, both-slots shown as Deny, the read-back into the two
fields, and the save. On the old page it fails at the first subtest (no
`addressRows`). t/unit/manager/440 drives the Groups page the same way: rows,
choices, read-back, the two sends in order, and a refusal; on the old page it dies at
the first extraction (no `groupAddressRows`).
