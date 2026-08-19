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

## What the data means

The response has these fields:

```
window           { days, from, to }            the period covered
totals           { human_visits, unique_visitors, pageviews }
traffic_classes  { human|ai|bot|noise: { visits, share } }
by_day           [ { date, human, ai, bot, noise } ]   the trend, one row per day
top_pages        [ { key: "/path", count } ]   most-visited pages (people only)
referrers        { direct, internal, external: [ { key: host, count } ] }
status_codes     { "200": n, "404": n, ... }   people's responses
not_found        { plausible: [...], junk_count: n }   missing pages vs scanner noise
auth_refused     [ { key: "/path", count } ]   turned away, NOT missing
events           [ { t, class, path, status, visitor } ]   recent requests
events_capped    true if the event stream hit its size limit
```

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

Every request is classified by a log-only heuristic (user-agent + path + status):

human
: a real person's browser. This is the audience figure - use it for "visits".

ai
: an AI assistant or model fetcher (GPTBot, ClaudeBot, PerplexityBot, ...).
  Track this to show how much AI-assistant interest the site draws.

bot
: search crawlers and generic automation (Googlebot, curl, monitors).

noise
: vulnerability scanners and probes (`/wp-login.php`, `/.env`, `*.php` on a
  Markdown site). Background abuse, not audience - usually report it only if it
  spikes.

When the operator asks about "traffic" or "visitors", they almost always mean the
**human** class. Call out the AI share separately when it is interesting.

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

- Trend over the window: is human traffic rising or falling? Quantify it from
  `by_day`.
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
