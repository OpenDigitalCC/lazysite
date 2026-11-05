---
title: "Address profiles"
brand: plain
---

# Address profiles

Governing capability: `manage_users` to read; the operator to change.

## Create and edit a profile

Where
: Access -> Address profiles

Do
: As the operator, choose New profile, name it (`office`), add a range
  (`203.0.113.0/24`) and a single address with notes, and save. Edit it, remove
  an entry, save again; then delete the profile.

Expect
: The profile appears with its entry count and its entries and notes, and no
  allow or deny of its own: that is chosen where a rule names it. Each save and
  delete is in the audit log, naming the profile and the addresses added or
  removed. An entry that is not an address or a range (`banana`, `10.0.0.0/33`,
  `0.0.0.0/0`) is refused by name and nothing is saved.

Negative
: An account with `manage_users` who is not the operator sees the profiles and
  no New, Edit or Delete controls, and a direct request to change one is refused
  with "Only the operator changes address profiles". An account without
  `manage_users` is refused the page's data with the capability named.

## One profile, allowed in one place and denied in another

Where
: Files -> a page's permissions card, Limited by address profile

Do
: Choose Allow for `office` on one page and Deny for `office` on another, and
  save each.

Expect
: The first page is served only to an address in `office`; the second is
  refused to one. Neither save is refused: a profile has no kind.

## A profile in use is not deleted by accident

Where
: Access -> Address profiles

Do
: Delete a profile that a page or rule still names.

Expect
: The delete is refused, naming where the profile is used. Delete anyway asks a
  second time and then deletes it; the audit row names what still refers to it.

## A profile store that cannot be read

Where
: Access -> Address profiles

Do
: Damage `lazysite/auth/address-profiles.json` (truncate it) and open the page.

Expect
: The page says the store does not decode and that every rule naming an address
  profile refuses until it is repaired; it does not show an empty table.

Negative
: Saving a profile while the store is broken is refused rather than written
  over the other profiles.
