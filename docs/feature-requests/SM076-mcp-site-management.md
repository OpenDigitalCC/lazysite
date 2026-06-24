---
title: "SM076 - MCP server for site management"
subtitle: "Expose lazysite's control API + WebDAV as MCP tools so claude.ai (and any MCP client) can manage sites"
brand: plain
---

::: widebox
A thin **Model Context Protocol** server in front of an existing lazysite
partner credential, so an MCP client (claude.ai, Claude Code, any agent) can
manage a site conversationally - publish pages, activate themes, set config,
own files - without hand-driving HTTP. It is a *client* of the control API and
WebDAV that already exist; it adds no authority of its own.
:::

## Status

Queued - not yet specced. Captures the intent + the shape so it can be picked
up. Depends on the control-API surface that already ships (SM071–SM074).

## Goal

The brief and `/.well-known/ai-partner` already make a lazysite site
**discoverable** to an agent; MCP makes it **operable** over a standard tool
protocol. Today an agent has to speak raw WebDAV + the control API (Basic auth,
`?action=`); an MCP server turns those into named tools an MCP host can call
directly, with schemas and the partner's real capabilities.

## Shape

- **A standalone MCP server** (not part of the CGI) that holds a partner
  credential (the `lzp_` pairing key → `lzs_` token exchange + rotation) and
  proxies to one site's control API + `/dav`. Stateless beyond the token.
- **Tools** map 1:1 onto what already exists, gated by the partner's grant
  (call `whoami` at start-up to advertise only the permitted tools):
  `whoami`, `list-files`, `read-page`, `publish-page` (PUT), `delete`,
  `activate-theme` / `activate-layout`, `config-set`, `acl-set`/`get`/`remove`,
  `wire-form`, `generate-brief` / `read-brief`, `cache-invalidate`,
  `rotate-token`.
- **Multi-site:** one server instance per site, or a server that takes a
  site + credential per session (so claude.ai can manage several of the
  operator's sites).

## Considerations

- **Language / packaging:** lazysite itself is core-Perl, no-CPAN. An MCP
  server is a separate component and need not follow that; decide Perl vs
  Node/Python and how it's distributed (the operator runs it, pointed at a
  site + token).
- **Auth & secrets:** the server stores a token; rotation is its job. It never
  needs operator/manager-group rights - it is a publishing partner, so SM074
  ACL ownership and the deny-set apply to it exactly as over WebDAV.
- **Enforcement stays server-side:** the MCP server is dumb; all capability,
  scope, ACL and deny enforcement remains in lazysite. This keeps the trust
  model unchanged.
- **Offline bundle** path (SM072) is the no-network counterpart; MCP is the
  live counterpart.

## Out of scope (for the first cut)

Cross-tenant provisioning (that is SM075's host-level API, a different trust
tier); operator/admin actions (user management) - MCP is the *partner* surface.
