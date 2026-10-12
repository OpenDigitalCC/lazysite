---
id: SM969
title: "SM969: A form outcome was written to the page cache and shown to the next visitor"
subtitle: "The outcome banner reads form= and outcome= from the query string, which the cache decision did not count - so a cold-cache request baked one visitor's link text into the page for everyone."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-07
raised-by: the SM869 adversarial review, second pass (WORK-PLAN-0153 Q11b)
area: security
status-note: "SHIPPED (0.15.3): a request carrying form= and outcome= is rendered for that request only - never read from or written to the page cache, as nocache: true is. t/unit/processor/90 (a visitor's outcome is not shown to the next) and 91 fail without it."
---

# What was wrong

The form outcome banner ([[SM415]]) is rendered from `form=` and `outcome=` in
the query string by convert_fenced_form. Neither is a declared `query_params`
name, so the request counted as query-free:

- with a warm cache it was answered from the cache, and the visitor did not see
  their outcome;
- with a cold cache - after any edit to the page - the render WAS the cache.
  The banner, carrying the text of whatever link was followed, was then served
  to every later visitor, with no query, in the alert style (`role="alert"`).

The text was escaped, so no markup; but it is a stored message on a public page
that anyone could place with one request after an edit.

Found while testing the banner sink: every request after the first showed the
first request's value.

# The fix

The dispatcher treats a request carrying both `form=` and `outcome=` as it
treats a `nocache: true` page: rendered fresh, never served from or written to
the page cache.

# Evidence

t/unit/processor/90 and 91 were committed with the banner checks marked TODO;
90 now also asserts the sequence directly (outcome, then a plain request, then
another outcome). Without the change they fail again.

# Related

[[SM415]], [[SM579]], [[SM869]].
