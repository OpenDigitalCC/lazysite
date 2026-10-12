---
id: SM1051
title: "SM1051: a handler may belong to a domain"
subtitle: "A handler carries domain:, and then a partner confined to that domain creates, changes and deletes it and binds its forms to it; an instance handler stays out of a confined caller's reach."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: inbox 2026-10-12, what a site partner cannot do while building a site (P-4)
area: forms
status-note: "SHIPPED (PENDING): handler domain:; handler-save/-delete and their MCP twins ask the domain rule (no longer instance_wide); handler-list shows a confined caller the instance's and its own; forms bind those (t/integration/210)."
---

# The report and the ruling

P-4: creating handlers `store-comments` and `store-feedback` (type `table`) was
refused - `handler-save` is instance-wide and a domain-confined caller is
refused - so the partner could not bind its forms.

The release manager, 2026-10-12, in their words: "Domain-scoped handlers": a
handler may carry `domain:`; a confined caller may create/edit/delete handlers
bound to its own domains only (SM976 caller_may_reach_domain); forms on its
pages may use those or instance handlers it may read; instance handlers stay
operator-only (instance_wide unchanged for them).

# What was built

- **The record.** `domain` is a key every handler may carry (beside id, type,
  name, enabled): a host as `list_domains` names it, lower-cased, checked at
  save against the configured domains (the primary's handlers are the
  instance's, so the primary is not one). Absent is an instance handler, as
  every handler was.
- **Who may write it.** `Manager::Common::handler_reach_refusal`: for a
  domain-confined caller, the domain the record carries now and the one it will
  carry must each be one it reaches (`caller_may_reach_domain`); no domain is
  the instance's and is refused, so a confined caller cannot create an instance
  handler, take an instance handler or another domain's into its own, or turn
  its own into an instance handler. Unconfined callers are not asked. The
  destination capability (SM842) is unchanged and still applies.
- **handler-save and handler-delete** are no longer `instance_wide`: the
  pre-dispatch refusal was the whole rule, and it could not tell a domain's
  handler from the instance's. Each branch asks the rule
  (`_refuse_unreachable_handler`), and their MCP twins (`save_handler`,
  `delete_handler`) ask the same function with the grant's reach. Everything
  else about an instance handler is as before: a confined caller is refused it.
- **Reading and binding.** `handler-list` / `list_handlers` show a confined
  caller the instance's handlers and its own domains', not another domain's
  (`caller_may_use_handler`). `form-targets-save` / `bind_form` refuse a handler
  of a domain the caller does not reach (`handler_bind_refusal`); the form-reach
  rule (SM976 F2) already confines which forms it binds.
- `schedule-save` / `schedule-delete` stay instance-wide.

# Tests

t/integration/210: the operator saves instance and any domain's handlers, and a
domain the instance does not serve is invalid; a confined token saves and
changes its own domain's handler, and is refused (forbidden) an instance
handler, another domain's, taking either into its own domain, and turning its
own into an instance handler - nothing refused is written; handler-list shows
it the instance's and its own; its form binds its own and an instance handler,
not another domain's; it deletes its own, not the others; the MCP twins answer
the same. t/integration/114 no longer lists the two actions as instance-wide
(an instance handler's refusal is held by 210). Sabotage: the reach rule
disabled, and every handler usable, each fails 210.

Lints: t/lint/218's instance-wide count (26), t/lint/114 (the two new
`*_refusal` rules are not content rules).
