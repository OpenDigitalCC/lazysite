---
title: AI briefing - visitor analytics
subtitle: Guide for AI assistants analysing a lazysite's visitor traffic for trend reporting.
register:
  - sitemap.xml
---

## Who this is for

This briefs an AI assistant that the operator has asked to analyse visitor
trends for this site. You get the data from the `analyse_visitors` tool (it needs
the `analytics` capability). The operator directs the analysis - this doc tells
you how to read the data and what you can honestly report.

## How to get the data

Call `analyse_visitors` with an optional `window` (days, 1-365, default 30). It
returns a sanitised JSON summary built from lazysite's first-party access log
(recorded by the site itself, anonymised at write; the web-server access log
is the fallback source when no first-party data exists). You never
see the raw log, any filesystem path, or a visitor's IP address: the tool
aggregates and anonymises before anything reaches you. Repeated calls are cheap -
the data is cached and only new log lines are processed each time.

### On an instance serving several domains

Every request in the log records the host that served it. A host listed in
`alias_hosts` is its own domain; any other host (the primary's own name, a `www`
form nobody registered) was served the default site and counts as the primary,
`(default)`.

- `host` - one domain's traffic only (`host: "(default)"` for the primary). It is
  counted from the raw log, as the whole instance's is, over as many days as the
  raw log keeps (`retention_days`); the reply names the domains in `hosts` and
  explains its basis in `host_basis`. Form outcomes carry no domain and are left
  out. `index`, `day`, `month` and `trails` are the instance's durable records,
  not split by domain, so they cannot be combined with `host`.
- `by_host: true` - adds `by_host`: page requests and visitor-days (a visitor key
  is salted daily) per serving domain over the window, every class of visitor
  included, with its `basis`.
- A grant confined to some domains sees only their traffic, whether or not it
  asks for a `host`, and is refused `index`, `day`, `month` and `trails`. One
  that reaches no domain is refused. On a one-domain instance nothing changes.

## What the data means

The response has these fields:

```
window           { days, from, to }            the period covered
schema_version   "3"                            the shape of this reply
counting_basis   5                              HOW these were counted
counting_basis_in_window  [ 5 ]                 more than one = a mixed window
totals           { pageviews, asset_hits, error_hits, unique_visitors }
traffic_classes  { unattributed|no_agent|ai|bot|noise|scanner:
                   { visits, share, visitors } }
by_day           [ { date, unattributed, no_agent, ai, ... } ]  one row per day
window_scoped    { by_day: true, months: false, ... }  which fields the window governs
top_pages        [ { key: "/path", count } ]   most-visited pages
referrers        { direct, internal, external: [ { key: host, count } ] }
status_codes     { "200": n, "404": n, ... }
not_found        { plausible: [...], junk_count: n }   missing pages vs scanner noise
auth_refused     [ { key: "/path", count } ]   turned away, NOT missing
events           [ { t, class, path, status, visitor } ]   recent requests
events_capped    true if the event stream hit its size limit
```

### The three counters in `totals` add up

```
pageviews + asset_hits + error_hits == traffic_classes.unattributed.visits
```

`pageviews` is a successful page, `asset_hits` a successful image or file, and
`error_hits` anything that returned 400 or more. Check that identity when you
read a report: it holds by construction, and if it does not, say so rather than
reporting either number.

`unique_visitors` counts the `unattributed` class alone - the same group
`pageviews` counts, so the two are comparable. Per-class visitor counts are in
`traffic_classes[].visitors`.

### `counting_basis` - before you compare two reports

A day's numbers only mean anything beside another day's if both were counted the
same way, and the way has changed over time. The current basis is **5**.

`counting_basis_in_window` lists every basis the window actually contains. **If
it holds more than one entry, the totals add together days counted differently**
and a step in `by_day` is the upgrade, not the traffic. Say so; do not report the
step as a trend.

Basis 4 (lazysite 0.15.2) was a large correction: requests with no user-agent,
responses of 400 or more, and socket endpoints all left the visit count. **Counts
fell sharply** on upgrade. A report comparing before and after must name the
basis change or it is describing an engine change as a loss of audience.

Basis 5 (lazysite 0.15.3) applies the site owner's rule for pace: **more than
five page views from one source, each under ten seconds after the last, is a
bot**. That source moves from `unattributed` to `bot`, including its earlier
page views. One or two requests never move (there is no run to judge), and a
gap of ten seconds or more starts the count again. `unattributed` steps down on
upgrade; the day rollup's `bot_paced` counts what moved, so the change can be
inspected rather than taken on trust.

A source is the visitor token and the user-agent together, and on a server log
the token is the address with its last part zeroed. Several people behind one
network with identical browsers, clicking quickly at the same moment, can
therefore read as one fast source. The scanner rule has the same limit.

A day rollup (`day=YYYY-MM-DD`) additionally carries:

```
bot_paced        n                              requests moved to bot by pace (basis 5)
registry_hits    n                              generated registries served
registry_by      { "sitemap.xml": n, ... }       which one, and how often
```

These are the engine's generated files - the sitemap and the feeds - fetched
mostly by crawlers. They are counted **beside** `pageviews` and never inside it:
a sitemap fetch is not a page view, and folding it in would inflate the one
figure an operator reads as their audience. Read them as interest from search engines
and AI crawlers rather than as traffic.

### auth_refused

Paths a visitor was **turned away from** - a page or file that exists and that an
access rule refused. It is separate from `not_found` because the two need
different actions: a 404 means write the page, a refusal means check who is meant
to be able to read it.

It is its own field rather than a status-code slice because the status cannot
carry it. An anonymous refusal is a 302 to the login page, identical in the log
to every other redirect.

**A file in this list that you believe is public is the finding.** It means an
access rule is refusing it - most often an ACL `read` list. Since 0.10.5 that
list governs the public read path as well as the authoring channels, so an entry
originally written to keep other editors out of a file now also keeps anonymous
visitors out of it. That is usually what was wanted; occasionally it is not, and
this is where it shows.

`unique_visitors` is approximate - it counts anonymised networks, not people.
`visitor` in an event is a short, non-reversible token for the request's network,
so you can group events into rough sessions/flows without identifying anyone. `t`
is a Unix timestamp.

## The traffic taxonomy

Every request is classified by a log-only heuristic (user-agent + path + status).
**The classification works by exclusion**: each rule can recognise a kind of
automation, and what no rule recognises falls into the residual class. Nothing
here identifies a person, and no field claims to.

unattributed
: no rule could attribute this request to automation. **This is an upper bound on
  real people, not a count of them.** Anything a person did is in here - and so
  is any automation that declared nothing in its user-agent and behaved like a
  browser. It is the closest thing to an audience figure the data supports, and
  it must be reported as a ceiling: "at most N", never "N people".

no_agent
: the request sent **no user-agent at all**. Counted separately because an absent
  user-agent is a fact worth reporting rather than a residual - and because a
  browser always sends one, so these are not people. On one measured site this
  was 4,227 requests in a day, previously all counted as human.

ai
: an AI assistant or model fetcher (GPTBot, ClaudeBot, PerplexityBot, ...).
  Track this to show how much AI-assistant interest the site draws.

bot
: search crawlers and generic automation (Googlebot, curl, monitors).

noise
: vulnerability scanners and probes (`/wp-login.php`, `/.env`, `*.php` on a
  Markdown site), and socket/live-reload endpoints this engine never serves.
  Background abuse, not audience - usually report it only if it spikes.

scanner
: a visitor promoted to this class by its **behaviour** over a whole day - a
  sweep of many distinct missing paths - rather than by what it called itself.
  Often the largest class on a public site.

When the operator asks about "traffic" or "visitors", they mean the
**unattributed** class. Give them that number with its ceiling stated. Call out
the AI share separately when it is interesting.

### If you identify as an agent, say so

Send a user-agent containing `lazysite-agent/<partner-id>` (or `lzs-fetch`) when
you fetch pages from a site you are working on. Your requests are then recorded
as agent traffic and stay out of the visitor counts, where a sysop can still see
what your tooling did. An agent that does not declare itself lands in
`unattributed` and inflates the one figure the operator reads as their audience.

## Trails: the order people went in

The aggregates answer *how many* took each step. They cannot answer *in what
order* one visit went, because a transition count of 100 on an edge is not a
hundred stored journeys. `trails=YYYY-MM-DD` returns the recorded visits for
that day instead:

```
visits           how many visits the day HOLDS
returned         how many this reply contains
truncated        true when returned < visits - the reply is capped at 200
trails[]         one entry per visit
  entry          first page of the visit
  exit           last page
  depth          DISTINCT pages, so a reload is not another page
  steps[]        the ordered sequence, repeats included
    p            the path
    c            the visitor class AS IT WAS at the time
    gap          seconds until the next step; ABSENT on the last step
```

Two things to keep straight when you use it:

- **Trails expire and the rollups do not.** Default retention is 30 days. Call
  `index` and read `trail_days` to see which days actually have them - do not
  guess a date. A day with none says so, and says whether it was never recorded
  or has expired.
- **`truncated` means you are looking at part of a day.** Say so if you report
  from it; do not describe a capped sample as the day's behaviour.

Trails are the most person-adjacent data here. They are pseudonymous and
capped, they are still a single visitor's path, and the rules under "What you
must NOT claim" apply to them with more force rather than less.

## What you can report on

- Trend over the window: is `unattributed` traffic rising or falling? Quantify it
  from `by_day` - and check `counting_basis_in_window` first, because a basis
  change inside the window produces a step that is not a trend.
- Top and rising/falling content: which pages draw people; which grew or dropped
  versus earlier in the window.
- Referrer mix: how much is direct vs internal vs which external sources, and
  which external site sends the most.
- AI-assistant interest: the `ai` share and its trend - useful as AI search grows.
- Health: 404 spikes (broken links, missing pages), unusual status patterns.
- Anomalies: day-to-day spikes or drops worth a closer look.
- Journeys, from `trails`: the common entry points, where visits end, how deep
  people go, and which sequences recur - the questions the aggregates cannot
  answer.

## What you must NOT claim

- Not authenticated identity. These are heuristics over log lines, not logged-in
  sessions - say "approximately" and never name or profile an individual.
- No conversions, scroll depth, or anything needing JavaScript or cookies -
  lazysite uses none for analytics.
- Not time-on-page. A trail's `gap` is the interval between two requests, which
  is a *lower bound* on the dwell for the page being left and nothing more: it
  cannot see a page read in a background tab, and there is no gap at all for the
  exit page, which is where a visit usually ends. Report it as "at least N
  seconds before moving on", never as how long somebody spent reading.
- No PII. You do not have IPs or personal data, by design; do not infer them.

## Style

Lead with the answer to what the operator asked, backed by the specific numbers.
Prefer a short narrative plus the few figures that matter over dumping the whole
JSON. Flag a caveat when a number is approximate or the window is short.
