---
id: SM1165
title: "SM1165: a write through the Odoo endpoint says which records it made"
subtitle: "The apply answer carries OOM's `created` (model to ids) for the records this caller's plan made, so a page can open the new record without reading it back."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: lazysite-sites agent, OOM Lab quotation app (inbox, L-10)
area: odoo
status-note: "SHIPPED on n649: Lazysite::Odoo::_result_summary; t/unit/odoo/51."
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

# What shipped

`_result_summary` in `lib/Lazysite/Odoo.pm` now passes `created` and `written`
(model to ids, as OOM gives them) beside `total counts by_bucket verified
stopped_by`. It is the one function both apply paths use (`apply: immediate`
in `call`, and `action_odoo_confirm`), so the single endpoint, the batch
(each call goes through the same two), and a confirmed plan all answer it.
`unlinked` and the journal's path stay out. The browser helper
(`starter/assets/lazysite-odoo.js`) hands the endpoint's answer to the page
whole and needed no change. The apply answer is described in
`starter/docs/odoo.md` under the binding's `apply` key.

`t/unit/odoo/51-a-write-says-what-it-made.t` holds it against OOM's fake Odoo:
an immediate create answers `created`, an immediate write to the same line
answers `written`, a confirmed planned create answers the same as the
immediate one, and nothing outside the named fields is passed. All three
subtests fail on the base and pass now.
