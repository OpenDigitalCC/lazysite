---
id: SM941
title: "SM941: analyse_visitors reports two different human totals, and on another site more unique visitors than visits"
subtitle: "On xisl.com, `totals.human_visits` says 15,979 and `by_day[].human` sums to 18,849 - the same report, 2,870 apart, and the report's own notes field calls both complete. On opendigital.cc, 4,359 unique visitors across 4,241 visits, which a unique visitor cannot do. Nothing checks the arithmetic in this report, which is why three contradictions are visible in one call's output."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-02
raised-by: the sites agent (xisl.com, opendigital.cc), answering a site owner's question
area: analytics
status-note: "CANDIDATE, AND THE METHOD IS RULED (R4/R5, 2026-10-02): measure the gap before ruling AV2, and HOLD the invariant test H1 until AV2 is ruled so it lands green beside the fix rather than red or marked-red. The consequence is accepted explicitly - until then nothing checks this report's arithmetic. The measurement needs the live log this tree cannot read, so the engine gains the diagnostic and the sites agent is asked to run it. Grade A: measured on two live sites, reproduced across two window sizes, with the raw reports kept. NOT YET REPRODUCED HERE against a fixture - the numbers come from live first-party logs this tree cannot see, and the arithmetic contradictions are self-evident from the output rather than needing a repro. THREE FINDINGS, DELIBERATELY NOT MERGED: one is a hard contradiction (unique > visits), one is a split between two counters (two human totals), one is probably CORRECT behaviour that reads as broken (months not window-scoped). They are in one filing because they share a cause at the level that matters - nothing asserts that this report's numbers agree with each other - and the reporter says so: 'the arithmetic in this report is not being checked anywhere'. The report also names its own closing condition, which is a test rather than a fix: one call, three invariants."
---

# Rulings, 2026-10-02 (release manager)

**R4 - MEASURE THE GAP BEFORE RULING AV2.** The question put was which counter is the
human population. The answer is that the 2,870 is a *specific set of requests* and can
be characterised, so AV2 becomes a reading of data rather than a preference:

- the user agents in the gap set, by frequency;
- the paths behind the 8,023 404s - `/wp-admin`, `/.env` and friends would settle it
  in one glance;
- per-address request intervals, because a human and a scanner do not pace alike.

If the gap is scanner-shaped, the larger counter is absorbing bots and `totals` is the
one telling the truth. If it is not, the status codes describe a population the report
has never named. **Nothing is built on a guess, and that includes the test.**

**R5 - H1 IS HELD, DELIBERATELY.** The invariant test fails on commit because the
contradictions are live. It is not landing failing, and it is not landing marked as an
expected failure: it waits for AV2 and then arrives green beside the fix. The
consequence is accepted and recorded rather than discovered later - **until AV2 is
ruled, nothing checks this report's arithmetic**, which is the condition that let
three contradictions reach a site owner. It is a choice, not an oversight.

**What this engine can and cannot do about R4.** The gap lives in xisl.com's live
first-party log, which this tree cannot read. So the work splits: the engine gains a
diagnostic that characterises a window's gap set (H0, and it ships, so any site can be
asked the same question), and the RUN against a live site is the sites agent's. Asked
for through its inbox rather than assumed.

# What was measured

Two live sites, engine 0.14.4, analytics schema 2, classifier `built-in`, first-party
log. Raw reports kept at `lazysite-sites/xisl.com/tmp/stats-30.json`, `stats-90.json`
and `lazysite-sites/opendigital.cc/tmp/stats-30.json`.

## 1. Two human totals on one report, 2,870 apart

xisl.com, 30-day window:

| Field | Value |
| --- | --- |
| `totals.human_visits` | 15,979 |
| `totals.pageviews` | 15,979 |
| `months[].pageviews` summed | 15,979 |
| `by_day[].human` summed | **18,849** |
| `traffic_classes.human.visits` | **18,849** |
| `status_codes` summed | **18,849** |

The 90-day window gives 15,977 and 18,846 - **the same gap of 2,869**, so this is a
split between two counters rather than a window edge.

**The report's own `notes` field calls both complete:** "The aggregates
(totals/by_day/months/top_pages) are complete over data_from..window.to". Two of the
names in that list disagree about the one number a site owner asked for.

**Which is right decides what the site owner is told.** `status_codes` sums to the
LARGER figure. If 18,849 is the human population then 8,023 of 18,849 human
requests - **43%** - were 404s, which is not a plausible figure for people and
suggests the human class is absorbing scanner traffic the classifier missed. If
15,979 is the human population, then the status codes belong to a population the
report never names. Either reading leaves the owner unable to say what their human
traffic is, and 43%-of-humans-hit-404 is the kind of number that starts an
investigation into the wrong thing.

Related, and probably the same root: **`totals.human_visits` and `totals.pageviews`
are identical on every site the reporter checked.** Two fields, one number - so
either one is redundant or one is filled from the wrong counter.

## 2. More unique visitors than visits

opendigital.cc, 30-day window:

    "totals": { "human_visits": 4241, "pageviews": 4241, "unique_visitors": 4359 }

4,359 unique visitors across 4,241 visits. A unique visitor cannot visit fewer than
once, so this is a hard contradiction rather than a rounding question.

**And it is independent of finding 1.** On this site the three human totals all agree
at 4,241 - `by_day`, `traffic_classes` and `status_codes` included. Whatever splits
them on xisl.com does not split them here. Two sites, two different faults, which is
the reporter's argument for one filing: nothing is checking either.

## 3. `months` is not scoped to the window, and nothing says so

opendigital.cc, 30-day window: `months` sums to 11,159 against a window total of
4,241. On xisl.com's 90-day window they agree exactly, because the data happens to
start inside it.

**This is probably correct behaviour** - whole calendar months against an N-day
window - and it is recorded as a presentation defect rather than an arithmetic one.
The two sit in the same JSON with no field saying their scopes differ, and the first
reading of "months sums to 2.6x the total" is that something is broken. A
`window_scoped: false` on the block, or month rows clipped to the window, settles it.

# What would close this

The reporter names it, and it is a test rather than a fix:

> A single test that pulls one report and asserts the obvious invariants: the human
> totals in `totals`, `by_day` and `traffic_classes` agree; `unique_visitors <=
> human_visits`; `status_codes` sums to a population the report names.

**All three failures are visible from one call's output with no fixture**, which is
the argument for the test: it means nothing is checking the arithmetic today. The
test comes first, because until the invariants are written down "which counter is
right" is a question with no referee.

# Ordering, and what must be decided rather than coded

| Ref | The work | Needs |
| --- | --- | --- |
| AV1 | The invariant test: one report, three assertions. It will fail on commit - that is its purpose | nothing |
| AV2 | Which counter is the human population, and what `status_codes` counts. **This is a decision about what the product MEANS by a human visit**, and the 43%-404 figure is the evidence that the two counters are classifying differently | a ruling |
| AV3 | `unique_visitors <= human_visits`, once AV2 says which `human_visits` is | AV2 |
| AV4 | `totals.human_visits` and `totals.pageviews` are the same number on every site checked: retire one, or fill it from the counter its name claims | AV2 |
| AV5 | `months`: a `window_scoped` field, or clip the rows. Presentation, not arithmetic | nothing |

# Related

[[SM579]] (the visitor outcome), [[reference_lazysite_stats_gotchas]],
[[feedback_buckets_must_sum_and_population_drawn_apart]] - which is this filing's
whole shape: buckets that do not sum, and two populations drawn apart without being
named.
