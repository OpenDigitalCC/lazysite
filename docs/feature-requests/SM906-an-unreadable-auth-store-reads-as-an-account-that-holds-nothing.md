---
id: SM906
title: "SM906: an unreadable auth store reads as an account that holds nothing, and four surfaces said so"
subtitle: "On a new 0.14.4 install the CGI user could not read lazysite/auth/groups-settings.json - the one file recording what each group grants. caps_for resolved to zero for everybody, and the engine reported that as facts about the ACCOUNT: an empty capability grid, group labels falling back to technical names, backend groups offered as assignable, and `account-create` refusing about a capability the account held. `lazysite check` was silent, because the file that decides capabilities was the one auth store missing from its list."
brand: plain
standard-margins: true
status: partial
status-note: "RULED 2026-09-29: THE CONTROL API GETS A DISTINCT CANNOT-TELL STATE, not an empty capability list - and the manager's wording alongside it. Raised by the field on the 0.15.0 edge walk (T3, SPLIT): with groups-settings.json unreadable, whoami reported 0 of 28 capabilities and a gated call told an account HOLDING the api capability to ask the operator to grant it, while the manager in the same window named the file, the fault, the cost and a repair. SM906 landed on one surface. THE REASON FOR THE SHAPE: the caller on this channel is a PROGRAM, so I hold nothing and I could not read the store must be different VALUES and not the same empty list - the four-state rule the engine already applies to its stores, and the same distinction Lazysite::Auth::Settings::settings_readable exists to carry. A client that cannot branch on it will keep reading an unreadable store as a revoked grant, which is the failure the field met. The manager's sentence goes in the message too, so a human reading the log gets the repair without having to open the other surface. NOT BUILT YET. PREVIOUSLY: SHIPPED 2026-09-27 for 0.15.0. REPRODUCED FIRST, twice: a fresh site built by setup-sysop where the CLI works and the store is provably correct (29 capabilities on `sysops`, ada a member, effective_groups resolving), and then the same site with groups-settings.json chmod 000, which reproduces the operator's refusal verbatim - \"Creator 'ada' lacks create_sub_users permission\" - with caps_for reporting zero held. THREE FIXES, one cause. (1) lazysite check now lists groups-settings.json in both the CGI-readable set, beside user-settings.json which has been there since SM141, and the CGI-writable set, because the manager saves it. Had it been there the check an operator runs to find exactly this fault would have named it. (2) read_group_settings distinguishes an ABSENT store from one that exists and will not open - `group_settings_unreadable` - and account-create says which of the two it is, naming the file, the fault class and the command that repairs it, instead of making a statement about the account. An ordinary refusal is unchanged and asserted to be. (3) The manager group carried `label => $group`, so it displayed as `sysops` while every group seeded beside it had a descriptive one; it is 'Site operator' now, and the existing-record top-up heals a label that merely repeats the name, on the same reasoning the capability top-up uses - a label equal to the group name is indistinguishable from never having been given one, so fixing it takes nothing from an operator who chose one and repairs installs on upgrade. THE OPERATOR'S HOST WAS FIXED BY THE PERMISSION ALONE, which confirms the cause; the label was the only half that was ever about naming. t/tools/88 covers all three plus the two silences - the plain refusal survives, and a store that read fine is never blamed."
raised: 2026-09-27
raised-by: release manager (new 0.14.4 install)
area: auth, diagnostics
---

# What was reported

A new install. The capability grid showed every cell empty. The sysop could not
create sub-users. Group names appeared as `cap-analytics`, `ch-ui`, `sysops` in
the Add User dropdown and in users' group memberships, while the Groups page
showed them correctly. And the sysop could not add themselves to a group that
could add users.

Four symptoms that read as four defects. They were one.

# What was measured, before anything was changed

**The store was correct.** A fresh site built by `setup-sysop --user ada`:
`sysops` carries `manager=yes` and twenty-nine capabilities including
`create_sub_users`, `manage_users`, `ui` and `webdav`; the groups file has ada in
it; `effective_groups('ada')` returns `sysops`; `caps_for('ada')` returns
twenty-six held. `account-create bob --by ada` succeeds, exit 0.

The release manager's own permissions dump agreed, capability by capability, each
attributed to `sysops`.

**So the grant was never the problem.** The absence of `api` and `mcp` from that
list is deliberate - SM127 keeps manager groups off the remote channels - so two
of the four grid columns being empty is by design.

**Then the same site with the store unreadable.** `chmod 000` on
`lazysite/auth/groups-settings.json` reproduces the operator's sentence verbatim:

    Creator 'ada' lacks create_sub_users permission

with `caps_for('ada')` reporting zero capabilities held, and this in the log:

    cannot read groups-settings.json - it exists and this process cannot open it
      error=Permission denied unix_user=...

One unreadable file, four wrong sentences, and the only true one was in the log
where nobody reading a refusal would look.

# Why all four symptoms follow

`caps_for` builds from the group settings. With the store unreadable it resolves
to nothing, and nothing is indistinguishable from "this account holds no
capabilities". So:

- the grid renders every cell empty, correctly reporting what it was told;
- the picker's metadata is empty, so labels fall back to the group's own name;
- the same fallback defaults `assignable` to true, so the backend `cap-` and
  `ch-` groups are offered when the server would refuse them;
- and the create path reports a statement about the account.

The Groups page reads the settings directly rather than through that metadata,
which is why it alone looked right - and that contrast is what made the whole
thing read as a naming bug.

# The three fixes

| Ref | What changed |
| --- | --- |
| D1 | `lazysite check` lists `groups-settings.json` in the CGI-readable set, beside `user-settings.json`, and in the CGI-writable set, because the manager saves it. It checked `users`, `groups` and `acls.json` in the same directory for this exact fault and omitted the one that decides capabilities |
| D2 | `read_group_settings` tells an absent store from an unopenable one, and `account-create` says which, naming the file and the repair rather than making a claim about the account |
| D3 | The manager group gets the label `Site operator` instead of its own name, on creation and by healing an existing record whose label merely repeats the name |

# What is NOT fixed here, and why

**The manager page's fallbacks.** When group metadata is absent the Users page
still falls back to the raw name and to `assignable: true`. With D1 and D2 in
place the cause is now diagnosable and the refusal now truthful, so the page's
behaviour is no longer the thing that hides a permissions fault. Changing a
security-adjacent picker's default wants its own pass rather than riding this
one: the server-side `group_is_assignable` already answers correctly, and the
page's default only applies when a group is missing from the payload entirely,
which happens when the store could not be read at all.

Filed as the remaining work rather than left unsaid.

# Related

[[SM800]] (the fourth state travelling with the users payload as
`store_readable` - the precedent this follows), [[SM770]] (no stat guard in front
of a store read, the same distinction one level down), [[SM873]] (a refusal that
could not reach its status, the same class), [[SM127]] (why a manager group holds
no `api` or `mcp`), [[feedback_a_boolean_has_four_states]].
