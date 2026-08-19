---
title: "SM414: search results exist only in the browser"
subtitle: "A search-results page is byte-identical for a real query and a nonsense one - ?q= is never read server-side; a 73KB index is fetched and filtered by an inline script, with no noscript. Search results are invisible to crawlers and to any visitor without JavaScript, and the failure is silent."
brand: plain
standard-margins: true
status: candidate
status-note: "FILED 2026-08-19 from the site agent's beta-readiness field pass (brief archived at inbox/archive/2026-08-19-search-and-forms-both-require-javascript.md); DECISION HELD for the release manager - both the approach and whether it gates beta. NOT a regression: it has been this shape since search shipped; what changed is that somebody measured it. THE FINDING'S OWN METHOD IS WORTH KEEPING: the agent's first assertion - body matches /authoring/ - PASSED on the word 'Authoring' in the navigation menu, an expectation-based check passing on page chrome while the feature did nothing; comparing the real-query body against the nonsense-query body is what told the truth. A differential comparison can fail in a way an expectation cannot. THE SUGGESTED SHAPE (the brief's, and it is right in outline): read q server-side and render matches into the page, leaving the client script as progressive enhancement - the index already exists, the page never consults it. THE PART THAT NEEDS THE DECISION: /search-results is a cached page, and a per-query server body either bypasses the cache for ?q= requests or keys on q (a cache the visitor controls the key-space of - the SM389 class); query_params front matter exists and is the natural hook. Whether crawlable search results are even WANTED is a positioning question too (llms.txt and the registries already carry the crawl surface). Login is the in-product proof the no-JS pattern is achievable (302s, next preserved, no cookie on failure)."
---

# The measurement

`/search-results?q=authoring` and `/search-results?q=zzzz-nonsense` on edge at
0.10.16: **byte-identical server bodies**. The 73,688-byte `/search-index` is
fetched by an inline script and filtered in the browser. No `<noscript>`.

# Why it matters, in the brief's own terms

Search results are not crawlable; a no-JS visitor who searches and sees nothing
assumes there is nothing; and the site owner sees no error because server-side
nothing went wrong. It is out of step with the platform's own positioning -
server-rendered, works everywhere - on one of the two things a small site most
needs.

# What is held for the decision

Approach (server-side rendering keyed how, against which cache posture), scope
(is a `<noscript>` statement the honest v1?), and whether any of it gates beta.
