---
title: "SM415: a form post without JavaScript lands on raw JSON"
subtitle: "form-handler.pl answers application/json for success AND failure - with HTTP 200 on failure - and the form carries a native action/method, so a no-JS client posts natively and is shown JSON as a page. Login already implements the pattern the forms are missing."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.29, in the brief's suggested shape with the held decisions decided: CONTENT-NEGOTIATE - the chrome JS now declares Accept: application/json and keeps today's reply byte-for-byte; a native browser post is answered 303 back to the page named by a _page hidden field the renderer embeds, carrying form=<name>&outcome=ok|<user-safe text>, and the :::form renderer shows the outcome as a banner above the form (success line, or the refusal text the handler already deemed safe to show). THE DECISIONS: the redirect lands on the FORM'S OWN PAGE via the embedded field, not Referer (nothing user-controlled is trusted: _page is validated as a same-site absolute path - no scheme, no protocol-relative //, no CRLF, capped - and an invalid or ABSENT _page answers JSON, so a stale cached page is never redirected to nowhere and the field cannot become an open redirect; t/unit/forms/09 holds both). Failure redirects DO NOT re-present typed values in this cut - recorded, and SM501 already points here as the real protection for typed work, so that half is the known follow-on. The SM402 capture-method question is MOOT: no such field exists. The HTTP-200-on-failure wart is half-fixed by construction (native failures are 303s; the JS path keeps its 200-with-ok:0 contract untouched, because changing it breaks the shipped chrome mid-fleet). The banner renders only for the form whose name matches, so two forms on a page banner correctly. ORIGINAL NOTE: FILED 2026-08-19 from the site agent's beta-readiness field pass (briefs archived at inbox/archive/2026-08-19-form-submission-requires-javascript.md and ...-search-and-forms-both-require-javascript.md); DECISION HELD for the release manager. NOT a regression - measured for the first time, shipped this way always. What works is worth restating: all three spam controls (zero dwell, honeypot, bogus token) refuse WITHOUT storing, with a deliberately uninformative message, and storage/notification are correct - the JS path is healthy; the finding is the absent no-JS path. THE SUGGESTED SHAPE (the brief's): content-negotiate - an Accept carrying application/json keeps today's reply; anything else gets the login pattern, a redirect carrying the outcome, which fixes the HTTP-200-on-failure question at the same time. THE PARTS THAT NEED THE DECISION: where the redirect lands (back to the form's page needs the ::: form block to render an outcome from a query param - a template-facing change with SM374-class fleet staleness exposure), whether failure redirects re-present the values (they are gone unless something carries them), and whether the SM402 capture-method field distinguishes native posts. Related decision from the same pass: static-asset revalidation is 6 engine requests per page view where it was 1 - probably the intended trade, worth CHOOSING rather than discovering (the agent's words)."
---

# The measurement

Five submissions from outside on edge at 0.10.16: the handler answers
`application/json` for both outcomes, HTTP 200 for both, and the `<form>`
carries a native `action`/`method` - so a client without JavaScript posts
natively and is shown raw JSON as a page. The visitor does not report it; the
owner sees nothing wrong, because server-side nothing went wrong.

# Login is the counter-example

302 redirects, `next` preserved, no cookie on a failed credential, no
JavaScript needed. The pattern exists in the product; forms and search are the
two surfaces that missed it.

# What is held for the decision

The negotiate-vs-redirect shape, where a native post lands, whether failures
re-present values, and whether any of it gates beta.
