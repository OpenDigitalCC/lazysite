---
title: "SM411: one verification chain, in one module"
subtitle: "Session-cookie verification moves from lazysite-auth.pl into Lazysite::Auth::Session, and the wrapper delegates - so a surface that cannot sit behind the auth wrapper can hold a real identity instead of trusting a header the client sent."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.10.17 (b03bece). Named and scoped by SM410's audit - it closes SM402's recorded option 2 - and filed at release rather than at start, which t/lint/26 rightly refused to let stand. WHY: the data endpoint (SM410 DP-3) would be routed by the front door but NOT wrapped, reading X-Remote-User as the client sent it - the SM402 defect reintroduced by specification. Self-validation was chosen over wrapping because wrapping needs fleet vhost-template edits, whose staleness SM374 measured. THE EXTRACTION'S RISK WAS QUIET WEAKENING: auth.pl carried TWO verifiers - the full chain in the wrapper and a SUBSET in _session_identity that skipped the disabled-account and revoked-session checks; packaging the subset would have handed every future caller the gap. The module carries the FULL chain (parse, HMAC constant-time, both SM141 payload shapes, expiry, SM071 disabled, SM141 revocation incl. not_before for legacy cookies, SEC-2026-07 M5 fresh group resolution), _session_identity delegates and logout becomes deliberately stricter, and verification is READ-ONLY - it never mints the secret; minting stays with login where the 0660 group mode matters. Verified by t/unit/auth/14 against real state files with three biting sabotages: the subset packaged, groups taken from the cookie, a verify that mints. The cookie name and lifetime are module subs the script assigns from - one fact, one place (plain subs, not use constant: the house perlcritic profile forbids the pragma, which the landing rehearsal caught)."
---

# The one-sentence why

An identity check that exists once is auditable; one that exists twice is a
drift waiting for its field report - and one that a new surface cannot reach
becomes a client-supplied header, which is SM402's whole story.

# Source of truth

Commit b03bece, the 0.10.17 changelog section, and `t/unit/auth/14`. The
intended second caller is the data endpoint (SM410 DP-3, post-stable).
