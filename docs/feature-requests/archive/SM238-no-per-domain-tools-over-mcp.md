---
title: "SM238 - MCP exposes the instance-wide theme switch and no per-domain one"
subtitle: "An agent managing one domain on a multi-domain instance can reach activate_theme, which changes every domain, but not domain-set, which changes only theirs. The safe operation is the missing one."
brand: plain
status: shipped
status-note: "IMPLEMENTED in the 0.10.3 edge line (2026-08-08, commit 37e7c37). Reported by a site agent 2026-08-07, who correctly declined to use the tools available rather than risk another domain on the same instance. Verified: the MCP tool list carries NO domain-management tools at all beyond site_backup / site_apply, while the control API carries the full set under the same manage_domains capability. This is a channel gap, not a permission question."
---

# SM238 - no per-domain tools over MCP

## Why

An agent asked to bind `harmony2050.org` to a specific layout and theme reported:

> That control lives behind a control-API action (`domain-set`) that isn't
> exposed to me as an MCP tool - I only hold `activate_layout`/`activate_theme`,
> which are instance-wide and would risk touching theunited.fund itself, so I
> deliberately didn't touch them.

The judgement was right and the situation is backwards. The MCP surface offers
the operation that changes **every** domain on the instance and withholds the one
that changes **a single** domain. An agent scoped to one site can either do
nothing or do something far broader than it was asked to.

A careful agent stops, reports, and waits - costing a round trip and operator
time. A less careful one reasons that `activate_theme` is the only tool it has,
uses it, and reconfigures somebody else's live site.

## What is true today

The full MCP tool list contains no domain-management tools:

```
whoami describe_capabilities list_files read_file write_file site_backup
site_apply replace_text copy_file get_permissions move_file delete_file
set_permissions list_themes theme_tokens activate_theme create_theme
activate_layout list_layout_catalogue install_layout delete_layout ...
```

Under `manage_domains`, the capability map records the asymmetry plainly:

| Channel | What it unlocks |
|---|---|
| api | `domains-list`, `domain-add`, `domain-set`, `domain-remove`, `domain-preview`, `domain-check`, `site-backup-*` |
| mcp | `site_backup`, `site_apply` |

`domain_set` accepts `theme` and `layout` among its settable keys, so the
per-domain binding the agent needed exists and works - just not on the channel
the agent has.

Meanwhile `activate_theme` and `activate_layout` are exposed over MCP and write
the instance-wide `theme:` / `layout:` keys in `lazysite.conf`.

## The question this raises, and the answer

The operator's question was whether this is missing MCP functionality or whether
an MCP partner should also hold an API token. It is the former, for three
reasons.

**No new privilege is involved.** `manage_domains` already gates these actions,
and an account either holds it or does not. Exposing the same actions over MCP is
the same capability on a different channel, which is precisely what the
channel/action split exists to express. Nothing about who may do what changes.

**A token is a wider grant than a tool.** Handing an MCP partner an API token
gives it every action its capabilities allow, as a bearer credential, over a
channel with no per-operation description. An MCP tool is typed, described,
individually gated and individually auditable. Solving a missing-tool problem by
issuing a broader credential moves in the wrong direction.

**It leaves the hazard in place.** The agent would still see `activate_theme` in
its tool list, still with instance-wide effect, and would still have to know not
to use it. The asymmetry is the defect; a second credential works around it.

## What to add

Per-domain tools over MCP, gated by `manage_domains` exactly as their control-API
twins are:

- `list_domains` - read-only; an agent should be able to see what it is working
  within.
- `domain_set` - the immediate need. Per-domain `theme`, `layout`, `nav_file`,
  `site_name`, `site_url`, `search_default`.
- `preview_domain` - read-only, renders a domain as a visitor would see it.
  Valuable before committing a change, and harmless.

`domain_add` and `domain_remove` deserve a separate decision. Adding a domain is
an instance-level act with DNS and certificate consequences; removing one is
destructive. Neither is needed for the reported case, and both should be argued
on their own rather than swept in.

## The better fix for the tools that already exist

Adding `domain_set` solves the reported problem. It leaves `activate_theme` and
`activate_layout` as instance-wide tools sitting in the tool list of an agent
scoped to one site.

Give both an optional `host` parameter. With a host, they set that domain's
binding; without one, they set the instance default as they do now. The agent
then reaches for the tool it was always going to reach for and gets the scoped
behaviour by naming the domain it was asked about.

Their descriptions should state the instance-wide effect of omitting `host`
explicitly - the current wording does not warn that the operation touches every
domain, and an agent has to infer it.

## Verification

- An account holding `manage_domains` over MCP can read the domain list, set a
  domain's theme and layout, and preview it.
- An account without `manage_domains` sees none of these tools, and
  `describe_capabilities` reports the capability as ungranted rather than absent.
- `activate_theme` / `activate_layout` with a `host` change only that domain;
  without one they behave exactly as before.
- Their descriptions state what omitting `host` does.
- Scope confinement applies on the MCP channel as it does on the API channel: an
  agent confined to one domain cannot set another's.

## Not in scope

- Any change to what `manage_domains` permits.
- `domain_add` / `domain_remove` over MCP - a separate decision.
- Issuing API tokens to MCP partners.
