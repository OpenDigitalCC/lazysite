---
title: "SM371 - an error page has no canonical, and only the 404 knew"
subtitle: "SM355's reasoning was never 404-specific, but its helper was only ever called from `not_found()`. The 402 and 403 pages render into the served tree carrying whatever canonical the layout emitted - and on a 402 that points at content the visitor was just refused."
brand: plain
status: shipped
status-note: "SHIPPED 2026-08-18. Covered by a test at the second sitting, after the first four fixtures failed to reach serve_403. Four attempts at a fixture reaching serve_403 produced an ACL refusal (a different branch, minimal body, no canonical to strip - so the assertion passed with the fix REMOVED), an anonymous 302 to login, and twice a plain 200. The first is the dangerous one: green, looked like coverage, and sabotaging the fix did not disturb it. Removed rather than approximated, with what would cover it written into the test file. Found by the site agent on edge; the canonical's PRESENCE is settled, the ?v= query it carried is not - see below."
---

# What SM355 established, and where it was applied

A missing page has no canonical URL. Not the requested path either - that would
assert a missing page is the canonical version of itself. And the cached file
lives in the served tree, so the front end answers `/404.html` directly at 200:
an indexable soft error page. Hence the strip, the `noindex`, and the rewrite of
the cache file.

Every word of that is true of a 402 and a 403. The helper was called from
`not_found()` and nowhere else.

# What the field found

On edge, `/402.html`:

```
<link rel="canonical" href=".../payment-members-demo?v=rv24596">
```

pointing at a **payment-gated page** - content the visitor was refused - and
carrying `?v=rv24596`, which was the reporter's own cache-buster from an
unrelated page sweep earlier that day.

`/404.html` on the same instance carries no canonical at all, so SM355 works on
the path it covered. The 402 path was never covered.

# What is settled and what is not

the canonical should not be there
: settled, and fixed. `serve_402` and `serve_403` now run the same sanitiser and
  rewrite their cache files, exactly as `not_found()` does.

how the `?v=` query got in
: **not settled.** The reporter tried to reproduce it as SM355's mechanism and
  failed: a different distinctive query did not change it, and after
  invalidating `/402.html` and re-requesting from a chosen path the canonical
  was still `?v=rv24596` although the file had been rewritten - mtime moved,
  size changed. `_inject_canonical` strips `[?#].*` from the path it builds, so
  it is not that. A layout emitting its own canonical would explain the query
  and not the persistence.

They filed it as an observation they could not explain rather than dressing it
up as a finding. That is the right instinct and the reason this filing can be
precise about its own scope: **stripping the tag removes the symptom on all
three error pages and does not explain the query**, and if the query is reaching
a canonical it may be reaching other things.

# Verification

- A 403 rendered by `serve_403` carries no canonical, in the response and in the
  cached `403.html`, and is marked `noindex`.
- The same for a 402.
- A real page keeps its canonical, unchanged.
- All of the above is asserted, and sabotaging the fix fails it. The four
  fixtures that did NOT reach `serve_403` are named in the test: the key is
  `auth_groups:` as an indented block, not `groups:`, so every attempt writing
  the latter left the required-group list empty and answered 200.

# Related

[[SM355]] (the 404 case, its live demonstration, and the reasoning this widens),
[[SM201]] (the system-page fallback chain these render through), and
`inbox/archive/2026-08-18-invalidate-cache-deletion-observed-live-and-a-discriminator-caveat.md`.
