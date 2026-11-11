---
id: SM1440
title: "SM1440: a refusal names the user to run as, and check says ok only about what it read"
subtitle: "The 0.16.11 field pass found that on a Hestia host no unix user could run acl set: root is refused by design, the login user cannot read the auth store, and neither refusal named the user that can. It also found an ok line printed after the warning that its store was unread."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-11
raised-by: "the 0.16.11 edge field pass (O-1, O-3, O-4, O-5, O-6 of the test plan results), built by the lazysite developer agent on n818"
area: reliability
status-note: "SHIPPED (0.16.12): a root refusal names the auth store's owner and spells the command with it; a command that cannot read a store names the user it ran as and the owner; check prints no ok about a store it did not read; the --fix hint shows only when --fix has a repair; a missing group is named before a missing profile. t/tools/630-633."
---

# What happened

On edge, `lazysite acl set` had no unix user that worked from the documented routes. As root it
refused by design ("Run it as the site user instead: sudo -u SITEUSER"), a placeholder. As the
login user (ispadmin) it could not read `lazysite/auth/acls.json` and said only "a fault on the
host". Only the user the CGI runs as, which owns the auth store (www-data), reached the profile
refusal. `address-profile-delete` said "Repair the file and retry" with no user. The same pass
found the check printing "every rule names its address profile in the slot its old list's kind
meant" straight after warning that acls.json could not be read, a "re-run with --fix" hint on a
run where `--fix` had nothing to change, and a limit set on a group that does not exist refused
as a missing profile.

# The change

- The root refusals of `lazysite acl` and the handlers tool name the owner of
  `lazysite/auth/acls.json` (its directory when the file does not stat) and spell the command with
  it.
- One helper, `Lazysite::Util::unreadable_note`, says which unix user a run was, which user owns
  the file, and to run the command as that user. It is empty when the file opens. `acl set` (the
  write refusal for a store that cannot be read) and the address-profile refusals (the users tool,
  the manager's profile list, the manager's address-limit setting) use it. "Nothing was changed"
  stays.
- The check's two address ok lines (every profile a rule names is in the store; every rule names
  its profile in the slot its old list's kind meant) say they could not check when any store they
  read was unreadable, naming the file, the user and the owner, as SM1437 does for pages.
- The summary offers `--fix` only when the run queued a repair `--fix` applies.
- `group-settings-set` with `addresses`, `addresses_deny` or `address_limit` looks the group up
  before its profiles: a group with no settings record and no members is refused as not existing,
  and nothing is written.

# Test

`t/tools/630` to `633`; each fails on the code before this change.
