---
id: SM1044
title: "SM1044: a member reads the notices addressed to them, on /account"
subtitle: "SM1034 phase 1b, answering SM1010 R2. The per-member bell had a reader filtered by addressee and no door a member could reach."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: SM1034 phase 1b (SM1010 R2), ruled "Accept, build phase 1" by the release manager 2026-10-12
area: accounts
status-note: "SHIPPED (0.15.5): me-notices and me-notices-seen (self, cookie-only, no capability) over the one notice reader with addressed_only - the account's own notices in a window of its own, never a broadcast; ::: account-bell on /account. t/unit/account/03."
---

# What was wrong

SM1010 R2 (A): a notification rule rings the bell for each account it names
(`Notify::bell_for`), and the reader shows an addressed notice only to its
addressee (`_for_principal`) - but the reader's door is `notifications`, an
operator capability. A member could not read their own bell, and a member who
held `notifications` would also have seen every broadcast. The reader's window
was the store's last 100 lines, shared with every other account.

# What was built

- `Lazysite::Manager::Notices::_read_notices_addressed`: the notices whose `to`
  is exactly the account (not a login that merely contains it), read from the
  whole store and bounded to the account's own last 100, with the same ids the
  shared reader gives. `action_notices` and `action_notices_seen` take
  `addressed_only`; the operators' path is unchanged.
- `me-notices` and `me-notices-seen` (`Lazysite::Manager::Account`), declared
  `self` like the rest of the family: the caller's notices only, mark one read,
  dismiss one, or mark all read. Another account's notice id is not found.
- `::: account-bell` on `/account`; the script links a notice's `url` only when
  it is a site path or http(s).

# Tests and sabotage

`t/unit/account/03`: alice sees exactly her three (not the broadcast, not bob's,
not alice2's), including one 150 other notices older; she cannot mark bob's;
read, dismiss and mark-all work and leave bob's state alone; the operators'
`notices` still refuses her. Sabotaged (a substring match for the addressee,
the shared reader, a window of two) - each fails.
