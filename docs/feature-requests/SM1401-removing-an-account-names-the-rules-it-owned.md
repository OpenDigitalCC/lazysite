---
id: SM1401
title: "SM1401: removing an account names the rules it owned"
subtitle: "Triage T-91: lazysite-users.pl remove left the account's access rules with an owner that is no account, and lazysite check did not name them. The remove command and the manager's account delete now say which rules and where; the check names a rule whose owner is no account, with the remedy."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "0.16.7 edge triage, T-91"
area: auth
status-note: "SHIPPED (PENDING) on n771: cmd_remove names the rules the account owned (paths, the store, the remedy) on the command line and in the API's remove answer (orphaned_rules, message - the Users page shows it); lazysite check report_rules_without_an_owner warns per stored rule whose owner is no account, local counting as one. No rule is changed. t/unit/users/73, t/tools/336."
---

# What happened

An access rule in `lazysite/auth/acls.json` carries its owner's login. When
the account was removed (`lazysite-users.pl remove`, or the manager's account
delete, which is the same tool's `remove` over its API) the rule kept the
login: in force as written, and - since a rule's writer must be its owner or
an operator - changeable by the operator alone. The remove answered "User
removed" and `lazysite check` said nothing, so the operator learned of the
rule only when somebody met it. A token cannot clear such a rule by design:
`Acl::_is_operator` answers 0 under token auth, so an agent that sets rules is
never an operator.

# What was built

- `tools/lazysite-users.pl cmd_remove`: after the account, its groups and its
  settings are gone, the rules whose owner is the login are read from the
  store (`Lazysite::Auth::Acl::load_acls`, the one decoder) and named, as
  paths, with the store they are in and the remedy; a WARN is logged. The
  command line prints it after "User 'x' removed."; the API's `remove` answers
  `orphaned_rules` (the paths) and the same sentence in `message`, which the
  manager's Users page shows when there are any. An account that owned no rule
  is removed with the sentence it always had.
- `lazysite check` (`report_rules_without_an_owner`): a WARN per stored rule
  whose owner is no account in `lazysite/auth/users` (`local`, the host
  operator, counting as one), naming the path, the owner and the remedy.
  Nothing is changed, with or without `--fix`: whether the rule should stay is
  the operator's decision. A rule with no owner is not named (it is a shape
  the store allows).
- The remedy, on every door: remove the rule from the manager's Permissions
  (the Files page) as the operator, or re-own it with `lazysite acl set 'PATH'
  --owner ACCOUNT --actor local --docroot DOCROOT`; a token cannot.
- Not a behaviour change to the rule itself, as the triage asked.
- `/docs/auth` (the command list) and `docs/OPERATOR.md` say so.

Tests: `t/unit/users/73` (the command line names the two rules, their paths
and the remedy and changes none; an account with no rule is unchanged; the
API answers `orphaned_rules` and the message, and the Users page shows it) and
`t/tools/336` (one WARN for the orphan, none for a rule owned by an account,
by `local` or by nobody; nothing changed by the check or `--fix`; a removed
account's rule is named on the next run). Each fails with its part reverted.
