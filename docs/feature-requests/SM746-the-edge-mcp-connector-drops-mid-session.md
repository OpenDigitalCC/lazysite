---
id: SM746
title: "SM746: the edge MCP connector drops mid-session"
subtitle: "Twice in one week every edge tool vanished from a live session with no action from the agent. Reported, not diagnosed - I have no logs from the incidents. Recorded because the workaround is pasting credentials into chat, so an intermittent reliability fault is quietly buying us a standing security cost."
brand: plain
standard-margins: true
status: candidate
---

# The report

From the edge testing agent, in the filing that became SM745:

> The **edge MCP connector kept dropping server-side** mid-session this week
> (all `edge_explore` tools vanished, twice). Whatever causes that, it pushes
> testers back onto pasted keys.

Two occurrences in one week, in the middle of a working session, with no action
from the agent that could account for it.

# Why it is filed separately from SM745

SM745 is a convenience feature. **This is a defect**, and it is the reason
SM745 has demand.

The prescribed secure channel for handing an agent a credential is the
connector's own settings - no secret in the conversation. When the connector
drops, the agent falls back to a pasted pairing key, which the brief then
declares spent. So an intermittent reliability fault is **converting itself into
a standing security cost**, one rotation at a time, and the rotations look like
the problem rather than the symptom.

Fixing this may remove most of the need for SM745. Building SM745 first would
leave the cause running.

# What I do not know

**Everything about the cause.** I have the report and nothing else: no logs from
either incident, no timestamps, no correlation with a deploy, a restart or a
token expiry. I have not reproduced it and I am not going to guess at a
mechanism from two sentences - `lazysite-mcp.pl` is the obvious place to look,
and "obvious place to look" is not a diagnosis.

This file exists so the observation is not lost between an inbox note and a
conversation, not because it is understood.

# What would settle it

In rough order of cheapness:

- **The timestamps of the two incidents**, from whoever saw them, matched
  against the site's own event log and any restart or deploy in that window.
- **Whether the drop is server-side or client-side** - whether the tools vanish
  because the server stopped answering the tool listing, or because the client
  dropped a session it could not renew. These have entirely different fixes and
  the report cannot distinguish them.
- **Whether it correlates with token lifetime.** A connector token expiring
  mid-session would present exactly as "all the tools vanished", and would be a
  configuration answer rather than a code one.
- **Whether it is edge-specific.** No other connector has been reported doing
  this, but no other connector is exercised as hard, so absence of reports is
  not evidence.

# The ask

Next time it happens, capture the time and whether a subsequent call returned an
authentication error or nothing at all. Two data points from a live incident
would be worth more than any amount of reading the source with no failure in
front of me.

# Provenance

Edge testing agent, 2026-09-02, inside the partner-key delivery filing. Split
out because a defect buried inside a feature request does not get fixed.
