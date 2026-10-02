---
id: SM935
title: "SM935: the form rate limit buckets on a calendar hour, so a burst can double at the boundary"
subtitle: "The limiter keys on `\"$ip:$hour\"` where `$hour = int(time/3600)`. Five submissions at 10:59:59 and five more at 11:00:00 is ten in one second, every one within the shipped limit of five an hour. The window is not rolling, and the boundary is free."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-02
raised-by: measured here while answering a sites-agent report about a scanner that sent five submissions in two seconds
area: forms
status-note: "SHIPPED (PENDING) as a ROLLING hour rather than the boundary being documented as deliberate: a limit of five that permits ten is not the limit the operator set. The stored value is the submission TIMES, the window is the hour before now, and the row is bounded at the limit because a decision only needs to know whether that many fall inside it. The key is the address ALONE, which also removes an ambiguity the old scheme carried - "$ip:$hour" appended a colon-separated number to an IPv6 address that already contains colons, and the purge had to parse it back out. COUNTERS START FROM ZERO ON UPGRADE and that is asserted: an old row holds a bare count, which is not a timestamp inside the window, so the first purge clears it - the safe direction. SABOTAGE-VERIFIED: with the calendar-hour bucket put back, the boundary subtest, the rolling-window subtest and the legacy-purge subtest all fail. ORIGINAL REPORT: NOT YET RULED. Measured in `plugins/form-handler.pl`: `check_rate_limit` defaults to 5, refuses when `$count >= $limit`, and keys the DB_File counter on `\"$ip:$hour\"` with `$hour = int( time() / 3600 )` - a FIXED CALENDAR HOUR, not a rolling window. The report that prompted this reasoned that the per-token timing floor was the wrong control for a burst and was right; it also supposed the five submissions had bypassed something, and they had not - five is exactly the shipped limit, so all five were permitted. THE SHARPER FINDING IS THE BOUNDARY, and it is mine rather than the report's: a caller gets a fresh allowance the moment the clock crosses the hour, so twice the limit can land in adjacent seconds. WHAT NEEDS DECIDING is whether that matters enough to change: a rolling window costs a stored timestamp list per address rather than a counter, and the existing shape is cheap and legible. The alternative is to say the boundary is deliberate and write it down, which is an honest answer for a control whose job is to blunt volume rather than to be exact."
---

# Measured

`plugins/form-handler.pl`, `check_rate_limit`:

    $limit = defined $limit ? $limit : 5;      # the shipped default
    return if $limit <= 0;                      # 0 or `off` = no limit
    my $hour  = int( time() / 3600 );
    my $key   = "$ip:$hour";
    my $count = $db{$key} || 0;
    if ( $count >= $limit ) { ... reject( 'Rate limit exceeded', 'rate' ) }

So the counter is per address **per calendar hour**, in a DB_File keyed on that pair.

**Grade: read from the limiter (A). Not exercised against a live site** - the
arithmetic is the finding and it does not need a site to confirm.

# The consequence

| Time | Submissions | Allowed? |
| --- | --- | --- |
| 10:59:59 | 5 | yes - the 10:00 bucket is fresh |
| 11:00:00 | 5 | yes - the 11:00 bucket is a different key |

Ten submissions in one second, within the rules. A caller that waits for the top of
the hour gets double the allowance; one that does not care will find the boundary by
accident sooner or later.

# What this is and is not

**It is not the reason a scanner got five submissions through.** Five is the limit;
nothing was bypassed. The reporter's own conclusion about the other control was
correct: the three-second floor measures the interval since a token was issued, and
fetching a fresh token per submission costs nothing, so it is not a rate control at
all.

**It is a bound that is loose at one point by a factor of two**, in a control whose
purpose is to blunt volume. Whether that is worth a rolling window is the decision.

# The two answers

| Option | Cost |
| --- | --- |
| A rolling window - keep N timestamps per address, refuse when N fall inside 3600 seconds | A list rather than a counter, and a prune. Exact, and the boundary disappears |
| Keep the bucket and **say so** - document that the allowance resets on the hour | Free, honest, and leaves the factor of two in place for anybody who reads the docs |

Either settles it. What should not stand is a limit whose edge behaviour is neither
chosen nor written down.

# Related

[[SM934]] (the other half of what that scanner exposed), [[SM930]] (a heuristic from
the same area), [[SM401]] (the per-form `rate_limit` key),
[[feedback_a_boolean_has_four_states]].
