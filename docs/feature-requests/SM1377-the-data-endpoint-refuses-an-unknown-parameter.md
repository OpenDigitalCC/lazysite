---
id: SM1377
title: "SM1377: the data endpoint refuses a query parameter it does not read"
subtitle: "SM606 named an unknown parameter and still answered every row. Ruling 131: an unknown parameter is a 400 with its own kind, and the cache-buster `_` is the one name accepted."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-06
raised-by: "release manager (ruling 131)"
area: data
status-note: "SHIPPED (PENDING) on n760, ruling 131: lazysite-data.pl refuses an unknown query parameter, 400 kind unknown-parameter naming it and the four it reads; `_` accepted and unread. Ruling 139: the control API data-rows refuses one the same way. Supersedes SM606 in part. t/integration/355."
---

# What happened

`/cgi-bin/lazysite-data.pl` builds its binding from `order_by`, `order`,
`limit` and `offset`. Since SM606 any other parameter was named in an `ignored`
list and a warning, and the reply was still 200 with every row the caller may
read. A script that did not read `ignored` showed every row as the subset it
asked for.

# What shipped

Ruling 131:

- **Refused.** A parameter outside `table`, `order_by`, `order`, `limit`,
  `offset`, `csrf` and `_` answers 400:
  `{ ok: 0, kind: "unknown-parameter", parameters: [...], error }`. The error
  names each unknown parameter and the four the endpoint reads.
- **`_` is accepted and unread.** It is the ordinary cache-buster
  (`?table=t&_=1700000000`).
- **Unchanged:** the four read parameters, `table`, `csrf=1`, and the 400 for a
  bad value.
- **Removed:** SM606's `ignored` field and its warning line.

# Callers checked

The shipped helper `starter/assets/lazysite-data.js` sends `table`, `order_by`,
`order`, `limit` and `offset` only. No shipped page, layout, template or example
calls the endpoint with any other parameter. The bench (`tools/bench-surfaces.pl`)
sends `table` only. The docs that said "ignored, not refused" (FEATURES.md,
/docs/data-tables, the practice notes and their briefing copy) now say refused.

# The control API's data-rows (ruling 139)

Ruling 139 (release manager, 2026-11-06): the control API's `data-rows` action
refuses an unknown parameter the same way, kind `unknown-parameter`. It was a
separate surface that read the same four and ignored the rest.

What it reads
: `table`, `order_by`, `order`, `limit` and `offset`, the parameters its
  declaration in `Lazysite::ControlApi::Actions` lists, and `action`, which the
  dispatcher reads. `_` (a cache-buster) and `csrf_token` (the CSRF gate's
  last-resort channel for a POST) are accepted and unread.

What it answers
: Any other query parameter is a 400,
  `{ ok: 0, kind: "unknown-parameter", parameters: [...], error }`, the error
  naming each one and the five it reads, before any row is read
  (`_data_rows_unknown_parameters` in `lazysite-manager-api.pl`). The manager's
  Data page sends `table`, `limit` and `offset` only; MCP `read_data_rows`
  already refused an unknown argument by its schema.

Test
: t/integration/355's last subtest, through the manager API CGI; it fails with
  the refusal removed.
