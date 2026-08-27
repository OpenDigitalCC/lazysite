---
title: "SM588: the partner brief said a nav PUT is refused; it is accepted, by design"
subtitle: "A WebDAV PUT to lazysite/nav.conf succeeds for a manage_nav grant - a deliberate carve-out - while the brief the operator hands out states in as many words that it returns 403."
brand: plain
standard-margins: true
status: shipped
status-note: "FOUND BY THE SITE AGENT 2026-08-25 on 0.10.32 while closing SM536, with a grant holding api/manage_nav/mcp/webdav: PUT /lazysite/nav.conf returned 204 while every other path under lazysite/ refused in the same minute with the same grant (zz-probe.txt, lazysite.conf, auth/zz.txt, forms/handlers.conf), so the blocklist was working and nav.conf specifically was reachable. THE ENGINE IS RIGHT AND THE BRIEF IS WRONG, both established from code without further probing: Capabilities.pm lists webdav => ['lazysite/nav.conf'] under manage_nav, and Common::carveout_requirement returns caps => ['manage_nav'] for that exact path - so the carve-out is deliberate AND it gates on manage_nav, which answers the agent's second question (a webdav grant without manage_nav is refused) without needing the grant they declined to ask for. SHIPPED 0.10.33: the brief paragraph in tools/lazysite-users.pl now says what is true - the PUT is accepted with manage_nav, and the control API is preferred because it parses, invalidates the cache and reports what changed, where a raw PUT replaces the file wholesale with no validation. FILED ALONGSIDE SM573, which proposes generating the brief's capability block from the account: this is the same class - a hand-written brief asserting engine behaviour that nothing checks - and it is the second instance found in one day."
---

# What the agent did to edge, recorded

Their probe PUT the single character `x` into the live nav file; it
succeeded, and their next call restored the nav via `nav-save`. The
window was seconds and nothing was left broken. They also recorded that
their own rule - never probe a gate with a live target - would have had
them use `/lazysite/zz-probe.txt` first, which refuses, and would have
shown the blocklist working without touching anything real. Right answer,
wrong route, said plainly.

# Proving test

A generated brief for a `manage_nav` partner does not claim the nav PUT
is refused; SM573's generator is where that stops being possible by hand.
