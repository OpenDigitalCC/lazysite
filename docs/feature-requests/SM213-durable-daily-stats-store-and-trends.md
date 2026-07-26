---
title: "SM213 - durable per-day stats store + month-on-month trends (no cap, no operator knob)"
subtitle: "The visitor-stats cache keeps aggregates plus a 5000-event ring in one JSON blob; at real volume the ring covers about a week and an operator sees an events_capped flag that reads like data loss. Replace the single blob with a durable per-day rollup file the dashboard indicates from and an AI can read or download per day, add per-day filtering and month-on-month trends, and make the cap an invisible implementation detail - never an operator setting, because needing to set it presumes you are losing data."
brand: plain
status: candidate
status-note: "PROPOSED 2026-07-27, target 0.9.17 beta. Origin: an operator report that the stats event cap (5000) is hit, plus the lazysite.io site agent's analytics proposal (inbox archive 2026-07-27-goals-and-privacy-analytics-proposal.md). Scoped deliberately to the STORAGE + TRENDS + ACCESS foundation - a durable per-day rollup store, month-on-month trends, per-day filtering, AI-readable/downloadable day+month index files, dashboard kept as a lightweight indicator - and NOT a full analytics platform. The brief's richer items (goals, redirect: outbound goals, sessionised flow, access-log ingestion, passive-header device/language mix) are captured as phased follow-ups that build on this foundation, not bundled here. UPDATED 2026-07-27 with the site agent's validation follow-up (inbox archive 2026-07-27-analytics-validation-and-notes.md): confirmed in source that aggregates were never capped (only the events ring is), so SM213 adds two self-describing horizon fields (data_from + sample) to retire events_capped, and folds in the referrer-spoofing diagnosis (visitor-level scanner classing is the clean catch; a per-class referrer split would NOT help since referrer buckets are already human-only + SM192 spam-listed)."
---

# SM213 - durable per-day stats store + trends

## Why

Two things converged:

- An operator hit the stats event cap (`$EVENT_CAP = 5000` in `plugins/stats.pl`)
  more than once and read the `events_capped` flag as "we are losing data".
- The lazysite.io site agent, after a hand-run traffic analysis, filed a proposal
  (`inbox/archive/2026-07-27-goals-and-privacy-analytics-proposal.md`) whose Part 2 opens
  with exactly this: aggregate per day at ingest, retain small daily rollups
  long-term, and let the raw event ring stay capped - "long-run trending falls out,
  and granular data lives shorter, a privacy improvement not a trade-off".

The important clarification first: the aggregates are **not** truncated at 5000
today. The per-day buckets (`days`) in the cache accumulate every event and are
kept for 400 days; the 5000 cap only bounds the raw recent-event **sample**
(`events`). So trend, top-page and class data is already complete. But the design
has three real problems:

- It is not legible. One opaque `stats-export.json` blob holds aggregates and the
  event ring together; the only durable-looking artefact an operator or an AI can
  point at is the capped ring, and its `events_capped` flag reads as loss.
- The durable aggregates live in `cache/`, which is clearable - so the thing that
  should be the long-term record can be wiped as "cache".
- There is no per-day file to read or download, no month-on-month view, and the
  event ring - not the aggregates - is what an AI is handed to reason over, so at
  volume the AI only ever sees the last week.

The fix is not an operator setting for the cap. Needing to raise a cap presumes
you believe you are losing data; the product should simply not lose it, by
construction, with a sensible default nobody has to touch.

## Current behaviour (located)

`plugins/stats.pl`:

- `_export_ingest_*` parse new log lines since a byte offset into a single cache
  (`lazysite/cache/stats-export.json`): per-day aggregate buckets (`days`) plus a
  rolling `events` ring, `shift @events while @events > $EVENT_CAP` (5000).
- `_export_assemble` sums the day-buckets across the requested window into totals,
  by-day series, top pages, referrers, status codes, class shares; returns those
  plus the window-filtered slice of the (capped) ring and an `events_capped` flag.
  Day-buckets older than 400 days are dropped.
- The control API (`action_analyse_visitors`) and the MCP `analyse_visitors` tool
  run the plugin with `--export --window N` and return that JSON. Gated on
  `analytics`.

So: aggregates complete (in a clearable cache), event sample capped, no per-day
artefact, no monthly view.

## Design

### 1. A durable per-day rollup store (the source of truth)

Move the long-term aggregates OUT of the clearable cache into a durable stats data
directory, one small JSON file per day:

- `lazysite/stats/daily/YYYY-MM-DD.json` - that day's complete, sanitised
  aggregate: pageviews, unique visitors (within the salt period), traffic-class
  counts (human/ai/bot/noise/scanner), top pages, referrers (origin-only), status
  codes, and a top-404-paths table with a junk/plausible split. Aggregates only -
  never a per-visitor record - so a day file is safe to read, expose and download.
- Written incrementally: the byte-offset cache (kept in `cache/`, rebuildable)
  advances as today; the current day's file is rewritten each ingest, past days are
  immutable once the day closes. Small and bounded by the aggregate shape, not by
  traffic volume, so there is no cap on what a day retains and nothing to configure.
- `lazysite/stats/index.json` - the days index: which days exist, each with its
  headline counts, so a reader gets the available range and a coarse series in one
  small read.
- `lazysite/stats/monthly/YYYY-MM.json` (derived/rolled from the day files) - the
  months index for **month-on-month trends** without reading every day.

Retention is generous and time-based (the day files are tiny); it is a fixed
sensible default, not an operator knob. The raw per-event **ring** stays only as
the dashboard's short "recent activity" sample, with a fixed internal size that is
never surfaced as a limit.

### 1a. Self-describing horizons (retire `events_capped`)

The payload silently carries two different horizons - the aggregate buckets (up to
400 days, or the age of the install's stats) and the events sample (whatever the
ring currently spans) - and reading one as the other is exactly the trap the site
agent fell into (it mis-read a 17-day by-day series as cap truncation when it was
just the age of the install). Two small additive fields make the horizons explicit
so no consumer repeats it, and replace the misleading `events_capped` boolean:

- `data_from` - the first day a bucket exists for, so "the window I asked for" vs
  "how much data actually exists" is visible at a glance.
- `sample: { from, to, count }` - what the raw events ring actually covers, stated
  plainly, so the sample is never mistaken for the authoritative dataset.

### 2. Two views over one store

Human dashboard (manager Stats page) - an INDICATOR, not a platform
: Reads a compact rollup (recent days + the monthly series) and shows the headline:
  totals, the month-on-month trend, traffic-class shares, top pages, the 404
  junk/plausible split. Per-day filtering: pick a day (or range) and see that day's
  rollup. Deliberately a summary an operator glances at, not a full BI tool.

AI analysis + download - reads the index files directly
: `analyse_visitors` gains a day/range/month selector and can return a specific
  day's rollup, the days index, or the monthly series (additive, `schema_version`
  bump, existing consumers unchanged). The day and month JSON files are also
  directly readable and downloadable over the control surface (they are sanitised
  aggregates, the same safety class as today's export), so an AI can pull exactly
  the slice it needs - a day, a month, or the whole index - rather than being handed
  one capped event list. This is the "read different index files" the operator
  asked for.

### 3. Month-on-month trends + per-day filtering (operator asks)

- Month-on-month: the monthly rollups give per-month totals and deltas
  (pageviews, uniques, class mix, top pages, goals when present); the dashboard
  shows the trend and direction, the API/MCP returns the monthly series.
- Per-day: every report accepts a day (or day-range) filter and returns that day's
  rollup from its file, so "what happened on the 14th" is one lookup, not a
  re-scan.

### 4. Privacy stance, codified (from the brief, stated as commitment)

The store must hold this line, and it should be published as a product commitment
(a sentence on /features, a section in FEATURES.md, a paste-ready privacy paragraph
for operators), worded to the correct scope - **"lazysite installs no trackers"**,
not "this site has no trackers" (a site owner may add their own scripts; lazysite
cannot guarantee otherwise):

- No client-side trackers ever: no analytics JS, beacons, analytics cookies,
  fingerprinting, or third-party requests. Analytics are derived only from data the
  server already receives while serving pages.
- Aggregate early, discard detail: the durable day files hold aggregates, never
  per-visitor records. The raw ring is short-lived working memory.
- Visitor tokens cannot become long-term identifiers: salt them and rotate the salt
  on a fixed period (weekly). Returning-visitor metrics exist only within a salt
  period - the accepted cost.
- Forbidden by design: high-entropy client hints, ETag/cache-based visitor marking,
  cookie-based analytics IDs.

### 5. Classification trust (small, in scope - it governs what the store records)

From the field (lazysite.io): scanners wearing AI user-agents polluted the `ai`
class, and config-probe requests with browser UAs were counted `human`. In scope
for a store you can trust enough to publish:

- Classify the **visitor**, not the event: any probe-path hit marks that visitor
  token as `scanner` for the window.
- A distinct `scanner` class (probe-path patterns), split out of human/ai.

This also fixes referrer spoofing, validated in the field (odysseytimeship.com's
buckets recorded HN and Reddit referrals that those platforms have zero record of).
Note what does NOT help, to save the tempting wrong turn: referrer buckets are
*already* human-class-only at ingest (`stats.pl:784-800`) and `_ref_is_spam`
(SM192) already drops a known-spam host list - so a per-class referrer split changes
nothing, and real social hostnames (news.ycombinator.com, reddit.com, t.co) can
never go on a static spam list. The spoofers pass the human UA classifier and wear
real referrers. Visitor-level classing is the clean catch: the spoofing tokens are
typically the same ones probing `/env.json`-style paths moments apart, so marking
the visitor `scanner` removes their referrals from the human buckets as a side
effect. A cheap corroboration heuristic (a social referrer on a visitor whose only
request is one page and no assets is suspect) is a phased add-on, not needed for the
core fix.

Deferred (bigger, see roadmap): verifying self-declared crawlers against published
IP ranges / reverse DNS.

## What ships in 0.9.17 (this FR)

The foundation: the durable per-day + monthly store, retention, the index files,
per-day filtering, month-on-month trends, the dashboard reworked to indicate from
the rollups, the `analyse_visitors` day/range/month selector + downloadable index
files (additive, schema bump), the self-describing horizon fields (`data_from` +
`sample`, replacing `events_capped`), the 404 junk/plausible split, the
visitor-level `scanner` classification (which also removes spoofed referrals from
the human buckets), and the privacy commitment codified + published wording.

## Roadmap - phased follow-ups (captured from the brief, NOT bundled here)

These build ON this store; each is its own increment so 0.9.17 stays a storage +
trends release, not a platform build:

- **Goals** (brief Part 1): `goal.<name>: <path-glob>` in stats.conf, form-submission
  join (the truest conversions, already stored), a goals panel. A distinct feature
  family - likely its own FR (SM214).
- **`redirect:` front-matter** for logged 302 outbound-goal pages (`/go/<name>`),
  literal absolute URL only (no open redirect), skipped by registries/search. Also a
  standalone content primitive.
- **Server-side sessionisation** (30-min gap): entry/exit pages, top transitions,
  depth histogram computed at ingest into the day rollup - so flow analysis stops
  depending on the raw event list at all. Must be computed at ingest, NOT derived
  from the events ring, or flows silently inherit the sample horizon while the rest
  of the report does not.
- **Opt-in external-referrer path retention**: keep the path of an external
  referrer (query string always stripped; origin-only stays the default) so "which
  Reddit post sent this" is answerable for the referrals that are real. Per-site
  opt-in, default off.
- **Access-log ingestion**: optionally read the web server's combined access log so
  static-asset 200s (a strong browser-vs-bot tell) are visible; packaged installs own
  the vhost and could wire it by default. Same privacy posture, much richer data.
- **Crawler verification**: check self-declared search/AI crawlers against published
  IP ranges / reverse DNS before crediting the class.
- **Passive-header mixes** (brief Part 3): `Accept-Language` -> visitor-language mix
  (useful for multilingual decisions); default-on low-entropy client hints
  (`Sec-CH-UA*`) -> device/platform mix; returning-visitor share within the salt
  period. High-entropy hints stay forbidden; anything beyond default headers is a
  documented per-site opt-in, default off.

The honest limit, worth documenting so nobody reaches for a tracker to fill it:
time-on-page, scroll depth and rage-clicks cannot exist without client-side code,
and do not exist here.

## Tests

- Ingest writes a per-day file with complete aggregates; a second incremental ingest
  updates only the current day and advances the offset; past-day files are unchanged.
- No data loss with volume: ingest N > 5000 events across several days; every day's
  totals equal the input; nothing depends on the ring size.
- Per-day filter returns one day's rollup; a range sums the day files; the monthly
  rollup equals the sum of its days (month-on-month deltas correct).
- The days index and months index list the available range and headline counts.
- Day/month files are aggregates only - a test asserts no per-visitor field and no
  raw IP/UA leaks; salt rotation makes a visitor token from period A not equal the
  same address's token in period B.
- `scanner` classification: a probe-path hit reclasses that visitor's other events
  in the window; class shares shift accordingly.
- `analyse_visitors` schema is additive: existing fields unchanged, new selectors +
  `schema_version` bump; the control-API/MCP gate stays on `analytics`.

## Rollout

The durable store is rebuilt from the existing day-buckets/logs on first run after
upgrade (no manual migration); the old `stats-export.json` becomes the offset cache
only. Beta-channel first (0.9.17), the usual tag-on-main flow.

Related: `plugins/stats.pl`, `action_analyse_visitors` + the MCP `analyse_visitors`
tool, SM140 (first-party day-file ingestion), SM192 (referrer-spam drop), the 0.9.0
`analytics` capability, `docs/ai-briefing-stats`, and the site agent's proposal +
its validation follow-up in
`inbox/archive/2026-07-27-goals-and-privacy-analytics-proposal.md` and
`inbox/archive/2026-07-27-analytics-validation-and-notes.md`.
