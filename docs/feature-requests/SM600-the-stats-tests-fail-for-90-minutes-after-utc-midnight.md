---
title: "SM600: five stats tests fail for the 90 minutes after UTC midnight, every day"
subtitle: "Each stamps its records at $now - 5400 and derives the day string from $now, so inside 90 minutes of UTC midnight the records land on one day and the assertion asks for the next."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-26 at 00:20 UTC, when the 0.10.34 post-cut gate failed on t/unit/plugins 14, 15, 16, 19 and 27 - AT THE EXACT COMMIT WHOSE RELEASE BUILD HAD PASSED AN HOUR EARLIER, at 23:18 UTC. Nothing in the tree changed between the two runs; the date did. THE MECHANISM: each fixture writes visit records stamped `$now - 5400` - 90 minutes back, so the session is older than SESSION_GAP (30 minutes) and the export closes it into a trail - and then derives the day it asks for from `gmtime($now)`. Between 00:00 and 01:30 UTC those are DIFFERENT DAYS: the records are written under yesterday and the assertion asks for today, which has none. The failure says so exactly - 'No trails for 2026-08-26 - never recorded, or expired' - and the honest reading of that message is the first one, never recorded, under that date. AFFECTED: t/unit/plugins/14, 15, 16, 19, 27. Test 19 already derives one of its day strings from `gmtime($now - 5400)` and the rest from `$now`, so the file disagrees with itself and half of it is already right. A FIX THAT DOES NOT WORK, recorded so it is not tried twice: anchoring `$now` to noon of the current UTC day makes every derived stamp land inside one day, and breaks all five differently - noon today is up to twelve hours in the FUTURE, nothing is older than SESSION_GAP relative to the real clock, no session closes, and no trail is written at all. Measured: it turned 4 failing files into 5. THE FIX MUST KEEP THE RECORDS IN THE PAST AND INSIDE ONE UTC DAY - anchor to a fixed instant several hours back and derive both the stamps and the day string from that same instant, rather than from two instants 90 minutes apart. NOT A PRODUCT DEFECT: the engine buckets by the record's own timestamp, which is correct. This is the tests disagreeing with themselves about which instant they mean. NOT FIXED TONIGHT, deliberately - it blocks a release for 90 minutes a day and the release in hand can wait that long, whereas a hurried change to five time-dependent fixtures at 01:00 is how a permanent flake gets introduced to fix a daily one."
---

# The two instants

```perl
my $now   = time();
my @gm    = gmtime($now);                 # the day the test ASKS for
my $TODAY = sprintf '%04d-%02d-%02d', $gm[5] + 1900, $gm[4] + 1, $gm[3];
...
        $now - 5400 + ( $s * 10 ), $s, $v;   # the day the test WRITES
```

90 minutes apart. Inside 90 minutes of UTC midnight, on opposite sides of it.

# Why the same commit passed and then failed

| Time (UTC) | `gmtime($now)` | `gmtime($now-5400)` | Result |
|---|---|---|---|
| 23:18, 25 Aug | 25th | 25th | release build **passed** |
| 00:20, 26 Aug | **26th** | **25th** | post-cut gate **failed** |

# What it costs

A release cut in that window fails its gate for a reason that has nothing
to do with the release, and the evidence points at the stats plugin -
which is working correctly.
