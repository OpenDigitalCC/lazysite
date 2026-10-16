---
id: SM991
title: "SM991: manage_users passed every capability gate on the manager"
subtitle: "A group made to manage accounts was also the operator: config-set, every manager action. The operator is now a member of the operator group, manage_users is user and group management, and the operator's account and group are the operator's."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: SM979's report, left there for a ruling (manage_users passing the manager's capability gates, config-set measured 200)
area: security
status-note: "SHIPPED (0.15.5): ruled 2026-10-12. The operator is a member of the group carrying the manager flag (setup-sysop's sysops) and passes every gate and file rule. manage_users is user and group management; it cannot change the operator's account or group, or revoke its sessions or access keys. t/integration/128, 131."
---

# What was wrong

SM979 found, and left for a ruling, that a session holding only `manage_users`
passed every capability gate on the manager's cookie channel: `config-set`
answered 200 for the group the members' area had made to approve account
requests. `Lazysite::Auth::Acl::_is_operator` answered yes for any holder of
`manage_users` (the store, or a trusted X-Remote-Groups header), and the
manager API skips its whole capability gate for the operator
(`lazysite-manager-api.pl`, the `!_operator()` block). SM979 had already taken
the file-rule bypass away from the same test (`file_rule_bypass`), so the
operator - the site owner - was bound by every file rule too.

# The ruling

Release manager, 2026-10-12, SM979 revised, "Operators bypass, others bound",
and Finding 1, "do 1, and add an explicit operator group":

manage_users stops implying every capability - it grants user and group
management only (a manage_users-only session must NOT pass config-set etc.).
Add an EXPLICIT operator group concept (decide the cleanest mechanism from the
code: e.g. a group setting `operator: true` in groups-settings, or a reserved
capability `operator`; existing installs: the group(s) the bootstrap created as
the manager/sysop group become the operator group on upgrade so no live site
loses its operator - prove with an upgrade test). Members of the operator
group: pass every capability gate AND bypass file rules (as manage_users did
before SM979). Everyone else - manage_users, approve_accounts, all others - is
bound by file rules (keep n380's binding for them). local (CLI) and an
unsecured site keep bypassing as in n380. Tokens never count as the operator
(as n380). group-reach reports the operator group and what manage_users now
grants. Docs and the capability map. Behaviour change in CHANGELOG (PENDING).
Test the reported cases: manage_users-only session refused config-set and
refused writing outside its rules; operator-group member does both; upgrade
keeps the existing sysop group as operator. Sabotage.

# The mechanism: the `manager` flag is the operator group

The code already had an explicit operator group: the `manager` flag on a group
in `groups-settings.json`. `setup-sysop` writes it on the group it makes
(`sysops` by default, labelled "Site operator", described as "The site
owner"); the legacy `manager_groups` conf migration writes it; the
`lazysite-admins` -> `sysops` rename carries it. Only `local` may set it
(`cmd_group_settings_set`: "Only a sysop may make a group a manager group"),
and only `local` may put anyone in such a group or nest a group in it, because
the SM195 ceiling walks `manager` with the capabilities
(`_caps_granted_by_group_attributed`) and no delegate may confer it. The last
one cannot be unflagged or deleted, and every manager group is topped up with
every capability. A new `operator: true` key or an `operator` capability would
be a second declaration of the same fact, and a migration to keep the two
equal; a reserved capability would also enter every capability table, grid
and lint. So the flag is the operator group, and nothing migrates:

- `Lazysite::Auth::Settings::groups_are_operator`, `account_is_operator`,
  `operator_groups` - the flag, over the nesting closure (SM121), as
  capabilities are read.
- `Acl::_is_operator` asks `account_is_operator` (the store) and then the
  trusted X-Remote-Groups header (SM268 02-7's order), where it asked for
  `manage_users`. `local`, an unsecured site and the token rule are unchanged.
- `Acl::file_rule_bypass` is `_is_operator` again: the operator passes a
  file's rule, `local` and an unsecured site as in n380, a token never. Every
  manager file action, acl-set and acl-remove ask it (SM979's call sites).
- `Manager::Data::table_rule_refusal` already asked `_is_operator`, so a table's
  rule now binds a `manage_users` holder and not the operator.
- `may_read_any_rule` keeps SM464's grant: a cookie holder of `manage_users`
  still reads any rule, by name, now that it is not the operator.

## The upgrade

`t/integration/128` writes, as its fixture, the two group stores main's own
`setup-sysop --user boss` wrote (b5ab1ce4, run from `git archive main`;
`tmp/sec-evidence/sm991-upgrade-fixture.out`). On the new code, with nothing
migrated, `boss` passes `config-set`, writes a file the site-wide rule does
not name and overwrites an author's post - and passes `config-set` with
`manage_config` switched off on `sysops`, so it is the operator test that
admits it and not the group's capabilities.

## What manage_users is now

User and group management, unconfined as before: the Users and Groups pages,
every account (a holder still manages accounts it did not create - the actor
is not injected for it, `Manager::Users`), account approval. It passes no
other capability gate and a file's rule binds it.

Found while building, and closed under the same ruling: with the operator no
longer "whoever holds manage_users", a holder that could change the
operator's account or the operator group would make itself the operator in
one call - reset the operator's password, mint it a setup link or a
credential, or join the group. Joining was already refused by the ceiling; the
rest was not. `Manager::Users::_operator_target_refusal` refuses a caller who is
not the operator any users-tool verb that changes an account that is the
operator (`username`) or a group whose membership makes one (`group`, a
nest's `sub` and `parent`); reads are untouched. The operator itself, and
`local`, are not asked.

# Behaviour changes

- A holder of `manage_users` (the shipped `user-managers` role, or a group made
  to approve accounts) no longer passes the manager's capability gates: an
  action needs its own capability (`config-set` needs `manage_config`). It
  cannot change the operator's account or the operator group, nor revoke the
  operator's sessions or access keys (session-revoke, user-revoke,
  key-revoke); it still revokes every other account's.
- A member of the operator group passes every capability gate and every file
  rule on the manager's cookie channel - including a capability its group has
  switched off. Before SM979 that was every `manage_users` holder; between
  SM979 and this, nobody but `local`.
- A table's rule binds a `manage_users` holder that is not the operator.
- An identity known only from a trusted X-Remote-Groups header (SSO) is the
  operator when a named group carries the `manager` flag, no longer when it
  grants `manage_users`; such an identity holds no store capabilities, so a
  header-only `manage_users` group now reaches nothing on the manager
  (t/unit/manager/16's fixture names its operator group by the flag).

# Evidence

t/integration/128 (run against n383 first: 23 assertions fail,
`tmp/sec-evidence/sm991-t128.base.out`; all pass after), t/integration/124's
group-reach assertion, t/integration/127's operator (now a member of the
operator group), t/unit/manager/16, 35, 48, 159 and t/unit/users/25 (their
operator fixtures name the operator group by the flag). Sabotage: 11 cases
(`tmp/sec-evidence/sm991-sab*.out`), each bit; the first run found the store
half of the operator test unasserted (the header carried it), and a call with
no groups header was added.

# The operator's sessions and keys (ruled 2026-10-12)

Left open by the build above: the Sessions page's revokes did not ask the
operator rule, so a `manage_users` holder could sign the operator out
everywhere, sign out one of its sessions, or strip its OAuth grants, and do it
again whenever it signed back in.

Release manager, 2026-10-12, "Yes, protect operator sessions too": only the
operator can revoke an operator's sessions or access keys; `manage_users` still
manages everyone else's. Built on n387.

## The revoke paths

| Ref | Path | Reaches | Before | Now |
|---|---|---|---|---|
| R1 | manager API `session-revoke` (Sessions page, cookie only) | the account(s) the session registry records for the sid | any `manage_users` holder | operator rule |
| R2 | manager API `user-revoke` (cookie only) | the username, cleaned | any `manage_users` holder | operator rule |
| R3 | manager API `key-revoke` (cookie only) | the username: a key account's credential and OAuth grants, an interactive account's OAuth grants | any `manage_users` holder | operator rule |
| R4 | manager API `users` with `key-revoke`, `token-rotate`, `claim-create` (reset), `account-disable`, `passwd` | the username | operator rule (SM991) | unchanged |
| R5 | auth CGI logout (`action_session_revoke` on the caller's own sid) | the caller | itself | unchanged |
| R6 | `lazysite-users user-key-revoke` (CLI) | the username | `local` | unchanged |
| R7 | scheduler `sessions_sweep` | expired registry rows only | `manage_users` job account | unchanged: revokes nothing live |
| R8 | `rotate-auth-secret` (`manage_config`, cookie only) | every session on the site, the operator's included | `manage_config` | unchanged - for a ruling |

MCP has no revoke tool, and the control API refuses R1-R3 to every token
(`caps => undef` in `Lazysite::ControlApi::Actions`). R8 targets no account, so
it is outside the ruling as worded; it is listed so it can be ruled on.

## The fix

`Manager::Sessions::_revoke_target_refusal`, asked by `dispatch_sessions_keys`
after the `manage_users` gate, hands the account each revoke reaches to
`Manager::Users::_operator_target_refusal` - the one rule the users-tool verbs
ask - for a caller that is neither `local` nor the operator:

- `user-revoke`: the username cleaned by `_clean_username`, which
  `action_user_revoke` now also uses, so the account checked is the account
  signed out (`bo!ss` is `boss`).
- `key-revoke`: the username as the users tool receives it.
- `session-revoke`: every account the registry records for the sid. A sid in
  the right shape the registry does not hold cannot be placed and may be the
  operator's (the registry is advisory), so a non-operator is refused it - fail
  closed. A malformed sid or an empty name meets the action's own refusal.

## Evidence

t/integration/131 (run on n386 first: 14 assertions fail,
`tmp/sm991b-t131.base.out` in the n387 worktree; all pass after): a
`manage_users`-only account is refused each revoke of the operator's (and a
second operator's) session, sign-out and key, with revoked.json and oauth.json
read back; it still revokes a non-operator's session, sign-out and key and its
own session; the operator revokes another operator's, a non-operator's, its own
and an unplaced sid. Sabotage: 7 cases (backups in `tmp/sab-bak/sm991b/`,
restored by cp, checked by cmp) - the dispatch never asking, the operator
bypass dropped, an unplaced sid let through, the name not cleaned, the registry
lookup finding nothing, key-revoke's target not asked, and the rule ignoring an
operator account - each bit.
