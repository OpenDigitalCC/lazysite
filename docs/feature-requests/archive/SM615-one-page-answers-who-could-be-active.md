---
title: "SM615: an account with only a password was hidden from both cards"
subtitle: "SM439 states the intent - no hidden case where access is active or potentially active - and then met it for interactive accounts holding a machine channel, leaving the plainest account on any site invisible."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.0 (stable, 2026-08-26). ASKED BY THE OPERATOR 2026-08-26: make Sessions & Keys the one place to understand which accounts have the POTENTIAL to run a session, and when each was last active. IT IS A GAP AGAINST A STATED INTENT rather than a new idea, which is why it goes into 0.11.0 under the freeze. SM439 says in terms: 'The stated intent of these two pages is that there be no hidden case where access is active or potentially active.' It then widened the listing to an interactive account that ALSO held a machine channel - the WebDAV case, where a password is replayed over HTTP Basic on every request and creates no session - and stopped there. A plain manager account, a password and the manager and nothing else, remained absent from BOTH cards: from Active sessions whenever no browser cookie happened to be live, and from Active keys by the machine-channel filter itself. That is the commonest account on any site, and it was the last hidden case. FIXED by widening the filter to include `ui`, and NOT by widening what may be revoked - cmd_key_revoke already refuses an interactive account on its own, which is SM439's 'listing is not offering' and remains true. The card is titled for what it now answers, and an account with no key says what it DOES reach rather than showing an empty cell that reads as missing data. `channels` still lists only what a KEY opens, so the manager is not among them. LAST ACTIVE WAS ALREADY RECORDED and needed no new plumbing: cred_used_at is written by verify-credential, which a password login goes through as much as a token check does - so the same field answers 'when did this account last use its credential' for a person and for an agent. WHAT THE PAGE NOW ANSWERS, in one place: who is signed in right now (Active sessions), who COULD be - by key, by password, or both - and when each last was. An account in neither card cannot reach the site at all. THE FIXTURE TAUGHT ME SOMETHING worth recording: my first attempt built the test account with a group and then set webdav off per-account, and it still held webdav. effective_settings UNIONS group grants; a per-account `set` does not override one. An account with no group at all is the ui-only case, because `ui` defaults on for an account nobody has classified."
---

# The last hidden case

| Account | In Active sessions | In Active keys (before) | Now |
|---|---|---|---|
| Agent with a token | no | yes | yes |
| Person with a password **and** WebDAV | only while signed in | yes (SM439) | yes |
| **Person with only a password** | **only while signed in** | **no** | **yes** |

The third row is most of the humans on most sites.

# Listing is still not offering

Revocation is refused for an interactive account, in the tool, where that
decision belongs. Widening what is *shown* did not widen what can be
*taken away*.
