---
title: "SM102 - agent/connector feedback endpoint"
subtitle: "Let agents and MCP consumers log what worked and what didn't, for us to review"
brand: plain
---

::: widebox
An endpoint agents and MCP consumers can POST a **feedback report** to - what's good,
what's not, what got in the way - saved to a feedback-reports folder with the
metadata that makes it useful (who, which agent/method, version, context). It turns
the ad-hoc "field report" loop (the partner sessions that drove SM080/SM082/SM087)
into a first-class, always-available channel the connector can use unprompted.
:::

## Why

Most of lazysite's connector ergonomics came from reading what real AI partners
struggled with. Today that feedback is manual (a human writes up a session into
`lazysite-sites/reports/`). Giving the agent a tool to submit a report directly -
and encouraging it to - captures the friction at the moment it happens, from the
party that hit it, with the context attached.

## Shape

A new write action exposed on both surfaces:

- **MCP tool** `submit_feedback { rating?, summary, good?, bad?, context? }` -
  annotated read-only-ish (a side-channel, not a content write), available to any
  authenticated connector. `whoami` / the tools doc advertise it ("you're
  encouraged to submit feedback on what helped and what didn't").
- **Control-API action** `feedback` (POST) for non-MCP clients / scripts.

Each report is saved to `lazysite/feedback/<UTC-stamp>-<user>.json` (infrastructure,
on the deny-list, never served), captured server-side so the client cannot spoof the
identity metadata:

```json
{
  "ts": "2026-06-26T17:00:00Z",
  "user": "alex-claude",
  "method": "mcp",                 // mcp | api | webdav | oauth | bearer
  "client": "Claude Code",         // OAuth client_name if known, else null
  "ip": "160.79.106.35",
  "site": "sovereigncomputing.org",
  "version": "0.4.24",
  "capabilities": ["manage_content","manage_themes"],
  "rating": 4,                     // optional 1-5
  "summary": "...",                // required, one line
  "good": "...",                   // what worked
  "bad": "...",                    // what got in the way
  "context": "tried to edit the active layout; got a permission failure"
}
```

The agent provides the **content** fields (summary/good/bad/rating/context); the
server stamps the **identity/meta** fields (user, method, client, ip, site, version,
capabilities) - so the report's provenance is trustworthy.

## Reviewing

- v1: the files are JSON in `lazysite/feedback/`; read them when working on lazysite,
  and a manager **Feedback** page (list + read, like the Audit viewer) is the natural
  follow-on.
- These complement, and can feed, the `SMxxx` feature-request process the same way
  the manual field reports do (SM080's "reports refresh this doc" loop).

## Notes

- Audited as a material event (`feedback`, origin = the method).
- Rate-limited per user (it's a write) so it can't be used to flood.
- Optional: a `submit_feedback` that returns a short "thanks, logged as <id>" so the
  agent can tell the human it filed a report.

## Status

Queued. Bounded: one audited write action reusing the existing auth/identity plumbing
(the server already knows user/method/client/caps from verify_bearer / the OAuth
token), a JSON write to a new deny-listed folder, and an MCP tool + doc line. The
"dogfooding as the spec" pattern, made into a product feature.
