---
id: SM983
title: "SM983: approving an account request read every account's full settings"
subtitle: "The name and address check behind form-submission-approve asked for users-detail, which took 43 s for 695 accounts, so the browser gave up before the approval answered."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-11
raised-by: the dev inbox (2026-10-11, a local 0.15.3 site of 695 imported accounts); WORK-PLAN-0154 P4
area: performance
status-note: "SHIPPED (0.15.5): the approval asks users-detail for fields [email] only, answered from the settings store in one read: 0.27 s for 700 generated accounts, from 26.7 s (t/unit/users/50, t/unit/manager/240)."
---

# What was wrong

`form-submission-approve` checks that the name and the address it is about to
use are free. It asked the users tool for `users-detail`, which derives every
account's effective settings afresh - groups, capabilities, domain scopes, the
seeding check - at about 40-60 ms an account. The reporting site, 695
accounts, measured 42.8 s of CPU for the call and 44.6 s for the approval; the
page's fetch failed first. The check reads one field of it: the address.

Reproduced over a generated store of 700 accounts (no network): `users-detail`
26.7-28.4 s, 745 KB.

# The fix

`users-detail` takes `fields`, a list naming the stored settings the caller
needs. Only `email` can be named; anything else is refused by name. The answer
lists every account with `settings: {email}` and nothing derived, read from the
settings store once, and refuses if the store could not be read. Without
`fields` the answer is the full one, unchanged.

The approval asks `fields: ["email"]`, and now also refuses on an answer that
says the account store could not be read (`store_readable: false`), where an
empty list is not a list of free names.

Measured on the same generated store: 0.27 s, 48 KB.

# Not done here

The Users page (`users-page`) derives the same full settings per account and
costs the same on a large site. It needs every derived field it draws, so the
narrow read does not apply; making the derivation itself cheaper is a separate
item.

# Tests

- t/unit/users/50: the narrow answer carries only the address, refuses any
  other field, and the full answer is unchanged.
- t/unit/manager/240: the approval asks for the one field, still refuses a
  taken name or address on the narrow answer, and creates nothing on an
  unreadable store.
