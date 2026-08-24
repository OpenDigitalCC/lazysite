---
title: "SM429: cross-origin-opener-policy is not emitted, on any path or version"
subtitle: "The one line that survived the field's header pass. A gap rather than a regression - the engine has never sent it - and adding it interacts with two things this codebase actually does."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.29, at the filing's own recommended value: same-origin-allow-popups, on HTML responses only, beside the CSP in both copies of the header set (the SecurityHeaders module and the processor's ADR-0001 pinned copy - t/lint/55 holds them equal by value). The strict same-origin was rejected for exactly the two interactions the filing names: the manager opens the site in a new tab, and the OAuth popup flow depends on the opener handing the result back. AND THE FILING'S TEST RECOMMENDATION FOUND A BIGGER GAP THAN THE HEADER: driving the real authorize page showed lazysite-oauth.pl hand-prints every response and carried NO security headers at all - the consent page, an authorisation surface, answered without nosniff, frame-options, referrer-policy or anything else, having predated SM352's consolidation. The consent page now emits the full html set from the module; t/integration/70 registers a client through the script's own endpoint and asserts the set on the real page, and t/integration/44 asserts COOP on pages and its absence on stylesheets. ORIGINAL NOTE: FILED 2026-08-20 from the site agent's 0.10.18 field pass. Their CSP half was retracted after re-measurement (the policy IS served, under the report-only name, on HTML pages and correctly not on non-HTML paths); COOP is the part that stands. NOT A REGRESSION: `grep -ri opener` over the whole tree returns nothing, so it has never been emitted on any path or version. DECISION HELD, because adding it is not free here and the interactions are specific rather than theoretical - see below. My recommendation if it is wanted: `same-origin-allow-popups`, which is the value that keeps both of the behaviours this codebase relies on working, rather than the stricter `same-origin`."
---

# What it would do

COOP severs the `window.opener` relationship between a page and anything it
opened, or that opened it - the mitigation for cross-window attacks against a
document that shares an origin-adjacent context.

# Why it needs a decision rather than a default

Two things in this tree open windows, and one of them is an authorisation
surface:

the manager opens the site in a new tab
: `appearance.md` (`window.open('/', '_blank')` after stopping a preview) and
  `plugin-config.md` (opening a plugin's result URL). Under a strict
  `same-origin`, the opened window loses its opener reference. Neither of
  these currently *uses* the opener, so both would survive - but that is a
  property of today's code rather than a guarantee.

the instance is an OAuth authorisation server
: `oauth_enabled` exposes authorize/token endpoints for AI connectors.
  Popup-based OAuth flows are the normal shape for a connector, and they
  depend on the opener relationship to hand the result back. A strict
  `same-origin` on the authorize page is the classic way to break that,
  usually discovered by a partner rather than by a test.

# Recommendation, if it is wanted

`same-origin-allow-popups` on HTML responses only, beside the CSP in
`_security_headers` - which isolates the document from anything that opened
IT, while leaving windows it opens able to talk back. That keeps both
behaviours above working.

It is worth pairing with a test that actually opens the OAuth authorize page
and asserts the header, rather than asserting the string appears in the
source - the failure mode here is a partner's flow breaking in a browser,
which no processor-level test can see (the SM380 lesson about inline handlers,
one layer out).
