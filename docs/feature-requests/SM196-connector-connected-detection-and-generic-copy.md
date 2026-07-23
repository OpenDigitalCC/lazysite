---
title: "SM196 - Connector 'waiting to connect' never flips; generic AI-agent copy"
subtitle: "The pairing panel stays on 'waiting for Claude to connect' though the OAuth/MCP connection completes (audit: oauth-authorize + mcp connect both ok) - the connected-detection stamp is not being hit. Also make the status copy generic 'AI agent', not Claude-specific."
brand: plain
status: candidate
status-note: "IMPLEMENTED on claude/cluster-a-plus-sm192 (2026-07-23). (1) cmd_redeem_connect_code stamps cred_used_at at redemption, so the connected indicator flips at authorize time not on a later tool call (test in oauth/02-flow.t). (2) the connector-onboarding status copy is agent-neutral in users.md ('the AI agent', 'the agent is connected'); product buttons unchanged. (3) tools/list filters by the session's caps when a valid bearer is present (introspection always; channel + per-tool cap; interactive-manager refused), anonymous discovery unchanged (test in mcp/01-protocol.t). Enforcement unchanged. Awaiting gate + vcs-review."
---

# SM196 - Connector "waiting to connect" never flips; generic AI-agent copy

## Part 1 - the connected indicator no longer fires (bug)

Symptom: after generating a connect code, the pairing panel shows "waiting for
Claude to connect ..." and stays there, though the agent connected successfully.
The site audit confirms the connection completed:

    07:02:58  claude.ai  mcp  oauth-authorize  lzcid_2b1dd2...  ok
    07:03:00  claude.ai  mcp  connect          oauth            ok

How detection is meant to work: `pollConnector` (`starter/manager/users.md`) polls
`credential-status` every 3s and flips to "connected" when the response carries
`used: true`. `credential-status` derives `used` from `cred_used_at`
(`tools/lazysite-users.pl`). For the OAuth / web-connector path, `cred_used_at` is
stamped by `cmd_partner_caps` - added expressly so "the connector-setup connected
detection fires for the OAuth path too" (its own comment). So the chain is: agent
connects -> MCP resolves caps via `partner_caps` -> `partner_caps` stamps
`cred_used_at` -> `credential-status.used` -> poll flips.

The chain is broken: the connection completes (audit `connect ok`) but
`cred_used_at` is not stamped, so the poll never sees `used` and gives up after
180s ("not detected yet - check again"). Likely cause: the current MCP connect /
oauth-authorize path no longer routes through `cmd_partner_caps` at connect time
(cap resolution moved, or the used-stamp now fires only on a first TOOL call,
which the audit shows had not yet happened at 07:03). To confirm: trace whether
`cmd_partner_caps` is invoked during `mcp connect` / `oauth-authorize`
(`lazysite-mcp.pl`, `lazysite-oauth.pl`) and whether `cred_used_at` moves for the
user.

Fix options (prefer the robust one):

1. Stamp used at CONNECT / AUTHORIZE time. Ensure the oauth-authorize or MCP
   session-init path stamps `cred_used_at` (call `partner_caps` or an explicit
   used-stamp) so detection does not hang on a later tool call.
2. Broaden the detection signal. Have `credential-status` treat a completed
   oauth-authorize / mcp-connect for that user - which the audit ALREADY records
   `ok`, and the issued-and-bound OAuth token evidences - as "connected", not
   solely `cred_used_at`. The audit knows the connection happened; the UI should
   trust the same signal.

Recommend (2) as primary (decouples the UI from tool-call timing) with (1) as
belt-and-braces. Regression test: an OAuth connect flips
`credential-status.used` / the connected state WITHOUT a tool call.

## Part 2 - generic "AI agent" copy, not Claude-specific

The pairing status copy names Claude where it should be agent-neutral (the site
connects any MCP / OAuth agent - Claude, ChatGPT, others):

- "waiting for Claude to connect ..." -> "waiting for the AI agent to connect ..."
- "Connector authenticated - Claude is connected." -> "... the agent is connected."
- "Step 2 - paste this to Claude" -> "... paste this to the agent"
- "follow Step 1 to connect Claude.ai" -> "... to connect the agent"

Keep genuinely product-specific SETUP steps as they are - the connector target
buttons (Claude.ai / ChatGPT (web), Claude Desktop, Claude Code / script) and
their per-product menu instructions name real product menus, so those stay. Only
the generic status / progress copy goes agent-neutral. Consistent with the
existing generic-AI surfaces (`.well-known/ai-partner`, `describe_capabilities`,
the "AI agents (Claude, ChatGPT)" config note).

## Part 3 - filter (or annotate) tools/list by the session's capabilities

Field observation (0.9.10): an agent's `whoami` showed `feedback: false`, yet
`submit_feedback` appeared in `tools/list` - and the agent reasonably read that as
a capability-enforcement gap. It is NOT one. `tools/list` is deliberately open and
unauthenticated ("tools/list stay open for discovery; only tool invocation is
gated", `lazysite-mcp.pl`), and invocation IS gated at `tools/call` (the `mcp`
channel capability, then the per-tool capability), so `submit_feedback`
(`cap: feedback`) is refused on call. Enforcement holds.

But listing tools the caller cannot invoke is misleading: the agent wastes a call,
gets a denial, and can misdiagnose. In this same report the agent also flagged
`audit_site` while `audit: false` - but `audit_site` is gated by `manage_content`
(which it held), not by the audit-log `audit` capability; a name collision it was
led into precisely because the advertised surface did not reflect its grants.

Improvement: when a `tools/list` request carries a valid bearer, filter the
returned set to the tools the session can actually invoke (channel + per-tool
cap); or, softer, annotate each tool with the capability it needs and whether the
session holds it. Keep the anonymous, unfiltered list for pre-auth discovery (an
unauthenticated probe still learns the surface). This aligns the advertised
surface with what the agent can do and removes the "advertised but denied"
confusion. This does NOT change enforcement (invocation stays gated) - it is the
same reflect-reality theme as Part 1, SM190, and SM180 (dormant-capability hints).

## Tests

- OAuth connect (no tool call) flips the connected indicator (Part 1 regression).
- The wait / progress status strings render agent-neutral; product buttons
  unchanged.
- An authenticated `tools/list` omits (or flags) a tool whose capability the
  session lacks (e.g. `submit_feedback` with `feedback: false`); an anonymous
  `tools/list` still returns the full surface (Part 3).

Related: `starter/manager/users.md` (`pollConnector` / `revealPrompt` /
`cmd_partner_caps` chain), `tools/lazysite-users.pl` (`cred_used_at`,
`credential-status`, `cmd_partner_caps`, `cmd_redeem_connect_code`),
`lazysite-oauth.pl`, `lazysite-mcp.pl` (`tool_list` and the `tools/call` gate),
SM076 (connector setup), SM180 (dormant-capability hints), and SM190 (the same
"reflect reality" theme).
