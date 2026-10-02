---
id: SM942
title: "SM942: feed.rss and feed.atom list their items in path order, not newest first"
subtitle: "59 pages, correct pubDate on every one, and the items in filename order - so an aggregator taking the first 10 entries gets ten articles chosen by path. The reporter's proposed fix is to sort in the two registry templates, and that fix would reach no existing site: the templates install under bucket `seed`, which is the exact trap the engine's own `_feed_dates` comment was written about, on this very feature."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-02
raised-by: the sites agent (xisl.com), measured on a live feed after regenerating the registries
area: renderer
status-note: "CANDIDATE, and REPRODUCED HERE by reading the shipped template: `starter/lazysite/templates/registries/feed.rss.tt` has a bare `FOREACH page IN pages` with no sort. Grade A stands. TWO CORRECTIONS TO THE REPORT, both about where and how: (1) THE FIX CANNOT GO IN THE TEMPLATE. Registry templates install under bucket `seed`, so an upgrade never replaces them - a site installed a year ago keeps the template it was given, and fixing starter/ would fix new sites while leaving every feed that HAS a subscriber wrong. The engine already learnt this on this same feature: `_feed_dates` is applied in lazysite-processor.pl for exactly that reason and says so in a comment. (2) SORTING ON `page.date` WOULD ORDER BY DAY NAME. By the time the template sees it, `date` is already the RFC 822 string ('Fri, 02 Oct 2026'); the sort has to use the raw ISO value, which the engine keeps as `date_raw`. The item cap the report raises at the end is a decision, not a defect, and is not bundled in."
---

# Measured

xisl.com registered 59 pages into the feeds - a release-notes page dated 2026-10-02
and 58 knowledge-base articles dated across 2026. Both feeds carry all 59 items with
correct `pubDate` / `updated` values, in **path order**:

    Release notes                         Fri, 02 Oct 2026
    Backing Up and Restoring ...          Wed, 24 Jun 2026
    Build Blends - What They Change ...   Mon, 09 Feb 2026
    Checking Xi-Batch File and ...        Tue, 06 Jan 2026
    Choosing a Distribution Format ...    Tue, 17 Feb 2026

Atom the same: `updated` in document order is 2026-10-02, 2026-06-24, 2026-02-09,
2026-01-06, 2026-02-17, 2026-05-18 - neither descending nor ascending.

**Confirmed against this tree.** `starter/lazysite/templates/registries/feed.rss.tt`
loops `[% FOREACH page IN pages %]` with no sort, and nothing orders `@registered`
before the template sees it.

# Why it is worth fixing rather than documenting

The RSS specification does not require an order, which is presumably why nothing
caught it. The universal convention is newest first and every reader's UI assumes it:

- an aggregator taking the first N entries of a large feed gets an arbitrary slice -
  with 59 items, "the latest 10" is ten articles chosen by filename;
- a human opening the feed URL sees the oldest article in second position;
- anything polling for "new since last time" from the top rather than by guid reads
  the wrong end.

# The fix, and the two traps in the obvious version

## It goes in the engine, not the template

The reporter proposes sorting "in the two feed registry templates". That would fix new
sites and leave existing ones broken, and the engine has already been through this on
this exact feature. `lazysite-processor.pl`, in the `_feed_dates` block:

> DONE HERE RATHER THAN IN THE TEMPLATE, and that is the whole reach of the fix: the
> registry templates install under bucket `seed`, so an upgrade never replaces them. A
> site installed a year ago keeps the template it was given. Fixing `starter/` alone
> would fix new sites and leave every feed that has a subscriber wrong.

So the sort belongs where `@registered` is built for `feed.rss` / `feed.atom`, beside
the date formatting that is already there for the same reason.

## Sorting on what the template sees would order by day name

In that same block the formatted value REPLACES `date`: by the time a template sees
it, `page.date` is `Fri, 02 Oct 2026`. A sort on that string orders by weekday name,
then day-of-month - which is wrong in a way that still looks sorted, and would be
worse than the present fault because it would look deliberate.

The block keeps the original as `date_raw`, so the sort has an ISO value to use. The
sort must therefore happen on the raw date - either before formatting, or on
`date_raw` after it.

# Rows

| Ref | The work | Cx | Needs |
| --- | --- | --- | --- |
| FO1 | Sort the feed page list newest-first in the engine, on the raw ISO date, before the template is processed. `sitemap.xml` and `llms.txt` are untouched - path order is right for both, and only the feeds carry a time axis | S | nothing |
| FO2 | A test that asserts the emitted order, not the sort call: generate a feed from pages whose path order and date order DISAGREE, and assert the dates come out descending. A fixture whose filenames happen to be in date order would pass without the fix | S | FO1 |
| FO3 | **An item cap, and `lastBuildDate`.** The reporter raises it and rates it correctly: "Not a defect, but the same template and the same sort." 59 items is already large for a first fetch and a site with a few hundred dated pages emits all of them on every poll. The usual shape is the most recent 20-50 | S | **a ruling** - a cap changes what subscribers can reach, which is a product decision rather than a bug fix |

# Not a defect, recorded so the next reader does not chase it

The reporter checked and says so: `_feed_dates` is working as documented - every page
carried an ISO `date:` and each came through as the right RFC 822 / RFC 3339 value.
The ordering is the only fault, and it is upstream of the date handling rather than
in it.

# Related

[[SM915]] (one registry, one list), [[reference_lazysite_generated_docs]],
[[feedback_fixture_agrees_with_reader]] - FO2's trap is that shape: a fixture that
agrees with the code for the wrong reason.
