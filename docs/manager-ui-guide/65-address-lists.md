---
title: "Address lists"
brand: plain
---

# Address lists

Governing capability: `manage_users` to read; the operator to change.

## Create and edit a list

Where
: Access -> Address lists

Do
: As the operator, choose New list, name it (`office`), choose allow, add a range
  (`203.0.113.0/24`) and a single address with notes, and save. Edit it, remove
  an entry, save again; then delete the list.

Expect
: The list appears with its kind, its entry count and its entries and notes.
  Each save and delete is in the audit log, naming the list and the addresses
  added or removed. An entry that is not an address or a range (`banana`,
  `10.0.0.0/33`, `0.0.0.0/0`) is refused by name and nothing is saved.

Negative
: An account with `manage_users` who is not the operator sees the lists and no
  New, Edit or Delete controls, and a direct request to change one is refused
  with "Only the operator changes address lists". An account without
  `manage_users` is refused the page's data with the capability named.

## A list that cannot be read

Where
: Access -> Address lists

Do
: Damage `lazysite/auth/address-lists.json` (truncate it) and open the page.

Expect
: The page says the store does not decode and that every rule naming an address
  list refuses until it is repaired; it does not show an empty table.

Negative
: Saving a list while the store is broken is refused rather than written over
  the other lists.
