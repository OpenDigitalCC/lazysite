---
id: SM1165
title: "SM1165: a write through the Odoo endpoint says which records it made"
subtitle: "The apply answer carries OOM's `created` (model to ids) for the records this caller's plan made, so a page can open the new record without reading it back."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-17
raised-by: lazysite-sites agent, OOM Lab quotation app (inbox, L-10)
area: odoo
status-note: "CANDIDATE, planned 2026-10-18: one function, built in wave 2 on n641's endpoint. OOM already returns the ids; lazysite drops them."
---

# The finding

OOM Lab, quotation app, L-10 (lazysite-sites agent, 2026-10-17): "A write
with `apply: immediate` answers counts and buckets but not WHAT it made: the
page cannot learn the new record's id. The lab's quotation page therefore
reads the order again by the key it was made with, one more call before it
can open it."

# Where it is lost

OOM's runner already reports what a plan made: its result carries
`created`, `written` and `unlinked`, each model to ids, for this plan's
changes only (`Odoo/Ops/Runner.pm`). lazysite's `_result_summary`
(`lib/Lazysite/Odoo.pm`) passes on `total counts by_bucket verified
stopped_by` and nothing else, so the ids stop there.

# The change

- `_result_summary` also passes `created` and `written` (model to ids, as
  OOM gives them), for `apply: immediate` and for a confirmed plan alike.
  `unlinked` stays out: a page has nothing to open.
- Nothing else of the runner's result is passed (the journal's path stays
  out, as it is today).
- The ids are the ones this caller's own plan made or changed. A read
  binding already shows ids, so this shows a page nothing it could not read.
- Test first: an `apply: immediate` create through the fake Odoo answers
  `created: { "sale.order": [id] }`, and a confirm of a planned create
  answers the same. Both fail today.
