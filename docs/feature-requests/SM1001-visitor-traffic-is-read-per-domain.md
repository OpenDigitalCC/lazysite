---
id: SM1001
title: "SM1001: visitor traffic is read per domain, and a confined caller reads only its own"
subtitle: "The visitor log recorded the host since SM151 and nothing read it: a multi-domain instance could not answer a per-domain question, and every caller with analytics read every domain's traffic."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-11
raised-by: the dev inbox (2026-10-11, the visitor log does not say which host, item 2); WORK-PLAN-0154 P15; ruling of 2026-10-12
area: analytics
status-note: "SHIPPED (0.15.5): analyse_visitors takes host and by_host on both surfaces through Manager::Services::visitor_scope_args; stats.pl --host/--by-host count from the raw log by serving domain; a confined caller is held to its own domains and refused the instance-wide selectors (t/integration/134)."
---

# The ruling

"Record host": each visitor-log event carries the served host; analyse_visitors
filters/groups by host; a confined caller sees only its own domains' traffic
(SM976 rule). Counting basis note if the report shape changes.

# The record

Each first-party event has carried `h`, the request's sanitised Host, since
SM151 (lazysite-processor/access-log.pm); absent for a missing or malformed
Host. The record is unchanged. What it is read as is new: **the serving
domain** of an event is its host when that host is in `alias_hosts`, and the
primary (`(default)`) for any other - the primary's own name, a `www` form
nobody registered (the reported case: it was served the primary's site), or no
host at all. `_served_domain_fn` (plugins/stats.pl) reads `alias_hosts` from
lazysite.conf as text.

# The report

- `--host NAME` (repeatable, `(default)` for the primary): the windowed view for
  those domains only. It is built from the raw first-party log, filtered by
  serving domain, into an ephemeral cache - the same ingest, tally and assembly
  as the instance's view, so a domain is counted exactly as the site is - and
  never persisted: the durable day files, the export cache and the trails stay
  the instance's. It reaches as far back as the raw log does (`retention_days`).
  Form outcomes carry no domain and are left out. The reply adds `hosts` and
  `host_basis`.
- `--by-host`: `by_host = { basis, domains: { name: { requests, visitor_days } } }`
  over the window, from the raw log, every class of visitor counted (the class
  is a visitor-level verdict over the whole site; a domain's own split is its
  `host` view). Visitor keys are salted daily, so the unique count is
  visitor-days, and the basis says so.
- `--host` with `--index`, `--day`, `--month` or `--trails` is refused: those are
  the durable records, not split by domain.

The report's shape grows only when asked (`host`, `by_host`); the window view
asked for without either is byte-for-byte the shape it was, and its
`counting_basis` is unchanged.

# Who may read what

`Lazysite::Manager::Services::visitor_scope_args` is the one reading for both
surfaces (the control API's analyse_visitors and MCP's): it validates `host`
against the instance's domains, asks `domain_reach_refusal` of it, and for a
**confined** caller (a grant passed as scopes - every MCP grant - or a
confined manager request) with no `host`, filters to every domain
`caller_may_reach_domain` admits. A confined caller is refused the index,
rollups and trails, and one reaching no domain is refused outright. A confined
caller reaching every domain of the instance (any one-domain instance) is
treated as unconfined: nothing changes there.

**A narrowing to note.** By SM975 an MCP grant with no scope reaches the
primary only, so on a multi-domain instance its analyse_visitors now shows the
primary's traffic where it showed every domain's. That is the SM976 rule as
every other domain-addressed tool applies it.

# Tests

t/integration/134 (three domains, five hosts of traffic): the unconfined
operator reads all; `host=mine.test` reads mine.test's only and names it;
`host=(default)` reads the primary's own name, the unregistered www host and the
host-less event; `by_host` counts 6/2/2; an unknown host and a rollup with host
are refused. An MCP grant scoped to mine.test reads only mine.test's traffic,
is refused other.test and the primary, the index and a day, and its `by_host`
names only mine.test. An unscoped MCP grant reads the primary's only.
t/unit/manager/205 and 215 now give boss's request the unconfined cookie
manager's context, which the analysis asks for since this change.
