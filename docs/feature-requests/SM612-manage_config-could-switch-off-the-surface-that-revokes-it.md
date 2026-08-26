---
title: "SM612: manage_config could disable the manager UI - the only surface on which a capability can be revoked"
subtitle: "Not an escalation: the account was trusted with the capability. A loss of control, which is worse, because what it switches off is the operator's ability to undo the decision."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.0 (stable, 2026-08-26). REPORTED BY THE SITE AGENT 2026-08-26 from a capability-row campaign, measured with a grant holding manage_config and the transports and nothing else. VERIFIED FROM SOURCE, all of it: config-set's allowlist admitted `manager` and `manager_path` alongside the four transport switches, and the `users` action - which is where a group's capabilities are written - is refused to token clients outright, so revocation exists only in the manager UI over a cookie session. A token grant could therefore switch off, or relocate, the one surface on which its own manage_config could be taken away; recovery was editing lazysite.conf on the host. THE SEVERITY SPLIT THE FILING DID NOT MAKE, and it decides the fix: the four transport switches are RECOVERABLE - disabling webdav, mcp, the control API or token exchange is instance-wide and unpleasant and the manager survives it, so an operator undoes it from inside the product. `manager` and `manager_path` remove the undo. Two keys, not five. FIXED as a CHANNEL restriction rather than by removing them from the allowlist, and the lint caught that distinction: the Config page carries a settable toggle for `manager`, so dropping it would have broken the operator's own control while fixing the partner's. They are settable from the manager UI over a cookie session and refused to a token client, which says which route to use rather than merely refusing. SECOND FINDING, also theirs and also fixed: whoami reported a capability as held while its transport was switched off instance-wide - measured with webdav disabled by a DIFFERENT account, PROPFIND answering 404 for a grant that held webdav. reachability() read the GRANT alone; it now takes the service state too, from the same service_enabled predicate the request gate uses, so the two cannot disagree. THIRD, FROM A SEPARATE FILING: whoami now carries `engine_version`. No token-readable signal reported the running build - `version` is refused to token clients, and the generator meta names the build that rendered a PAGE, which on a cached page is arbitrarily stale. An agent re-checking a previous release's finding is in the one case where the build IS the question, and a correct field finding was wrongly withdrawn on the strength of that gap. Both whoami twins carry it, so the two doors answer alike. STILL OPEN, and the operator's own proposal: surface management as its own capability. A capability titled 'Read and set SAFE site configuration' should not decide whether anyone can reach the instance at all - the filing's outcome test says the same from the other end. That is a new capability across four surfaces and waits for after the stable cut."
---

# What was measured, and what it cost

| Key | Set by a token holding `manage_config` | Recoverable from inside the product |
|---|---|---|
| `webdav_enabled`, `mcp_enabled`, `control_api_enabled`, `token_exchange_enabled` | yes | **yes** - the manager survives |
| `manager`, `manager_path` | yes | **no** - the manager *is* the recovery surface |

# Why a channel restriction and not a removal

The Config page carries a settable toggle for `manager`. Taking the key off
the allowlist would have stopped the partner and the operator alike - fixing
the exposure by removing the control it exists to protect. `t/lint/18` refused
that change, correctly, on the grounds that the page would silently fail to
save.

So the key stays settable and the *channel* is what narrows: the manager UI
over a cookie session may set it; a token client is told where it is set
instead.
