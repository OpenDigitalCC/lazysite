---
title: "SM214 - form-list read action for token clients (+ clarify the submission-delete exclusion)"
subtitle: "A token client with manage_forms or read_submissions can read a submissions store but cannot discover what forms exist - plugin-list/handler-list are cookie-manager-only, PROPFIND on forms/ is 403, and llms.txt only helps for registered form pages. An agent asked 'were any forms submitted?' must guess store names. Add a small, PII-free form-list action; and either comment or open up the token-excluded form-submission-delete so its status is intentional, not an apparent oversight."
brand: plain
status: candidate
status-note: "PROPOSED 2026-07-27 by the lazysite.io site agent (inbox note, found reading cloudient.net submissions over the control API). Small, read-only, PII-free. Two parts: (1) a form-list control-API action + MCP counterpart gated manage_forms|read_submissions; (2) a decision on form-submission-delete's token exclusion (comment it as deliberate, or allow it for a manage_forms token client). Candidate for a stats/connector follow-up beta."
---

# SM214 - form-list read action for token clients

## Why

A token client (control API / MCP, not a cookie manager) with `manage_forms` or
`read_submissions` can read a submissions store (`form-submissions&file=<name>`)
but has no way to discover which forms exist:

- `plugin-list` / `handler-list` answer "Action not available to token clients"
  (cookie-manager-only).
- `PROPFIND /dav/lazysite/forms/` is 403 - only the individual `<name>.conf`
  carve-out is granted, not the directory listing.
- `llms.txt` only lists a form page when it is registered; on cloudient.net the
  two busiest form pages are unregistered, so page-slug guessing misses exactly
  the stores that matter.

So an agent asked "were any forms submitted?" must guess store names by
convention (contact/support/feedback + `/forms/` slugs). A small read action
retires the guessing.

## Request

`form-list` - a control-API action plus an MCP counterpart, gated
`manage_forms | read_submissions`, returning per form:

- the config name (basename of `lazysite/forms/<name>.conf`),
- its handler type (smtp / file / webhook),
- whether a submissions store exists and its row count.

Read-only and PII-free (names and counts only - no submission content), so the
`read_submissions` gate is arguably the more natural of the two. One call answers
both "what forms are there?" and "which deliver to email rather than storage?".

## Related design question (decide, then document)

`form-submission-delete` is excluded from token clients (the token-exclusion list
in `lazysite-manager-api.pl` ~446) even though the capability table gates it on
`manage_forms` (~428). Two clean outcomes:

- If deliberate (destructive PII operations stay interactive-only): add a comment
  by the exclusion list saying so, so it does not read as an oversight.
- If not: allow a `manage_forms` token client to call it, for housekeeping the
  spam rows it has just identified (e.g. the single SEO-spam row currently sitting
  in cloudient.net's contact store, flagged to the operator for manual deletion
  today).

Either way the intent should be explicit in the code.

## Notes

- Enforcement is unchanged; this only adds a read surface and clarifies one
  exclusion. Additive, `schema_version`-safe.
- Pairs naturally with the connector/stats work; a good candidate for the next
  connector-focused beta.

Related: `lazysite-manager-api.pl` (the action dispatch + token-exclusion list),
`Lazysite::Manager::*` form handling, the `read_submissions` capability (SM187),
and the site agent's inbox note (archived
`inbox/archive/2026-07-27-form-list-request.md`).
