---
id: SM958
title: "SM958: A token-gated action was open to any manager account"
subtitle: "An action without a %COOKIE_CAP line had no capability check on the manager channel: a manager without manage_forms could turn file uploads on for a public form."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-07
raised-by: the developer agent, found by the SM943 survey of the action tables
area: security
status-note: "SHIPPED (PENDING): on the manager channel an action with a token gate and no %COOKIE_CAP line now needs the token gate's capability; four actions that decide for themselves are listed with reasons. Found by the SM943 survey. t/unit/manager/138 drives it; lints 14 and 87 now read `a+b` values and `_` names."
---

# What was wrong

On the manager (cookie) channel a non-operator account was capability-checked
only for actions listed in `%COOKIE_CAP` (`lazysite-manager-api.pl`). An action
added with a token gate in `ControlApi/Actions.pm` but no `%COOKIE_CAP` line
had no capability check there at all.

Measured on the tree of 2026-10-07 (n256): 15 actions were in that state. Three
WRITE:

| Action | Token gate | Shipped |
| --- | --- | --- |
| `form-uploads-save` | manage_forms | 0.15.x (baaec983, 2026-09-28) |
| `form-notify-save` | manage_forms | 0.15.2 (SM938 D4) |
| `regenerate-registries` | manage_content | earlier |

The other twelve read: `aliases-list`, `artifact-manifest`, `artifact-validate`,
`layouts-available`, `layouts-manifest`, `nav-read`, `notices` (also gated by its
own branch), `pages`, `preview-public`, `theme-list`, `themes-for-layout`,
`themes-list-all`.

**Impact.** Any account that can sign in to the manager - a member of a group
with the `ui` capability, a trusted population - could turn file uploads on for a
public form, change what a form announces, and regenerate the registries,
without the capability those actions name. Token (API/MCP) clients were never
affected: their gate is `%GATE`.

**Why nothing caught it.** Lint 14 counts an action as "classified" when it is in
the token gate, so a missing cookie line passed. Its `%COOKIE_CAP` parser also
dropped every `a+b` value and every name with an underscore, so the cross-channel
parity check never saw five entries.

# The fix

- On the cookie channel, `%COOKIE_CAP` still wins where it says something; where
  it says nothing, the token gate's capabilities apply (any of). A new action is
  therefore gated on both channels by its one `%GATE` line.
- `%COOKIE_GATES_ITSELF` names the four that decide for themselves, each with
  its reason: `acl-get`, `acl-set`, `acl-remove` (owner-checked; `manage_users`
  reads any rule, SM464) and `audit` (a scoped view for `create_sub_users`,
  SM173).
- Lints 14 and 87 read `a+b` values and `_` names. Lint 14 then reported the two
  submission deletes, whose channels differ on purpose (manager:
  `manage_forms+read_submissions`, SM660; token: `delete_submissions`); they are
  listed in its `%ALLOW_DIVERGENCE` with that reason.

# Evidence

t/unit/manager/138 drives the gate by behaviour: both form writers refused
without `manage_forms` and reached with it; `regenerate-registries` refused
without `manage_content`; `acl-set` reaches its own ownership check. With the
fallback removed the first two subtests fail. All 364 manager and integration
test files pass.

# Related

[[SM943]] (one declaration per action - the structural end of this),
[[SM660]], [[SM669]].
