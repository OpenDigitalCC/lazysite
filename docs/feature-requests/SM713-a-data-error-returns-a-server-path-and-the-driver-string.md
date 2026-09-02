---
id: SM713
title: A data error returns an absolute server path and the driver's own string
raised: 2026-09-01
raised-by: edge-testing agent (0.11.9 token-surface regression)
area: control-api
status: shipped
---

# What happens

A failed row save returns the driver's raw error in the `error` field:

```
DBD::SQLite::db do failed: no such table: ... at
/home/ispadmin/web/edge.explore.lazysite.io/cgi-bin/../lib/Lazysite/Data/Tables.pm line 453
```

Pre-existing, not a 0.11.9 regression, and the surface is authenticated and
capability-gated - which is why this is low severity rather than none.

# What is wrong with it

Three things, in increasing order of importance:

1. **An absolute filesystem path**, including the hosting account name and the
   site's directory layout.
2. **A source file and line number**, which describes the engine's internals to
   a client that has no use for them.
3. **The driver's own vocabulary.** `DBD::SQLite::db do failed` is not
   actionable by a caller. "no such table" is the part they can act on, and it
   is buried in the middle.

The first two are the ordinary argument against leaking internals to a client.
The third is the one that costs someone time: a caller has to parse an error
written for whoever was debugging the engine.

# Shape of an answer

The message a caller receives should say what they can act on - the table does
not exist - and the full driver string belongs in the log, where an operator
debugging the engine will look for it. That split is what the engine already
does elsewhere, and this path predates the convention rather than disagreeing
with it.

**Worth checking whether this path is the only one**, since a single leaking
call site is usually a family. The measurement to take before building anything:
how many control-API error returns pass a raw `$DBI::errstr` or `$@` straight
through.
