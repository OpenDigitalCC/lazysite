---
title: "Agents and connectors"
brand: plain
---

# Agents and connectors

Not a menu item - the surfaces an agent reaches instead of the menu. A review
that covers only the browser misses most of what a partner touches, and a
partner's first hour is spent entirely here.

Every one of these is **off by default** and enabled per site at
System -> Site settings -> Services. When off, the endpoint returns 404 and
discloses nothing - including that it exists.

## MCP connector

Where
: the MCP endpoint, `/cgi-bin/lazysite-mcp.pl`, added as a custom connector in the
  agent's own app. Enabled at System -> Site settings -> Services -> MCP connector.

Do
: Create a dedicated agent account (`mcp` capability, interactive login
  **disabled**), take the web connect flow, and have the agent run `whoami` and
  `describe_capabilities`.

Expect
: `whoami` names the account; `describe_capabilities` lists what it may do and,
  for anything it may not, says which capability is missing. Both stay available
  to any authenticated session even when the agent holds nothing else - a capless
  agent must be able to diagnose itself.

Negative
: Call a tool the account lacks the capability for: the refusal names the
  capability, and does not read as "unknown tool". Then pass an argument the tool
  does not support: it is **refused by name**, with the accepted arguments
  listed. An ignored argument that returns success is the failure this behaviour
  exists to prevent.

## Control API (token)

Where
: the control API, `/cgi-bin/lazysite-manager-api.pl`, with an `lzs_` bearer
  token. Enabled at Services -> Control API.

Do
: Issue a token, call a read action, then a write action, then an action the
  account may not perform.

Expect
: Token authentication is capability-based. The API and MCP expose the same
  surface - an action reachable on one is reachable on the other with the same
  capability, or deliberately absent from both.

Negative
: A token from another site must not work here. Confirm the refusal, and confirm
  it does not leak whether the account exists.

## WebDAV publishing

Where
: `/dav`, mounted by the partner tool. Enabled at Services -> WebDAV publishing.

Do
: Mount the endpoint as a partner account. Write a page, a theme asset and a
  layout. Then try `lazysite/` paths.

Expect
: Content writes land and re-render. The `lazysite/` tree is denied with four
  carve-outs, and each carve-out is separately capability-gated - `nav.conf`
  needs `manage_nav`, the submission store needs `read_submissions` or
  `manage_forms`.

Negative
: A partner holding only `manage_content` is refused the submission store and
  `nav.conf`. Try both: reading other people's form submissions through the
  generic file surface is the kind of gap that looks like nothing until it is
  everything.

## Scope confinement, on every channel

Where
: all three channels above, plus the manager UI. Set at
  System -> Domains -> a domain -> allowed groups.

Do
: Confine a partner by naming its group in one domain's `allowed_groups`. Then,
  on **each** of MCP, the control API and WebDAV, ask for a path outside that
  domain's content root - including spelled with `..` through its own prefix.

Expect
: Refused on all three, with the same reasoning, and the refusal names the scope
  the account does have. The `..` spelling must be refused on the resolved path,
  not the requested string.

Negative
: An operator (in no scoped domain) is unconfined, which is correct - so make
  sure the account under test is really a confined one, or this proves nothing.

## Agent-facing documentation

Where
: the public site, `/docs/ai-briefing-*`, read by the agent over its own channel.

Do
: Ask the agent to fetch `/docs/ai-briefing-building-sites`,
  `/docs/ai-briefing-authoring` and `/docs/ai-briefing-layouts`.

Expect
: All three are readable by a connected agent, and describe the rules an agent is
  actually held to: content and presentation stay separate, ordinary pages are
  never raw, forms are native, a page is moved with `rename_page` and never
  written-then-deleted.

Negative
: If the guidance and the enforcement disagree, the guidance is the bug. Note any
  case where a briefing tells an agent to do something the engine refuses.
