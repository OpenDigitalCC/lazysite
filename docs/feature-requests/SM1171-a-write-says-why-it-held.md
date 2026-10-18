---
id: SM1171
title: "SM1171: a write through the Odoo endpoint says why a change was held"
subtitle: "The plan answer carries each change's reason, and the apply answer lists every change with its outcome, its reason if held and a custom change's returned value."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-18
raised-by: lazysite-sites agent, OOM Lab stock and picking apps (inbox 2026-10-17-oom-lab-stock-and-picking-apps-findings.md, L-13)
area: odoo
status-note: "SHIPPED on n660: Lazysite::Odoo::_result_summary, _applied_changes, _preview; t/unit/odoo/52."
---

# What happened

OOM Lab, stock and picking apps, L-13 (lazysite-sites agent, 2026-10-17): "An
applied write answers `counts` and `by_bucket` only: the hold REASON, created
ids and a change's `returned` value (e.g. the backorder's name) never reach
the page. The stock app added a read that re-runs the decision to explain a
hold; the picking app maps bucket names to messages and re-reads. Extends L-10
(created ids): carrying `reason` and `returned` per change in the result
summary would serve both."

# Where it is lost

OOM's result holds only counts and the model-to-ids maps (SM1165 took those).
A change's `reason` and `returned` are in the plan (reason) and in the
journal OOM writes during the apply (every change, with its outcome, reason
and `returned`). lazysite passed neither on, and the plan view dropped the
reason.

# What shipped

- `preview.changes` (the plan answer) carries `reason` beside `seq`,
  `bucket` and `action`, so a page can show why a change will be held before
  the confirm. Values and before-images stay out, as before.
- `result.changes` (immediate and confirmed apply) lists, per change: `seq`,
  `bucket`, `action`, `model`, `id` if any, `outcome`, `reason` for a held or
  skipped change, and `returned` for a custom change. It is built from the
  journal OOM kept (read inside the engine; the journal's path is not
  passed), and nothing else of the entry is: no values, no before-image, no
  handler, no host path. A failed change carries no reason, since Odoo's
  message stays in the log. A journal that cannot be read gives an empty
  list; the counts still stand.
- `returned` is the handler's own answer and has no size of its own, so it is
  capped: past 4 KB (of its JSON) it is cut and ends `...[truncated, N
  bytes]`, so one change cannot make the answer as large as a handler chose.
  On OOM 0.32 a value over `blob_min` (64 KiB) is in the journal as a blob
  reference; it is read back from the journal's folder and capped the same
  way, and one that cannot be read answers the marker alone (found stacking
  on SM1167's 0.32 snapshot).
- Documented in `starter/docs/odoo.md` beside SM1165's `created` and
  `written`.

`t/unit/odoo/52-a-write-says-why-it-held.t` holds it against OOM's fake Odoo
with a test operation (`shop.ship`: a hold, a create and a custom change):
the plan shows the reason, the immediate and confirmed answers carry reason
and returned, an oversized returned is capped with its marker, and neither a
value the caller did not send nor the journal's path is in any answer.
`t/unit/odoo/51` now allows `changes` among the fields passed.

# Found on the way

A custom change whose handler lives in a site pack (`odoo_packs`) fails at
apply: lazysite sets `ODOO_OPS_NAMESPACES` for the operation lookup only
(`registry`), and OOM's runner builds its own default registry when it applies.
OOM's own handlers (`core.action`, `core.wizard`, ...) are unaffected, which is
what the Lab uses. The test sets the variable for its process; whether the
engine should set it around the apply is not decided here.
