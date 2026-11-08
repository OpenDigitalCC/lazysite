---
id: SM1382
title: "SM1382: live data is a scheduled connector answer in a table row"
subtitle: "Ruling 132, B: the chain the docs claim - schedule, connector handler, remote, table row, page - proved end to end on a scratch site, and written up as the one sanctioned live-data recipe with its limits measured."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "release manager (ruling 132)"
area: data
status-note: "SHIPPED (0.16.7) on n763, ruling 132 B: t/integration/360 drives the chain against a 127.0.0.1 JSON source; the Live data section of /docs/ai-briefing-building-sites states the limits it measured: 300 s floor, multiples of 300, fixed fields, one row per poll, mode=live inert. 0.16.8 (SM1357): a table write refreshes a ttl: page that reads it."
---

# What was asked

Ruling 132, B: spike the live-data chain the docs claim, then document it as
the sanctioned pattern. An outside live-data process is not ported into
lazysite; it stays its own engine.

    schedule (interval, run_jobs account)
      -> connector handler -> remote source -> a data-table row
      -> page binds db: (or a data-ls-db region reads /cgi-bin/lazysite-data.pl)

# The spike

`t/integration/360` builds a scratch site, starts a JSON source on 127.0.0.1
that numbers its answers, and drives the scheduler through its clock (`now`)
rather than by waiting. **The chain holds at every link.** Measured, on
792a0413b:

| Question | Observation |
| --- | --- |
| Minimum interval achieved | **300 s.** An entry with `every: 300` polls at +300 and +600 and not at +60, +299 or +360. Below 300 is refused at save (`at least 300`). The engine job that runs the schedule is itself every 300 s, so an interval rounds up to a multiple of 300: `every: 450` polls every 600 s. On the wall clock add up to one daemon tick (`daemon_tick_seconds`, default 60). There is no 60 s floor and no faster path. |
| A hand-written entry under 300 | Never runs. At the spike it was skipped in silence; ruling 148 (SM1391) makes it a recorded refusal, once, and `lazysite check` names it. |
| Fixed fields | Each poll sends the same fixed payload (as the GET query). A static request suffices for a single-call source. A sweep over N items is N entries; a payload cannot carry a list (`fixed values only`); every entry through one connector counts against its rate cap (3/hour in the test: the fourth of four was refused, recorded `failed`, `rate cap`). At the default 60/hour, five entries at the floor fill a connector. |
| Row shape | One new row per poll (nothing is replaced): `connector`, `call_id`, `mode` (`scheduled`), `actor` (the job account), `at`, `state`, `http`, `answer`. `answer` is the remote's whole JSON as one text value, rendered by a template as escaped text. The engine never prunes the table: 288 rows a day per entry at the floor. |
| Fresh rows without a cache clear | Yes. A page with no `ttl:` shows the newest row on its next request. |
| `ttl:` | At the spike (0.16.7), the only bound: a `ttl: 300` page served its cached render until the ttl passed, then showed the newest row. From 0.16.8 (SM1357) every table write touches the table's change stamp, so a `ttl:` page that reads the table shows the new row on the first request after a poll; the ttl still bounds a page whose table did not change. `t/integration/360` holds both, with the stamp's and the render's times set explicitly (n780: the old assertion passed only when the poll and the render fell in the same second). `mode=live` behaves identically to snapshot. `mode=client` still reads rows at render; the data-tables reference said otherwise and is corrected. |
| The endpoint | `table=..&order_by=id&order=desc&limit=1` answers the newest row with `Cache-Control: no-store`; `&since=0` is a 400 `unknown-parameter` (SM1377); `_` is accepted. |
| Per-poll cost | One scheduler tick with one due entry: about 55 ms against a local source (one HTTP call, one row, one call-record line, one audit line). One data-endpoint read: about 145 ms on the test host (a CGI start). |

# The cost is in the sweep, not the poll

A poll's cost is small and does not grow with visitors; a visitor's read of the
endpoint is one request, small at low visitor counts. How live the data can be
is decided by where the sweep runs - the scheduler, at a 300-second floor,
running its jobs one after another so a slow source holds the rest for up to
its connector's timeout - not by what a poll costs. Polling from the browser
faster than the schedule shows nothing newer.

# What shipped

- The "Live data" section of `/docs/ai-briefing-building-sites`: the parts, what
  a poll leaves behind, and the limits, each traced to a subtest of
  `t/integration/360`. The page's subtitle and the `/docs/` index entry name it.
- The `client` row of the binding-modes table in `/docs/data-tables`, corrected.

Discovery: the briefing is already one of the pages `describe_capabilities`
lists under `docs`. It is not added to `llms.txt`: lint 46 holds that shipped
documentation registers for `sitemap.xml` and not `llms.txt`.

# Left open

- `mode=live` is inert and `mode=client` reads rows at render; whether either
  should come to mean something is a design question, not this filing's.
- SM1384: a multi-step job protocol cannot be expressed (filed apart).
