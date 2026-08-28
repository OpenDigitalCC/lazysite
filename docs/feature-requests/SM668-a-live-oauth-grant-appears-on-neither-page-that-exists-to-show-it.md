---
title: "SM668: an MCP agent connected over OAuth appears on neither Sessions nor Keys, so the only lever an operator can find is disabling the account"
subtitle: "Release manager, 2026-08-28: 'an ai agent is connecting via an mcp user. i want to disconnect this but there is no listing in sessions/keys for this agent, so only option is disable account'"
brand: plain
standard-margins: true
status: candidate
---

# Three stores, two pages

| Store | Holds | Listed by |
|---|---|---|
| session registry | browser cookie sessions | **Sessions** |
| users credential store | account tokens / passwords | **Keys** |
| `lazysite/auth/oauth.json` | OAuth access + refresh tokens | **nothing** |

An MCP client authorised over OAuth authenticates per request with a bearer
token from the third store. It creates no cookie, so Sessions cannot show it by
construction. And `keys-list` skips any account holding no stored credential
(`tools/lazysite-users.pl:2753`, `next unless defined $users{$u} && length
$users{$u}`) - which is exactly an OAuth-only partner.

So the one live connection an operator most wants to see is the one neither page
can show, and the only remaining lever is `account-disable`: a bigger hammer
than the situation needs, and one that also stops the account being re-used.

# The mechanism is already right; only the listing is missing

`cmd_key_revoke` ALREADY drops OAuth grants. It clears the stored credential and
then calls `Lazysite::Auth::OAuth::revoke_partner($user)`, deleting every token
that names that partner - best-effort and non-fatal, so a failure there cannot
turn a partial revocation into a reported failure.

It guards on the account EXISTING, not on it holding a credential. So revocation
works on precisely the accounts the listing hides. The operator simply has no way
to reach it, because the row it would sit on is not rendered.

That is what makes this small: no new revocation path, no new capability. The
fix is to list what can already be revoked.

# What SM439 and SM615 already decided

Both widened these pages on the same principle, quoted in the source at the very
line that excludes this case: *"there be no hidden case where access is active or
potentially active"*, and *"listing is not offering"* - the listing widens, the
offer does not.

An account with a live OAuth access token is not merely POTENTIALLY active. It is
active, right now, and it is the one case both filings' principle was written for
that neither reached. The guard that excludes it is the same `next unless` line
SM615 already had to argue past once.

# What it should show

A row per account holding live OAuth tokens, whether or not it holds a stored
credential, carrying what the store already knows: the partner, that the grant is
OAuth rather than a static token, when the access token expires (`exp`), and when
the refresh token expires (`refresh_exp`). A count where one partner holds
several.

Refresh expiry matters more than access expiry for the operator's question: an
access token expiring in an hour is not "disconnected" if a refresh token good
for weeks sits behind it. A page that showed only the access expiry would answer
the wrong question reassuringly, which is SM647's failure mode.

# Open

1. Sessions or Keys? Keys holds the revoke and the credential inventory, so it
   is the natural home - but the operator looked in Sessions first, and an
   active connection is what Sessions is understood to mean. Naming it on Keys
   and cross-referencing from Sessions may serve both readings.
2. Does the row offer a per-TOKEN revoke, or only the existing per-account one?
   `revoke_partner` is per-partner today. Per-token needs a reason to exist.
3. `_gc` prunes expired entries on write. A listing should not report a grant
   that is expired but not yet collected, so the read filters on `exp` the way
   `action_sessions_list` filters on cookie max-age.

# Immediate workaround, until this ships

`key-revoke <account>` from the users tool drops the OAuth grants and leaves the
account enabled. It is a shell command, so it is available to whoever administers
the host and to nobody administering the site through the manager - which is the
gap this filing closes.

# Related

[[SM439]] and [[SM615]] (the two widenings whose principle this completes),
SM145 (key revocation), SM141 (session visibility), [[SM634]] (credential issue
times, so these pages stopped saying "unknown").
