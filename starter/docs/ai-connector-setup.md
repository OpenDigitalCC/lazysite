---
title: Connect an AI assistant
auth: manager
search: false
---

This site exposes an **MCP connector** so an AI assistant can maintain it through
tools (list, read, write, move, delete pages; set permissions; activate
themes/layouts). It speaks standard MCP + OAuth, so it works with any MCP-capable
client - Claude.ai, ChatGPT, Claude Desktop, Claude Code, and others.

For the full tool catalogue, auth/capability model and error reference, see
[AI connector - tools reference](/docs/ai-connector-tools). This page covers
*connecting*.

The endpoint is the same for everyone:

    https://YOUR-SITE/cgi-bin/lazysite-mcp.pl

There are two ways to authenticate, depending on the client:

Connector + OAuth (web apps)
: For Claude.ai and ChatGPT, you add the connector by URL; the app runs an OAuth
  sign-in, and you paste a one-time **connect code** (from the Users page →
  the partner → **Connect an AI assistant**). No token is ever pasted into chat.

Static bearer header (developer tools)
: For Claude Desktop, Claude Code, or a script, you set an
  `Authorization: Bearer <partner-id>:<lzs_ token>` header (the token comes from
  **Generate agent brief**). These clients let you set a header directly.

The capability gating and per-file ACLs are identical whichever you use - call
`whoami` first to confirm the grant.

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
   see the publishing briefing).

## Any other MCP client

Point it at the endpoint. If it supports OAuth, it will discover
`/.well-known/oauth-protected-resource` from the `401 WWW-Authenticate` challenge
and run the connect-code flow. If it supports a static header, use the
`partner-id:lzs_` bearer.

## Troubleshooting

- **Tools call back "unauthorized" / `invalid_client`**: remove and re-add the
  connector so the app does a fresh registration + sign-in.
- **Connect code expired** (30 min): click **Connect an AI assistant** again for
  a fresh one - it supersedes the old.
- **Tools aren't in the assistant's toolset**: connectors load at the start of a
  turn; enable it for the chat and send one more message. Don't fall back to raw
  HTTP - that path is unauthenticated.
- **`whoami` works but a write is refused**: the grant (capabilities + per-file
  ACL) is authoritative - the partner lacks that capability or write access.
