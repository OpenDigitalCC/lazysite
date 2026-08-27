---
title: "SM511: the cap reaches the page, and the page can say so"
subtitle: "SM502 U-1 made the manager honest about the 200-row cap. The db: page binding shares the same reader, had no pager and no total - a 250-row gallery rendered 200 looking complete, and an over-cap limit rendered zero."
brand: plain
standard-margins: true
status: shipped
status-note: "RAISED BY THE SITE AGENT 2026-08-24 (inbox filing), proved on edge 0.10.29: 250 rows imported, page rendered to row-200, the page's own .count said 200 - complete-looking and wrong, with no signal on the page, in the source, or in any log. Boundary-tested the second failure: limit=501 on a 9-row table rendered ZERO rows, no error - the parser's refusal never reaches a rendered page. And the two ceilings disagreed (ROW_CAP 500, select_sql 1000) for no stated reason. SHIPPED 0.10.30, one change per layer: MAX_ROWS=500 stated once in SQLite.pm (ROW_CAP delegates; select_sql clamps - the API's 501-1000 range is gone); an over-cap limit CLAMPS with a warning instead of refusing invisibly; the processor logs binding warnings AND capped renders (N of M, naming page and binding) and exposes the true count as <var>_total beside every list binding; .count is the TRUE count before the limit - the old after-the-limit choice was honest only while the page had no way to say capped, and <var>_total changed that calculus. The agent's authoring-practice guidance (hold list content in tables, render with db:) stands - this removes the trap it walked authors into at exactly the moment a site becomes worth something."
---

# The finding, proved on edge

A 250-row table, a `db:` binding with no limit: the page rendered 200
rows, its own `.count` said 200, and nothing anywhere said 250. Worse at
the boundary: `limit=501` against a 9-row table rendered **zero** rows -
the parser's cap refusal never reaches a rendered page.

# The fix, one change per layer

- **One ceiling.** `MAX_ROWS = 500`, stated once (SQLite.pm); the parser's
  `ROW_CAP` delegates to it and `select_sql` clamps to it. The API's
  unreachable-from-pages 501-1000 range is gone.
- **Clamp, loudly.** An over-cap `limit=` parses, serves the cap's worth
  of rows, and carries a warning.
- **The page can say it.** Every list binding gets `<var>_total` - the
  true count beside the (possibly capped) list - and the processor logs
  both binding warnings and capped renders, naming the page.
- **`.count` tells the truth** - the count before the limit. Counting
  after it was the honest choice only while the page had no way to say
  "capped"; `<var>_total` changed that calculus.
