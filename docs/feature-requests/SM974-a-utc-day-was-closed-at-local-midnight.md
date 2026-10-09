---
id: SM974
title: "SM974: A UTC day was closed at local midnight"
subtitle: "The stats plugin judged today and closed days on the local calendar while every day bucket was a UTC day, so east of UTC a day's last hours never reached its durable file."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-09
raised-by: the developer agent, Q14g - three stats tests failed on main between local midnight and 01:00 BST (found by the SM944 S20 agent)
area: correctness
status-note: "SHIPPED (PENDING) n305: every stats day is a UTC day - _day_str uses gmtime, the server-log parser reads a stamp's offset and keys by the UTC day of the instant, the form handler records an outcome under the UTC day. Fourteen stats tests fixed to the same calendar; t/unit/plugins/48 pins all three product changes."
---

# What was wrong

Q14g was reported as three flaky tests: t/unit/plugins/06, 09 and 31 failed
between local midnight and 01:00 BST and passed at 01:03. The tests were wrong,
and so was the product.

The first-party pipeline is UTC throughout. The processor files a line under
`access-YYYYMMDD.jsonl` by `gmtime`, salts the visitor key with the same UTC
day, and the stats ingester buckets each line by `gmtime( t )`.

`plugins/stats.pl` then judged the calendar with `localtime`. `_day_str` gave
"today" to `_persist_durable`, which treats a day before today as closed,
writes it once more and marks it final (SM343). It also gave the window's
start and end, the retention cut-offs and the trail expiry.

East of UTC, local midnight comes before UTC midnight. From local midnight
until UTC midnight, the UTC day still being filled was judged closed, written,
and marked final. Every view after that point stayed in the bucket and never
reached the day file. Under BST that is the last hour of every UTC day; under
UTC+14 it is the last fourteen hours. This is SM343's frozen day, brought back
by a time zone.

Two other writers used a different calendar:

- **The server-log parser** read a stamp's wall-clock digits as local time
  and dropped the offset. Its day was the log's local date, and a log written
  in a different zone from the host gave every view the wrong instant.
- **The form handler** recorded an outcome under the local date, so a form
  outcome near midnight landed in a different day bucket from the page views
  around it.

West of UTC the split was harmless to the data: a closed UTC day was rewritten
on every call until local midnight.

# The fix

One calendar for the whole store, the one its default source already uses:

- `_day_str` is `gmtime`. Today, closed, the window, retention and the trail
  expiry are all UTC days.
- `_parse_line` reads the stamp's offset (`Time::Local::timegm` minus the
  offset) and keys the view by the UTC day of that instant. A stamp with no
  offset is read as local time, as before.
- `_record_form_event` names the file and the record by the UTC day.

**Behaviour change for server-log sites on a host not set to UTC:** their
days were the log's local dates and are now UTC days. Days already in the
store keep their old buckets; new views are bucketed by UTC day from the
first export after the upgrade, so the day of the upgrade can be split
across two buckets. First-party sites, the default, are unchanged except
that their last hours east of UTC now reach the file.

# The tests

Fourteen stats tests had the same split. Each one stamped `localtime` labelled
`+0000`, named a day by the local date, or placed events "an hour ago" and
read "today":

- **01, 02, 05, 07, 25, 29**: stamps are now `gmtime` with `+0000`, and the
  day read is the UTC day of the same instant.
- **06, 47**: events were an hour back and the rollup read was today's. The
  events are now at 01:00 UTC yesterday, so the fixture sits inside one UTC
  day at any hour.
- **09, 10**: `time() - 86400` and 01:00 local are now 01:00 UTC yesterday.
  The event "a minute ago" is read on its own UTC day.
- **30**: local noon yesterday (wrong more than twelve hours from UTC) is now
  noon UTC.
- **31, 08, 46**: file names and days use `gmtime`.

t/unit/plugins/19 (SM600) already used UTC days, and failed on main under
America/Los_Angeles because the product did not. It passes now with no change.

# Evidence

A fake clock stands in for faketime, which is not installed: `tmp/q14g-clock/
Q14gClock.pm` overrides `time`, `localtime` and `gmtime`. Loaded through
PERL5OPT, it gives every perl process in a test the same skewed clock.

- **Reproduction**: `Q14G_AT=2026-10-08T23:30:00Z TZ=Europe/London` (00:30
  BST) fails 06, 09 and 31 on main, as reported; `2026-10-09T00:03:00Z` passes.
- **Product probe** (`tmp/q14g-probe-east.pl`): two first-party views at 23:05Z
  and 23:45Z, exported at 00:10, 00:50 and 01:30 BST. On main the day file says
  1; with TZ=UTC it says 2. After the fix it says 2 under Europe/London,
  Pacific/Kiritimati and America/Los_Angeles.
- **Matrix** (`tmp/q14g-matrix.pl`, 13 scenarios: four real-clock zones and
  nine fake-clock instants including 00:30 and 00:59 BST, 23:59:50 UTC, both
  sides of Kiritimati's midnight, Los Angeles evening and the end of a month):
  on main 7 test files fail across 11 of the 13 scenarios; after the fix all pass in
  all 13.
- **t/unit/plugins/48** uses a POSIX zone 23:59 east of UTC, so the local date
  is a day ahead for all but one minute of every UTC day and the suite needs no
  fake clock. Run against main's code, all three of its subtests fail.

# Related

- [[SM343]] - a closed day written once more after it closes; this is the same
  freeze, triggered by the zone instead of by a reader.
- [[SM600]] - test 19 already read the records' UTC day.
- [[SM216]] - the form-event log.
