---
id: SM1219
title: "SM1219: the visitor log names the signed-in account"
subtitle: "A visit made while signed in is recorded with the account the engine verified, never one a client typed. The analytics capability reads the visits per account, a domain-confined caller only its own domains', and the manager Stats page lists them."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-13
raised-by: "the release manager, 2026-10-13 (inbox: the-visitor-log-records-the-signed-in-account); ruled 2026-10-20 (#339)"
area: stats
status-note: "SHIPPED (PENDING) on n705: access-log.pm records `u` for a verified session or a listed proxy's user; by_account in the export, API and MCP; a Visits by account card on the Stats page. Sabotage: reading the raw header fails the forged-header test."
---

# The request

The release manager, 2026-10-13: "visitor log to record user if user is logged
in."

Before this the visitor log (lazysite-processor/access-log.pm, read by
analyse_visitors) recorded a visit with the served host (SM1001) but no identity: a
signed-in visitor was counted like an anonymous one.

# The rulings (2026-10-20, #339)

The brief put five questions; the release manager's answers, quoted:

- Q1/Q2 "**The account name; read by anyone with the analytics capability; a
  domain-confined caller sees only its own domains' visitors.**"
- Q3 "**Kept as long as the rest of the log.**"
- Q4 "**A token or MCP caller's account is recorded too**, beside the
  lazysite-agent/<partner> bot marking."
- Q5 "**Per-account visits are shown in the manager.**"

# What shipped

- **The record.** `_access_record` adds `"u":"<account>"` for a request whose
  identity the engine verified, asked of the one identity reader
  (`_request_identity`) at the end of the request. Its source decides: `cookie` (the
  auth wrapper's verified session on CGI, the pool front door's held value from
  SM1181) and `proxy` (a peer in `auth_proxy_trusted_from`) record the user;
  `direct`, a request nothing verified, records nobody. The raw `X-Remote-User` is
  never read here, so a forged header records nobody. An anonymous visit has no `u`
  at all. It is read at the end of the request and not from the page gate's context,
  so a cache hit served to a signed-in visitor still records them (and the shared
  cached page never lends the account to the next visitor). The preview and draft
  doors return before it, as before. Retention is the log's: `retention_days`.
- **A token or MCP caller.** The MCP and control-API doors write no access log of
  their own; a token holder reaches the site's pages by exchanging the token for a
  session cookie, and those page requests are recorded under its account beside
  the `lazysite-agent/<partner-id>` User-Agent marking. No separate path was added.
- **The read.** `plugins/stats.pl --export --by-account` (and `by_account` on
  analyse_visitors over the control API and MCP) adds `by_account`: a row per
  account for the window - `visits` (page requests), `agent_visits` (those from a
  declared agent), `days`, `last`. It is asked for; the default reply carries no
  account name. It needs `analytics`, and a confined caller is answered by the same
  scope as the traffic (`visitor_scope_args`): only the accounts that visited its
  own domains, the index and rollups refused as before.
- **The manager.** The Stats page has a Visits by account card, shown to an
  analytics holder from the same call (hidden when the call is refused), a row per
  account: account, visits, days, last visit. It says "No signed-in visits recorded
  in the last 30 days." when there are none, and adds no explanatory text.
- **The grant text.** The analytics capability said its figures "cannot identify an
  individual visitor". Its title and grant text now say the visits per signed-in
  account are shown to it (account names are personal data); the seeded
  `cap-analytics` group description, the generated capability map and the
  .well-known/ai-partner line agree.
- **Docs.** The AI stats briefing (`by_account`), the manager, onboard-an-agent
  and FEATURES pages, and the operator guide: the log is personal data once it
  holds account names, and telling the people who sign in is the operator's duty
  (the SM1010 principle), in the operator docs and not on a screen.

# Tests

t/integration/310 (a verified visit recorded, an anonymous one not, a forged
X-Remote-User nobody, a listed proxy's user, a cache hit to a signed-in requester and
not to the next visitor), 312 (the same in the one-rule pool), 311 (analytics needed,
a confined caller only its domains' accounts, the default reply carries none),
t/unit/plugins/55 (the per-account figures), t/unit/manager/380 (the page draws the
list, escapes a name, hides on refusal).

# Not done

- A per-account figure is not in the durable day rollups; it is read from the raw
  log, so it reaches back `retention_days` and cannot be asked for a single past
  day or month.
