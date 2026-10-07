---
id: SM962
title: "SM962: account-approve creates a stripped username, then uses the unstripped one"
subtitle: "cmd_add silently strips invalid characters (jo+hn becomes john) while cmd_account_approve goes on with the original name for groups and the claim."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-07
raised-by: the developer agent, found while building SM858 (approve from a submission)
area: auth
status-note: "SHIPPED (PENDING) (n264). Reproduced: account-approve jo+hn created john, then failed its claim for jo+hn. cmd_add now refuses a name holding any character outside letters, digits, . _ - by name, before anything is written - so approve, add, setup-sysop and the Users API refuse it alike. t/unit/users/48, three sabotages."
---

# Reported

The users tool's `cmd_add` strips characters a username cannot hold
(`jo+hn` -> `john`), and `cmd_account_approve` then calls `cmd_group_add` and
`cmd_claim_create` with the UNstripped name. Through the CLI or the Users API an
approval with such a name may create `john` and then fail - or act on nothing -
for the group placement and the claim.

# Proposal

Refuse an invalid name by name before anything is created (as SM858's button
does), rather than stripping it in `cmd_add`. Reproduce first.

# Done when

account-approve with an invalid name creates nothing and says why; a test
asserts it.

# Reproduced (n264)

Through the real tool on a fresh site, before any change:
`lazysite-users.pl account-approve jo+hn` logged `[john] user added`, printed
`User 'john' added.`, then failed with "the account was created but User
'jo+hn' not found" - the claim was minted for a name that does not exist. The
store held `john:` with no credential and no link. Through the Users API with a
group flagged for registrations, the same: `{"ok":0,"user":"jo+hn","group":[],
"error":"the account was created but User 'jo+hn' not found"}`, `john` in the
store, the group join skipped (it also failed on `jo+hn`). setup-sysop had the
same shape - `add` stripped the name, `group-add` used the original.

# The fix

No caller relied on the stripping: every one went on with the name it passed
in. So `cmd_add` refuses instead, through one rule (`_username_fault`) that
names the first character it cannot hold and the set it can: "'jo+hn' cannot be
a username: '+' is not allowed in one (letters, digits, '.', '_' and '-' only) -
nothing was created". account-approve calls `cmd_add` before any group, setting
or claim is written, so the refusal reaches it with nothing behind it. SM858's
button refuses such a name itself first and is unchanged (t/unit/manager/200
passes as it was).

`cmd_rename` and `cmd_account_create` still strip with their own copy of the
class; they use the stripped name consistently afterwards, so they do not have
this defect, but they do rewrite a name silently. Not changed here.

# Evidence

t/unit/users/48: the CLI and the Users API refuse `jo+hn` by name and create no
account, no setting and no group membership; `add`, the API `add` (`jo hn`) and
`setup-sysop` refuse the same way; `jo.hn_s-2` is still accepted. Before the
fix 12 of its assertions failed. Sabotaged three ways: the strip restored (13
fail), the rule accepting every name (18 fail), and the rule refusing `.` (the
three accepted-name controls fail).
