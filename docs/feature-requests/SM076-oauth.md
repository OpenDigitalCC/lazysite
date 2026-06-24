---
title: "SM076 OAuth - make the MCP server usable from Claude.ai web"
subtitle: "OAuth 2.1 (RFC 9728 + 8414 + 7591 + PKCE) so a web custom connector can authenticate"
brand: plain
---

::: widebox
Claude.ai **web** custom connectors support **OAuth only** - there is no static
bearer/API-key field (confirmed against Anthropic's connector-auth docs and the
live `-32001`: discovery works unauthenticated, every `tools/call` arrives with
no `Authorization`). So the MCP server must speak OAuth 2.1. Claude Code /
Desktop keep working with the `partner:lzs_` bearer; this adds the web path.
:::

## Auth model (the crux)

OAuth needs the human at the consent screen to prove they may act as the
machine partner. We reuse lazysite's one-time-code pattern:

- The operator generates a single-use, short-lived **connect code** (`lzo_…`,
  bound to a partner, ~15 min) from the manager ("Set up Claude.ai").
- During the OAuth flow Claude.ai redirects the user to our **authorize** page;
  the user pastes the connect code. Validating it proves authorization to act as
  that partner. The code is consumed.
- The issued **access token** maps to that partner's existing grant
  (capabilities + per-file ACLs) - the same enforcement as every other path.

No partner secret is ever typed into Claude.ai or a chat; the only thing the
user handles is a one-time consent code.

## Endpoints (new CGI `lazysite-oauth.pl`, served from cgi-bin)

- `GET /.well-known/oauth-protected-resource` - RFC 9728. Served as an api page;
  `{ resource: <mcp-url>, authorization_servers: [<site>] }`.
- `GET /.well-known/oauth-authorization-server` - RFC 8414. AS metadata: issuer,
  `authorization_endpoint`, `token_endpoint`, `registration_endpoint`,
  `response_types_supported:[code]`, `grant_types_supported:[authorization_code,
  refresh_token]`, `code_challenge_methods_supported:[S256]`,
  `token_endpoint_auth_methods_supported:[none]`.
- `POST …/lazysite-oauth.pl?action=register` - RFC 7591 dynamic client
  registration. Claude.ai self-registers; we issue a `client_id` (public client,
  no secret), recording its `redirect_uris`.
- `GET/POST …?action=authorize` - validate `client_id` + `redirect_uri` (must
  match a registered one) + `code_challenge` (S256) + `state`; render a consent
  page that takes the connect code; on submit, mint a single-use **authorization
  code** bound to (client, partner, code_challenge, redirect_uri) and 302 back to
  the client `redirect_uri` with `code` + `state`.
- `POST …?action=token` - `grant_type=authorization_code`, with `code` +
  `code_verifier` (PKCE S256 check) + `redirect_uri`. Issues an **access token**
  (+ optional refresh token) mapped to the partner. Also `grant_type=
  refresh_token`.

Redirect URI Claude.ai uses: `https://claude.ai/api/mcp/auth_callback`.

## Token model + store

`lazysite/auth/oauth.json` (0600, in the write-denied `lazysite/auth/` tree),
holding hashed records:

- `clients`: `client_id -> { redirect_uris, created }`.
- `codes`: `code_hash -> { client_id, partner, challenge, redirect_uri, exp }`
  (single-use, ~60 s).
- `tokens`: `token_hash -> { partner, exp, refresh_hash }` (access ~1 h, refresh
  longer). The MCP server resolves a presented opaque token to its partner here,
  then to `effective_settings` - identical capability + ACL enforcement.

The connect code lives in the partner's settings
(`connect_code_hash`/`_expires`), issued by a manager action, consumed at
authorize - mirroring `pairing_key`.

## MCP server change

`verify_bearer` accepts two shapes: the existing `partner:lzs_` (Code/Desktop),
or an opaque OAuth access token looked up in `oauth.json` (web). On no/invalid
auth it now returns **HTTP 401** with
`WWW-Authenticate: Bearer resource_metadata="<site>/.well-known/oauth-protected-resource"`
so Claude.ai starts the flow. (`initialize`/`tools/list` stay open for
discovery.)

## Build stages (tested at each)

1. **Discovery + registration + challenge** - the two metadata docs,
   `lazysite-oauth.pl` register (DCR), and the MCP 401 `WWW-Authenticate`.
2. **authorize + consent + connect code** - the consent page + connect-code
   validation + the authorization-code mint (PKCE-bound).
3. **token** - code->token exchange with the PKCE verifier check; the token
   store; refresh.
4. **MCP validation** - resolve an opaque access token to a partner.
5. **Manager rework** - "Set up Claude.ai" issues a connect code + the
   connector URL (OAuth), not a pasted token; the connection-detection survives.

## Status

Stage 1 in progress. Stages 2-5 follow. Security notes: PKCE S256 mandatory;
auth codes + connect codes single-use and short-lived; redirect_uri exact-match;
all stored secrets hashed; the store sits in the write-denied auth tree.
