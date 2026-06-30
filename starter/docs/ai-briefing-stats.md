---
title: AI briefing - visitor analytics
subtitle: Guide for AI assistants analysing a lazysite's visitor traffic for trend reporting.
register:
  - sitemap.xml
  - llms.txt
---

## Who this is for

This briefs an AI assistant that the operator has asked to analyse visitor
trends for this site. You get the data from the `analyse_visitors` tool (it needs
the `analytics` capability). The operator directs the analysis - this doc tells
you how to read the data and what you can honestly report.

## How to get the data

Call `analyse_visitors` with an optional `window` (days, 1-365, default 30). It
returns a sanitised JSON summary built from the web-server access log. You never
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
events           [ { t, class, path, status, visitor } ]   recent requests
events_capped    true if the event stream hit its size limit
```

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

## What you must NOT claim

- Not authenticated identity. These are heuristics over log lines, not logged-in
  sessions - say "approximately" and never name or profile an individual.
- No conversions, time-on-page, scroll depth, or anything needing JavaScript or
  cookies - lazysite uses none for analytics.
- No PII. You do not have IPs or personal data, by design; do not infer them.

## Style

Lead with the answer to what the operator asked, backed by the specific numbers.
Prefer a short narrative plus the few figures that matter over dumping the whole
JSON. Flag a caveat when a number is approximate or the window is short.
