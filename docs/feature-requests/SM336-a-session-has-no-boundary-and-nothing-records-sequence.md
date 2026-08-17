---
title: "SM336 - a session has no boundary, and nothing records sequence"
subtitle: "Every durable field is a marginal count. Nothing pairs one with another and nothing records order, so the question a site owner asks first - how do people move through my site, and where do they give up - is answerable only from a rolling 5,000-event sample, and never for any period already past."
brand: plain
status: partial
status-note: "PARTIAL, 2026-08-17: the prerequisite and items 1-5 shipped; 6 and 7 did not. A session is bounded by thirty minutes of inactivity OR a day change - the day boundary matters independently, because a session straddling midnight would fold its exit page into the wrong day and the durable store is per-day. Sessions close on SILENCE as well as on a following event, so the last visit of a day records its exit rather than waiting for that visitor to come back. Everything stored is an aggregate: a counter on an edge, a bucket in a histogram, never anybody's path. Item 6 (device class) needs the user-agent threaded through both ingesters, which the batch record does not carry; item 7 (internal search terms) carries the only real privacy risk here and needs its own operator toggle and frequency floor, so it wants deciding rather than assuming."
---

# The position

Everything durable is a **marginal count** - top pages, top referrers, class
shares, status codes, 404s. Nothing pairs one dimension with another, and
nothing records order.

Sequence exists today only in the rolling 5,000-event buffer, which is
explicitly a sample rather than the dataset. It is the one place where the
visitor token, the path and the timestamp live together, and it is overwritten
continuously.

So the trail question is answerable for the last few days, by accident of the
buffer's size, and for no period already past.

# The prerequisite, and why it comes first

**Nothing here can be computed correctly until a session has a boundary.**

Visitor tokens are day-scoped, not session-scoped. The brief found one token
showing `/login` followed by `/contact` **47,458 seconds apart** - thirteen
hours. Treated as one visit that is a two-page journey; it is two visits on the
same network a day apart.

A thirty-minute inactivity boundary is the conventional rule and is sufficient.
It costs one timestamp comparison per event at rollup. Without it every depth,
trail and dwell figure is wrong in the same direction: too deep, too long, too
connected.

This is not hypothetical. The brief's own headline figure moved from 41% to 5%
when a session was given a boundary and [[SM329]] stopped an image counting as
a page - the same data, two corrections, and the honest number is an eighth of
the flattering one.

# What to record, in the brief's priority order

```datatable
columns: # | What | Why it is worth the row
widths: 1.2cm | 5cm | X
bold: 2
tone: medium
---
1 | Path-pair transitions | The trail question answered as an aggregate. A hundred visitors going `/ -> /products -> /contact` is one counter of 100 per edge, not a hundred stored journeys - a flow diagram with nobody's path retained
2 | Entry, exit and depth | Exit page is the most actionable field a content owner can have: it names where the argument fails. A depth histogram turns "60% bounced" into which page they bounced off
3 | Referrer paired with landing page | The difference between "we get traffic from X" and "traffic from X arrives on the wrong page"
4 | The referring page for each 404 | Internal referrers only. A broken internal link is a one-edit fix, and today the owner is told the destination and not the source
5 | Dwell buckets per page | From timestamps that already exist. The last page of a session has no successor and therefore no dwell, which is correct and should be stated rather than guessed
6 | Device class | Three counters from the user-agent. Answers "does mobile matter to me", which decides a great deal of design work
7 | Internal search terms | The visitor saying in their own words what they could not find - and the only real privacy risk here
---
```

All are computed at rollup from data already passing through the reader. The
visitor token is used within the day and discarded exactly as it is now.

# The constraints that do not move

**Nothing client-side.** No script, no beacon, no cookie, no third party. "No
trackers" is codified in `FEATURES.md` and is a selling point in the market this
product sells into. Scroll depth, mouse tracking and view-time-by-viewport all
require it and stay unbuilt.

**No cross-day identity by default.** Returning-visitor counts need a token that
survives the day. That is a different privacy posture from the current one and
belongs in a deliberate, documented, operator-set choice rather than arriving
with a point release.

**Search terms are the exception that needs its own handle.** People type
surprising things into search boxes. Top-N only, never a log, with a minimum
frequency threshold so a one-off is never stored, and the one item on the list
an operator can turn off independently of the rest.

# Why the aggregates being good is the problem

The durable store is well built and the fields in it are correct. That is
precisely why this went unnoticed: there is no gap in what it records, only in
what it can express. A marginal count cannot be joined to another marginal count
after the fact, so no amount of later analysis recovers the pairing. The data
has to be recorded paired or it is not recoverable.

`data_from` on the instrument is **2026-07-14**. The fortnight before it is
gone, and the brief's closing line is the argument: the analysis can be
rewritten next year, and those fourteen days cannot.

# Reassessed 2026-08-17, after the durable store was repaired

This was filed against a store that could not have carried it. [[SM343]] meant a
closed day was frozen at the last call made during it, [[SM341]] meant a payload
could not say when it was made, and [[SM339]] meant nothing could repair what
was already written. Building session metrics on that would have produced
figures whose completeness depended on when somebody last looked at the
statistics.

All three are fixed, so the foundation is now sound and the filing's own
priority order stands unchanged.

**The prerequisite is still the prerequisite.** Nothing here can be computed
correctly until a session has a boundary, and the thirty-minute inactivity rule
is one timestamp comparison per event at rollup.

**What it costs, stated honestly.** Items 1 to 5 all need per-session state held
across a day's events, which the current tally does not keep - it aggregates as
it reads. That is the same structural question [[SM335]] raises from the other
end, and the two should be answered together: a reader that buffers a window can
compute sessions, trails and depth; a reader that streams cannot.

So this is not seven independent additions. It is one change to how a day is
read, after which the seven are mostly counting.

# What shipped, 2026-08-17

The prerequisite and items 1 to 5. Each day rollup now carries a `journeys`
block beside the marginal counts:

```datatable
columns: Field | What it answers
widths: 4.4cm | X
bold: 1
tone: medium
---
`transitions` | the trail question, as one counter per edge
`entry` / `exit` | where visits start, and where they stop
`depth` | 1 / 2 / 3 / 4-6 / 7+ - what turns "60% bounced" into which page they bounced off
`dwell` | under_10s / 10_30s / 30_120s / over_120s
`landing` | referrer host paired with the page it arrived on
`not_found_from` | a missing path paired with the INTERNAL page that linked to it
`sessions` | how many visits the day held
---
```

## The decisions inside it

**A day change ends a session, as well as a gap.** Not in the original brief and
it matters: a visit straddling midnight would fold its exit page into the wrong
day, and the durable store is per-day.

**Sessions close on SILENCE, not only on a following event.** Otherwise a
session's exit is recorded when that visitor comes *back*, so the last visit of
every day would be missing from `exit` and `depth` for ever - the most
actionable field silently excluding the most recent traffic. The sweep therefore
runs even on an ingest with nothing new, which is precisely the run that should
notice a visit has finished.

**Only human page views open a session.** A scanner has no journey worth
modelling, and an asset is not a step in one - not an entry page, not an exit
page, not a transition. That makes [[SM332]] and [[SM329]] prerequisites rather
than adjacent work: modelled against pre-SM332 data the most travelled journey
on the instrument was a WordPress sweep.

**The last page of a session has no dwell**, and that is stated rather than
guessed. Three pages produce two dwells.

## What the brief's own example turned out to be

The field case was `/login` followed by `/contact`, thirteen hours apart. Used
literally as a fixture it produces ONE session, correctly: `/login` is a system
path the engine already excludes from page counting, so it is not a step in a
journey either.

Worth recording. That specific pair would not have been modelled as a two-page
journey even without a boundary, because half of it was never a page. The defect
it illustrates is real and general; the example understated how much of the
engine already agreed.

# What did NOT ship, and why

Device class (item 6)
: three counters from the user-agent, and the batch record does not carry one -
  `classify()` consumes the UA and the record keeps only its verdict. Threading
  it through both ingesters is small, and it puts a new field in the cache, so
  it belongs with a decision about what else that field might be used for.

Internal search terms (item 7)
: the highest-signal field on the list and the only real privacy risk. People
  type surprising things into search boxes. It needs top-N only, never a log, a
  minimum frequency floor so a one-off is never stored, and its own operator
  toggle independent of the rest - which is three decisions, not an
  implementation.

# Verification

- A visitor's events are grouped into sessions by a thirty-minute inactivity
  boundary, and a thirteen-hour gap produces two sessions rather than one
  two-page journey.
- Depth, trail and dwell figures are computed per session, not per token.
- A day's rollup carries top-N transitions, entry pages, exit pages and a depth
  histogram, and none of them retains an individual's path.
- Nothing added requires a script, a cookie, a beacon or a third party.
- Internal search terms are top-N with a frequency floor, and can be turned off
  without turning off the rest.

# Related

[[SM329]] (an image is not a page - a prerequisite for every figure here, since
an image is not an entry page, an exit page or a step in a trail), [[SM332]]
(classification quality, and the sweep that would otherwise have been the top
journey on the site), [[SM213]] (the durable store and the event ring this
builds on), and
`inbox/archive/2026-08-16-visitor-stats-what-must-be-recorded-now.md`.
