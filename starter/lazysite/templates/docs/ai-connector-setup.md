---
title: Connect an AI assistant
subtitle: Adding this site to Claude.ai, ChatGPT, Claude Desktop, Claude Code or another MCP client, step by step, and how a client connects and authenticates.
search: false
---

## Who this is for

The operator, adding this site to an AI client once the assistant has an account
(see [Onboard an AI agent](/docs/onboard-ai-agent) for the account and its
permissions); and an AI agent, or whoever builds a client, that needs to know how
a client reaches the site. This is the one page with the steps for each client,
the [Endpoints](#endpoints), the two [Connection modes](#connectionmodes) and
[Authentication](#authentication). It is public, so a client can read it before
it holds a credential.

This site exposes an **MCP connector** so an AI assistant can maintain it through
tools (list, read, write, move, delete pages; set permissions; activate
themes/layouts). It speaks standard MCP + OAuth, so it works with any MCP-capable
client - Claude.ai, ChatGPT, Claude Desktop, Claude Code, and others.

For the full tool catalogue, the capability model and the error reference, see
[AI connector - tools reference](/docs/ai-connector-tools) (signed in). This page
covers *connecting*.

The endpoint is the same for everyone:

    https://YOUR-SITE/cgi-bin/lazysite-mcp.pl

The web apps (Claude.ai, ChatGPT) are added by URL and sign in with a one-time
**connect code**; the developer tools (Claude Desktop, Claude Code, a script) set
a bearer header. How each credential works, and that both are held to the same
grant, is in [Authentication](#authentication). Whichever
you use, have the assistant call `whoami` first to confirm the grant.

## Claude.ai (web / mobile)

1. Users page → the partner → **Connect an AI assistant**. Keep that panel open
   (it waits for the connection, then reveals the task prompt).
2. In Claude.ai: **Settings** (click your username) → **Connectors** (under
   *Customize*) → **Add custom connector**. Enter the **Name** (the site domain)
   and the **URL** above.
3. **Set the OAuth client to "No client ID - register one automatically".**
   This one matters and the default is wrong for this server. Claude.ai now asks
   which kind of OAuth client to use, and recommends *"Use Anthropic's hosted
   client metadata (CIMD)"* - where the server fetches Claude's client details
   from a URL Anthropic hosts. **This server does not support CIMD.** It
   implements RFC 7591 dynamic client registration, which is the option
   Claude.ai labels *"No client ID - register one automatically"*. Choose that
   and registration succeeds; leave the recommended default and the connector
   never reaches the sign-in step, so the connect code has nowhere to go.
4. Leave **Authentication** as *"Required when the server asks"* - this server
   answers an unauthenticated request with `WWW-Authenticate`, which is exactly
   the ask that setting waits for. *"Always required"* also works.
5. Under **Advanced**, leave **Transport** on **Streamable HTTP**. This server is
   POST-only and answers `GET` with 405, so **SSE (legacy) will not work**.
   Claude.ai selects SSE automatically for a URL ending in `/sse`; this one does
   not, so the default is already right - just do not change it.
6. Open a new chat, enable the connector, and ask Claude to run `whoami`.
7. Claude.ai shows a sign-in pop-up; paste the **connect code**. Done - the Users
   panel flips to connected and gives you the prompt to paste.

::: widebox
**If Authentication shows "None - Detected".** Claude.ai probed the server and
found no OAuth, which means `oauth_enabled` is off on this instance. Turn it on
in the manager: **Config → Services → OAuth authorization server**. Every OAuth
endpoint returns 404 until you do, so the connect-code flow cannot start.

You can also skip OAuth entirely: leave Authentication on **None**, and add
`Authorization: Bearer <partner-id>:<token>` under **Additional request
headers** using a token from **Generate agent brief**. That path needs no
`oauth_enabled` and no connect code - it is the static-bearer method below,
driven from the web app.
:::

## ChatGPT (Plus / Pro / Business / Enterprise)

1. Users page → the partner → **Connect an AI assistant** (get the connect code).
2. In ChatGPT: **Settings** → **Apps / Connectors** → **Advanced** → enable
   **Developer mode** → **Create / Add custom connector**. Enter a Name and the
   **URL** above; Authentication = OAuth (it is discovered automatically).
3. Acknowledge the custom-connector risk notice, then create it - ChatGPT runs the
   OAuth sign-in and asks for the **connect code**; paste it.
4. In a chat, ask it to run `whoami`, then `list_files`.

Note: on **Plus/Pro**, ChatGPT can call **read-only** tools only (whoami,
list_files, read_file). **Business/Enterprise** get the write tools (write_file,
activate_theme, …) with a per-call approval card. ChatGPT is also noticeably
slower than Claude per tool call.

## If the connector is added but the tools do not appear

The most common cause is **not** the server - it is that the assistant's tool list
is fixed when a chat opens. A connector you finished authorising *during* a
conversation will not surface until you **start a new chat**. So: complete the
sign-in, confirm the Users panel shows *connected*, then open a **fresh chat** and
ask for `whoami`.

If a tool call is refused, the error's `reason` names the cause precisely:
`sign-in-incomplete` (the connect code was never pasted - redo the sign-in with a
fresh code), `token-expired` (reconnect, or let the client refresh), or
`token-invalid` (the token was revoked or the site secret was rotated - reconnect).

## Claude Desktop / Claude Code / scripts (static bearer)

1. Users page → the partner → **Generate agent brief** (gives a pairing key) or
   **Generate credential** (gives an `lzs_` token directly).
2. Add the endpoint as a remote MCP server with a header:
   `Authorization: Bearer <partner-id>:<lzs_ token>` (Desktop/Code support custom
   headers). A script can also use the control API + WebDAV directly (API mode -
   see [Connection modes](#connectionmodes)).

## Any other MCP client

Point it at the endpoint. If it supports OAuth, it will discover
`/.well-known/oauth-protected-resource` from the `401 WWW-Authenticate` challenge
and run the connect-code flow. If it supports a static header, use the
`partner-id:lzs_` bearer.

## Troubleshooting

- **Tools call back "unauthorized" / `invalid_client`**: remove and re-add the
  connector so the app does a fresh registration + sign-in.
- **The connection fails**: check that WebDAV is enabled (in **Site settings**)
  and that the connect code has not expired (it lasts 30 minutes). Click
  **Connect an AI assistant** again for a fresh one - it supersedes the old.
- **Tools aren't in the assistant's toolset**: connectors load at the start of a
  turn; enable it for the chat and send one more message. Don't fall back to raw
  HTTP - that path is unauthenticated.
- **`whoami` works but a write is refused**: the grant (capabilities + per-file
  ACL) is authoritative - the partner lacks that capability or write access.

## Endpoints

MCP
: `https://YOUR-SITE/cgi-bin/lazysite-mcp.pl` - a single MCP endpoint,
  Streamable HTTP / JSON-RPC, exposing the maintenance operations as tools (see
  [Tools](/docs/ai-connector-tools#tools)). `initialize` and `tools/list` are
  open (discovery); a `tools/call` requires authentication. An unauthenticated tool call returns
  HTTP 401 with a `WWW-Authenticate` challenge so an OAuth client starts the
  sign-in flow.

WebDAV
: `https://YOUR-SITE/dav/` - content, assets, layout/theme files, and
  `nav.conf`.

Exchange / Rotate
: `https://YOUR-SITE/cgi-bin/lazysite-auth.pl?action=exchange` and
  `?action=rotate`.

Control API
: `https://YOUR-SITE/cgi-bin/lazysite-manager-api.pl` - token-authenticated (the
  same Basic auth as WebDAV). Carries the operations that are not file-shaped.
  Each is gated by the matching capability from your grant; the actions are in
  [AI briefing - publishing](/docs/ai-briefing-publishing#controlapiactions).

## Connection modes

Two ways to drive a site - pick by what you are. The credential, capabilities
and per-file ACLs are identical in both; only the transport differs.

API mode (WebDAV + control API)
: Direct HTTP. The full surface, and the right choice for a scripted build or
  bulk file work - WebDAV moves many files (a whole site deploy) efficiently,
  and the control API carries theme/layout/ACL/config. Authenticate with Basic
  auth (partner id + `lzs_` token).

MCP mode
: The MCP server wraps the *maintenance* verbs - `whoami`, list / read / write /
  move / delete files, `set_permissions`, `activate_theme`, `activate_layout` -
  as MCP tools. Best for an MCP-capable conversational agent (e.g. a Claude.ai
  custom connector, or Claude Desktop/Code): add `…/cgi-bin/lazysite-mcp.pl` as
  a remote connector with bearer auth `<partner-id>:<lzs_ token>` (the same
  credential, colon-joined). It writes one file per call, so for a large initial
  build prefer API mode + WebDAV; for ongoing maintenance either works.

Which to use, by client
: **Claude.ai (web / mobile)** reaches a site only through a connector, so it
  uses **MCP mode**. **Claude Code / Claude Desktop** can use **either**: API
  mode directly (curl the control API, `PUT`/mount over WebDAV - best for a full
  build or bulk upload), or the MCP endpoint as a remote (HTTP) MCP server for
  guided, tool-shaped maintenance. A scripted or non-AI client uses **API
  mode**. Whichever you pick, call `whoami` first to confirm your grant.

## Authentication

Two credential shapes, held to the same capabilities and per-file ACLs:

OAuth (Claude.ai, ChatGPT web)
: The client registers itself, the operator's one-time **connect code** is entered
  at the consent screen, and an opaque access token is issued (expires hourly,
  refreshed transparently). No token is ever pasted into the chat.

Token (Claude Code, Desktop, scripts, and API mode)
: An `lzs_` access token. The operator's *Generate credential* on the Users page
  gives one directly; *Generate agent brief* gives a pairing key you exchange for
  one (below). Over MCP send it as `Authorization: Bearer <partner-id>:<lzs_ token>`;
  over WebDAV and the control API as HTTP Basic auth (below).

`whoami` returns an `auth` block - `{ method: "oauth"|"bearer", expires_at }` - so
the agent can see how the session is authenticated and when it lapses.

### The pairing key and the access token

You hold a single-use, short-lived pairing key (prefix `lzp_`). You exchange it
once for a working access token (prefix `lzs_`).

Exchange
: `POST` the pairing key to the exchange endpoint. The JSON response carries
  the token and its expiry as an epoch timestamp.

Present
: Send the access token as HTTP Basic auth on every request - **username is
  your partner id, password is the token**. The partner id gives per-partner
  attribution and scoping; it is the exact id from your brief (often not a bare
  name - e.g. `claude-example`), and the wrong username returns `401`.

Rotate
: Before the token expires, present your current token as Basic auth to the
  rotate endpoint with no body; you get a fresh token and a new expiry. There
  is one live credential per account - the old token dies on rotation.

Recover
: On an unexpected `401`, rotate if you still hold a recently valid token;
  otherwise the operator must re-issue the pairing.

```bash
# Exchange the pairing key for an access token
curl -s -X POST "https://YOUR-SITE/cgi-bin/lazysite-auth.pl?action=exchange" \
  --data "username=PARTNER&pairing_key=lzp_..."
# -> { "ok": true, "token": "lzs_...", "expires_at": 1750000000 }

# Rotate before expiry (current token as Basic auth, no body)
curl -s -X POST -u "PARTNER:lzs_..." \
  "https://YOUR-SITE/cgi-bin/lazysite-auth.pl?action=rotate"
```

Read `expires_at` from the exchange and rotate responses so you rotate on
schedule rather than waiting for a `401`. Both endpoints are HTTPS-only and
rate-limited.

### Check your access, and your grant

A cheap, side-effect-free probe that the token is live:

```
PROPFIND /dav/  Depth: 0  Authorization: Basic base64(PARTNER:lzs_...)
-> 207 = authenticated; 401 = wrong username or token.
```

For your **full grant** - capabilities, groups, scope, and the extensions,
layouts, and themes the site offers (with active flags) - introspect over the
control API rather than assuming from the bootstrap:

```
GET /cgi-bin/lazysite-manager-api.pl?action=whoami
Authorization: Basic base64(PARTNER:lzs_...)
-> { partner, capabilities, groups, scope, layouts, themes, extensions, site_capabilities }
```
