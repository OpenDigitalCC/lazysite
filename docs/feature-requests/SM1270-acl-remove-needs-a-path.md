---
id: SM1270
title: "SM1270: acl-remove needs a path"
subtitle: "The control API's acl-remove with no path, or an empty one, removed the site-wide rule and published everything it held back. It is refused now, saying the site-wide rule is removed with path=/. This replaces SM306's no-path default."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "the release manager, ruling 17 (tmp/rulings-2026-10-22.md, \"23 October\"), on SM1263's open question"
area: access
status-note: "SHIPPED (0.16.3) on n731: the control API refuses acl-remove with an absent or empty path before the scope check, and Files::action_acl_remove refuses it for every caller, both naming path=/; the action declares path required, as MCP remove_permissions does; lints 52 and 265 no longer record a difference. t/unit/manager/401, t/integration/52."
---

# What was asked

Ruling 17 (2026-10-23): "The control API `acl-remove` (and `lazysite acl remove`)
refuses a call with no path; removing the site-wide rule takes `path=/`. This
replaces SM306's no-path default."

The control API's dispatcher defaults `path` to `/` for every action, and `''` is one
of SM287's spellings of the root. So `acl-remove` with no path, or with `path=`, took
off the site-wide rule. SM306 kept that on purpose: un-protecting the root is what
recovering a site looks like. SM1263 asked the release manager to look at it again
when MCP's `remove_permissions` was made to require its path. The ruling took the
other side: a script that drops its argument publishes everything a site-wide rule
held back.

# What shipped

- **The control API refuses it.** `_refuse_unread_or_missing_path` in
  `lazysite-manager-api.pl` refuses `acl-remove` with an absent or empty `path`, on the
  cookie and token channels and for the operator. It runs before the scope check, so a
  confined caller is told the path is missing, not that `/` is outside its scope. The
  refusal is `kind: missing-parameter`, `field: path`, and says that the site-wide rule
  is removed with `path=/`. Nothing is changed, and the refusal is audited, as every
  refusal is.
- **The handler refuses it as well.** `Lazysite::Manager::Files::action_acl_remove`
  refuses an undefined or empty path with the same message
  (`acl_remove_needs_a_path`). The control API branch passes the path as it was sent,
  not the dispatcher's `/`, so the handler's refusal stands behind the dispatcher's. MCP
  `remove_permissions` calls the same function, and its schema still requires `path`.
- **The declaration says so.** `acl-remove`'s `path` is `required => 1` in
  `Lazysite::ControlApi::Actions`, with a note that `path=/` removes the site-wide rule.
  It now agrees with `remove_permissions`.
- **`lazysite acl remove`** already refused a missing PATH. Its message now says that
  the site-wide rule is removed with `/` as the PATH.
- `/`, `.` and `./` still remove the site-wide rule, so a rule stored under any of
  SM287's spellings can still be taken off. The manager never sends an empty path: its
  root banner is hidden, and the protected-sections list names the root `/`.

# Tests

- **t/unit/manager/401** (new): the handler refuses no path and an empty path
  (missing-parameter, field path, the message names `path=/`), and the site-wide rule
  stays. `/`, `.` and `./` each remove it.
- **t/integration/52**: SM306's "recovery stays at least as easy as the mistake"
  subtest is replaced. Through the real CGI, `action=acl-remove` and
  `action=acl-remove&path=` are refused, naming `path=/`, and the root rule is still
  there. `action=acl-remove&path=/` removes it (`removed: 1`).
- **t/lint/52**: the `acl-remove` exemption is gone. A direct subtest asserts the
  dispatcher's refusal, the branch passing `$params{path}`, and the handler's refusal.
- **t/lint/265**: the recorded `acl-remove` difference is gone, and the two surfaces
  agree.

With the three code files put back to main, t/unit/manager/401 fails 12 of 22, t/integration/52
fails 2 subtests, t/lint/52 fails its new subtest, and t/lint/265 fails on
`acl-remove`.

# Not done

- **No behavioural test for a confined caller.** The order (the refusal before the
  scope check) is asserted by t/lint/52 from the source. No test runs a scoped token
  with no path.
- The SM306 filing has a note that ruling 17 replaces its `acl-remove` half. Its
  `acl-set` half stands.
