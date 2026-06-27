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

**v1 implemented (2026-06-24)** - `lazysite-mcp.pl`. A Streamable-HTTP JSON-RPC
MCP server reusing the shared `Lazysite::*` action handlers (the SM079 refactor
payoff). Pinned by `t/unit/mcp/01-protocol.t`. Remaining for later cuts: OAuth
2.1, the GET/SSE notification stream, and `set_config` + more tools.

### v1 shape

- **Transport** - single endpoint, `POST` = JSON-RPC request -> JSON response
  (`initialize`, `tools/list`, `tools/call`, `ping`, notifications -> `202`).
  Protocol `2025-11-25`. `GET` returns `405` (no SSE stream in v1; the server is
  stateless, issues no `MCP-Session-Id`).
- **Auth** - static bearer: `Authorization: Bearer <partner-id>:<lzs_ token>`,
  verified by the same `verify-credential` path as the control API, so
  capabilities + per-file ACLs bind identically. A token client is never a
  manager operator. (OAuth 2.1 is the v2 - Claude.ai accepts a static bearer
  today, confirmed 2026-06-24.)
- **Tools** (maintenance only, each gated by the matching capability):
  `whoami` (any), `list_files`/`read_file`/`write_file`/`move_file`/
  `delete_file`/`set_permissions` (`webdav`), `activate_theme` (`manage_themes`),
  `activate_layout` (`manage_layouts`). No user-admin or secrets surface.
- **Errors** - JSON-RPC codes: `-32001` unauthorized, `-32002` insufficient
  capability, `-32602` unknown tool / bad params, `-32601` unknown method.

### Connector setup (how an operator wires Claude.ai to a site)

1. Deploy `lazysite-mcp.pl` to `{CGIBIN}` (the classification installs it
   alongside the other CGIs) behind HTTPS.
2. In Claude.ai, add a custom connector pointing at
   `https://<site>/cgi-bin/lazysite-mcp.pl`, with bearer auth set to
   `<partner-id>:<lzs_ token>` (the same credential issued for the control API).
3. Claude can then call the maintenance tools within the partner's granted
   capabilities + ACLs.

### Deferred to later cuts

- OAuth 2.1 (RFC 9728 protected-resource metadata + PKCE) for per-user
  browser-grant auth instead of a pasted bearer.
- The GET/SSE notification channel + session resumability.
- `set_config` and additional tools (nav, plugins) as the control API exposes
  them as clean module functions.
- The Apache deploy snippet (the `RequestHeader unset X-Remote-*` trust-strip
  already applies; the MCP endpoint needs the same Basic/Bearer pass-through as
  the control API).

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

## Claude.ai vs Claude Code (verified 2026-06-24)

Claude Code already drives full builds + maintenance over the control API +
WebDAV (the dhcf + Barn field reports are the evidence). The open question was
**Claude.ai** (web/mobile): it connects to MCP servers only as **remote custom
connectors** - Streamable HTTP / SSE transport with OAuth - it cannot launch a
local stdio server. So for Claude.ai to manage a site, SM076 must be a **hosted,
remote MCP server** that authenticates the user (OAuth) and proxies to the
control API + WebDAV with a partner `lzs_` token. (Claude Desktop/Code could use
a local stdio build, but the remote form serves both.) This is the binding
design constraint: build the remote/HTTP transport first.

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

## Status (reconciled)

**SHIPPED (MCP v1, lazysite-mcp.pl; pinned by t/unit/mcp/01-protocol.t).** OAuth 2.1, the SSE notification stream, and further tools remain future cuts (see SM076-oauth).
