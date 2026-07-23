---
title: "SM200 - Connector first-time-connection reliability + diagnostics"
subtitle: "The OAuth/MCP server side is proven reliable end-to-end, yet operators repeatedly need several attempts and a fresh chat to connect an agent. Sharpen the levers lazysite owns: distinct sign-in failure reasons, connect-code robustness, and onboarding guidance for the fresh-chat reality."
brand: plain
status: candidate
status-note: "LEVERS 1+3 IMPLEMENTED on claude/batch-site-integrity (2026-07-23). Lever 1: send_401 now returns distinct data.reason values - sign-in-incomplete / credential-invalid / token-expired / token-invalid (via Auth::OAuth::token_status) - instead of one opaque reason (test in mcp/01-protocol.t). Lever 3: the connector-setup panel + ai-connector-setup doc tell the operator to open a NEW chat if the tools do not appear (the tool list is frozen per chat). DEFERRED: lever 2 (connect-code robustness - longer window / in-place regenerate) and lever 4 (lazysite-check OAuth-endpoint probe). From the 2026-07-23 outsourcify session; server side proven working (oauth/02-flow.t)."
---

# SM200 - Connector first-time-connection reliability + diagnostics

## Why

Onboarding an agent connector repeatedly takes several attempts and a fresh chat
before its tools appear. A full session (2026-07-23,
outsourcify.explore.lazysite.io) established the ground truth:

- The server side works end-to-end. The OAuth+MCP flow was emulated on the shipped
  code (register -> authorize + PKCE + connect code -> token -> MCP whoami with the
  bearer): a token is issued and resolves to the partner every time. The audit's
  `connect ok` IS the successful token issue (`lazysite-oauth.pl` logs `connect` on
  a good code->token exchange). So each attempt DID issue a valid token.
- The first-time friction is therefore NOT a server bug. It is (a) the claude.ai
  tool registry is frozen when a chat opens, so a connector finished mid-chat never
  surfaces until a NEW chat (confirmed repeatedly this session - "new chat also was
  required"); and (b) connect-code fragility - the authorize step needs a fresh,
  single-use, 15-minute code, and a stale / consumed / wrong-partner code leaves
  the connector in sign-in-incomplete.
- Diagnostics were opaque: `-32001 sign-in-incomplete` is returned identically
  whether no token was obtained, the connect code was never redeemed, or the token
  expired / was revoked. (Agent feedback: "a distinct reason would have shortened
  this diagnosis considerably.")

lazysite cannot fix the claude.ai client behaviour, but it can make first-time
connection far less error-prone on the parts it owns.

## Server-side levers

1. Distinct sign-in failure reasons (highest value; direct agent feedback).
   `send_401` (`lazysite-mcp.pl`) already splits had-credential (credential-invalid)
   from none (sign-in-incomplete). Extend the `data.reason` taxonomy:
   - credential-invalid -> `token-expired` vs `token-revoked` vs `token-malformed`
     (`validate_token` / verify-credential can already tell these apart).
   - Keep `sign-in-incomplete` for a genuinely absent bearer, but have the OAuth
     AUTHORIZE path return a specific, human error when a connect code is stale /
     consumed / for-another-partner (`connect-code-expired` / `connect-code-invalid`)
     rather than letting it surface later as the generic tools/call
     sign-in-incomplete. Surface it on the authorize consent page too.
   A machine-readable reason lets an agent go straight to the cause.

2. Connect-code robustness. The single-use + 15-minute window is the main
   first-attempt tripwire. Options: lengthen the window (e.g. 30-60 min); let the
   operator regenerate in place on the setup panel without losing their place; and
   show the code's remaining validity on the panel so an operator does not
   authorise with an expired one.

3. Onboarding guidance for the fresh-chat reality. The connector-setup panel and
   `docs/ai-connector-setup` should state plainly: after the connector shows
   connected, START A NEW CHAT in the agent - the tool list does not refresh
   mid-conversation. This alone stops the most common "it isn't working" loop
   (retrying in the same chat). Ties to the SM196 connected-detection widget (which
   now flips at authorize time).

4. Deploy-time self-check (the SM190 deferred piece). Extend `lazysite-check` to
   fetch the vhost's `.well-known/oauth-authorization-server` and probe the
   advertised authorize / token endpoints, so a misconfigured `site_url` (which
   would make a connector NEVER connect) is caught before onboarding, not during.

## Explicitly out of scope (client-side)

The tool-registry-frozen-per-chat behaviour and the completion / storage of the
OAuth token are claude.ai's; lazysite can only guide around them (lever 3). Say so
in the docs so operators do not chase a server fix that is not theirs to make.

## Acceptance

- A tool call with an expired vs revoked vs absent credential returns distinct
  `data.reason` values.
- Authorising with a stale / consumed connect code returns a specific connect-code
  error (page + reason), not a deferred sign-in-incomplete.
- The connector-setup panel + ai-connector-setup doc tell the operator to open a
  fresh chat after connecting.
- `lazysite-check` flags a vhost whose advertised OAuth endpoints do not answer.

Related: SM196 (connected-detection + generic copy + tools/list), SM190 (discovery
reflects service state; the endpoint-probe deferral), `lazysite-oauth.pl`
(authorize / token, redeem_code, redeem-connect-code), `lazysite-mcp.pl`
(`send_401`, the -32001 reasons), the connector-setup panel (`users.md`) and
`docs/ai-connector-setup`.
