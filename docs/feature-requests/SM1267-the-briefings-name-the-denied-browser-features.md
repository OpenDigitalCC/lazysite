---
id: SM1267
title: "SM1267: the briefings name the denied browser features"
subtitle: "The authoring and layouts briefings list every feature Permissions-Policy denies and say how a page asks for one, so an author learns it before a visitor reports it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: "lazysite-sites agent for the OOM Lab, inbox/2026-10-22-site-chosen-permissions-policy-and-the-visitor-address-for-an-operation.md row P-7; SM710 \"Also worth doing, and cheaper\""
area: docs
status-note: "SHIPPED (PENDING) on n729: starter/docs/ai-briefing-authoring.md and ai-briefing-layouts.md. t/lint/280."
---

# What happened

[[SM710]] recorded that "the authoring and layouts briefings say nothing about
these features being hard-denied by the platform. An author can ship a
microphone feature that cannot work and get no warning until a user reports it."
That was still true: neither briefing named Permissions-Policy, and only
starter/docs/frontmatter.md described `camera: self` ([[SM1174]]). Row P-7 asked
for the denied list and the way to ask to be documented in both.

# What shipped

- The authoring briefing's front matter keys list an entry for the browser
  features: the twelve denied, why a script cannot even prompt under `=()`, the
  page key `<feature>: self` ([[SM1266]]), https only, what the validator reports,
  that `payment` cannot be asked for, and that the names are reserved keys rather
  than page variables.
- The layouts briefing gains a section: a layout or theme script that calls
  `getUserMedia`, `navigator.geolocation` or a sensor API fails on every page, no
  layout or theme setting changes it, and the page that uses the component is what
  asks. `autoplay`, `fullscreen` and `picture-in-picture` are not denied.
- t/lint/280 reads `@DENIED_FEATURES` from the module and fails when either
  briefing leaves a feature out, or stops saying how a page asks and that it holds
  over https only; and when starter/docs/frontmatter.md leaves out a feature a page
  may ask for. A feature added to the list without a word in the docs fails there.

The site-level half of the request (P-5, "how a site asks") is not documented,
because it is not built: the ruling put it later.
