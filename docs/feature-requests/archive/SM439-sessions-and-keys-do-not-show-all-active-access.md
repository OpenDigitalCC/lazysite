---
title: "SM439: Sessions and Keys do not show everyone who has access"
subtitle: "The operator's stated intent for those two pages is that there be no hidden case where access is active or potentially active. Two cases are hidden today, and in one of them the obvious revoke control does not revoke."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED (PENDING). THE FILING SAID THIS WAS READ FROM SOURCE AND NOT EXERCISED, AND NAMED THE TEST THAT WOULD SETTLE IT. That test was run before anything was changed, as a probe rather than on a live partner: issue a token, blank the credential exactly as cmd_key_revoke does, then check. The access token still resolved to the partner AND refresh_access still returned a fresh one - so the reading was right, and it is now a kept test rather than an argument. OAuth::revoke_partner drops both halves of every grant for a partner; key-revoke calls it and reports the count. keys-list no longer skips interactive accounts that hold a machine channel. NOTE: a manager in manager_groups holds webdav, so managers now appear on that page - intended, since the page is meant to answer who can reach the site, and they can. Revocation still refuses an interactive account; listing is not offering. ORIGINAL FILING FOLLOWS. FILED 2026-08-20 on the release manager's instruction, after they asked why an MCP partner visible in the audit trail appears in no session: 'the intent on that sessions and keys page is to know all who have active access, there should be no hidden cases where a session is active (or potentially active)'. THE IMMEDIATE ANSWER IS BENIGN: MCP authenticates per request with a bearer token and never creates a login, and sessions.jsonl records one line per LOGIN, so a partner cannot appear there by construction. That is design, not a gap. THE GAPS ARE ELSEWHERE, and reading for them turned up two. GAP 1, INVISIBLE: cmd_keys_list skips any account with the ui flag - 'next if $eff->{ui}' - deliberately, and for a good reason stated in the code (an interactive account's credential is its login PASSWORD, and listing it as a key would let an operator lock a manager out by revoking one). The consequence is that a HUMAN account that also holds webdav or api access appears on the Keys page never, and on the Sessions page only while a browser cookie is live. WebDAV uses HTTP Basic, replaying the credential on every request with no session, so that access is permanently 'potentially active' and permanently absent from both pages. GAP 2, INVISIBLE AND NOT REVOKED BY THE CONTROL THAT LOOKS LIKE IT REVOKES: live OAuth grants live in lazysite/auth/oauth.json under `tokens`, each carrying exp and refresh_exp. Nothing lists them. Worse, cmd_key_revoke blanks the credential hash in the users file and clears the settings markers, and DOES NOT TOUCH oauth.json - while validate_token reads only oauth.json plus exp, cmd_partner_caps refuses only on a missing or DISABLED account (never on a blank credential), and refresh_access checks only refresh_exp before re-issuing for $rec->{partner}. So after 'revoke access key' on an OAuth-connected partner the connector keeps working until its access token expires, and then mints a new one from its refresh token, for as long as refresh_exp allows. The operator has pressed the control named revoke and the access continues. WHAT ACTUALLY CUTS OFF AN OAUTH PARTNER: disable the account (partner-caps refuses on disabled), delete it, or rotate the site auth secret (rotate-auth-secret, after which stored token hashes no longer match - token_status returns 'unknown'). None of those is what the Keys page offers. EVIDENCE STANDARD: all of the above is READ FROM THE SOURCE and has NOT been exercised against a running instance. The revocation chain in particular deserves a live test before anyone relies on the conclusion, and the filing names the test. This is not a report of an exploited condition, and nothing here says a partner has done anything it should not."
---

# What the two pages show today

```datatable
columns: Access path | Appears on Sessions | Appears on Keys
widths: 7cm | 4cm | X
bold: 1
tone: medium
---
Cookie login (human, browser) | yes, while live | no (correct - it is a password)
Machine account: api / mcp / webdav | no | **yes**
Human account that ALSO holds webdav or api | only while a cookie is live | **no - excluded by `ui`**
Live OAuth grant (access + refresh token) | no | **no - a different store entirely**
```

::: widebox
The stated intent is that there be no hidden case where access is active or
potentially active. The bottom two rows are hidden cases, and the fourth is the
one that matters, because it is also the one where revocation does not do what
its name says.
:::

# Gap 1: a human with WebDAV is on neither page

`cmd_keys_list` excludes interactive accounts on purpose:

```perl
next if $eff->{ui};
next unless $eff->{api} || $eff->{mcp} || $eff->{webdav};
```

The reason is sound and should be preserved - an interactive account's
credential IS its login password, and offering it as a revocable "key" is how
an operator locks out the only manager.

But WebDAV authenticates with HTTP Basic, replaying that password on every
request and creating no session. So a human with `ui` + `webdav` has access
that is live whenever they choose to use it, shows on Sessions only if they
happen to have a browser cookie open, and never shows on Keys at all.

The fix is a listing change, not a permission change: show the account with its
CHANNELS, and let the action offered differ from the one offered for a machine
key.

# Gap 2: revoking the key does not revoke the access

Verified by reading the chain end to end:

```datatable
columns: Step | What it checks
widths: 7cm | X
bold: 1
tone: medium
---
`cmd_key_revoke` | blanks the users-file hash, clears settings markers - **never touches `oauth.json`**
`validate_token` | the token record in `oauth.json`, and `exp`
`cmd_partner_caps` | account exists, and is not `disabled` - **not whether it holds a credential**
`refresh_access` | `refresh_exp` only, then re-issues for `$rec->{partner}`
```

So an OAuth-connected partner whose key has been "revoked" keeps working to the
end of its access token, then renews from its refresh token, and keeps renewing.

What actually stops it: **disable** the account, **delete** it, or **rotate the
auth secret** (`rotate-auth-secret`), after which the stored token hashes no
longer match and `token_status` returns `unknown`. None of those three is what
the Keys page presents as the revoke action.

# What is being asked for

One view that answers "who can reach this site right now", with nothing
omitted:

1. Cookie sessions - as now.
2. Machine keys - as now.
3. Interactive accounts holding a machine CHANNEL, listed with the channel and
   an action appropriate to a password rather than a key.
4. **Live OAuth grants**, from `oauth.json`, with partner, access expiry,
   refresh expiry, and a revoke that removes the token record.
5. `key-revoke` on an OAuth-connected partner should either clear that
   partner's `oauth.json` records too, or refuse and say which control does.

Item 5 is the one worth doing first even if the listing work waits: a control
named "revoke" that leaves access running is worse than no control.

# Before relying on this

Every statement above is read from the source and **not exercised**. The
revocation chain should be tested on a scratch instance before the conclusion
is quoted: connect a partner over OAuth, revoke its key, then call an MCP tool
with the existing access token, and again after refreshing it. Two calls settle
it.

Recorded that way deliberately. A reading of four functions that agree with
each other is still a reading, and today has already produced two confident
mechanisms that measurement overturned.
