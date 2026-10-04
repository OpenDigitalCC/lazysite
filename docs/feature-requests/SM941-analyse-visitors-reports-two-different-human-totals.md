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
status-note: "CANDIDATE, MEASURED IN FULL, AND AV2 IS ANSWERED - R4 is discharged and the diagnostic it scheduled (H0) is WITHDRAWN rather than built, because the split was in the source all along: cls{human} counts every human request and hits excludes successful asset fetches, so the gap is exactly asset_hits, which no projection of the report publishes. Four defects are now established from source plus one day of live user-agent data: (1) that asset split; (2) human_visits counts 404s as visits - 8,023 of 15,979, so real page views are 7,956; (3) unique_visitors sums ips (ALL classes) while the manager page deliberately sums cls_ips{human} and its comment says why; (4) classify() ends `return 'human'` and never consults the _is_browser it computed, so 4,227 requests with NO user-agent are counted as human - and 43% of the sampled human class is empty-UA or self-identifying automation, including our own lzs-fetch. RULED R8-R12: `human` BECOMES `unattributed` and the report explains the group as an upper bound. The first draft of this filing PARKED the rename on a false claim - that it would break every reader, dashboard and layout - which was an assertion, not a measurement: it is 8 usages in ONE file, none in lib/, tools/, templates or the front end. Retracted in the body rather than quietly corrected. Also a positive browser test plus a no_agent class, self-declaration tokens rather than a vendor list, and /websocket counted outside. CARRIES A MANDATORY CONSEQUENCE: counts DROP, so this is counting basis 4 and schema_version 3, or it recreates the exact unanswerable question SM338 exists to prevent. Grade A: measured on two live sites, reproduced across two window sizes, with the raw reports kept. NOT YET REPRODUCED HERE against a fixture - the numbers come from live first-party logs this tree cannot see, and the arithmetic contradictions are self-evident from the output rather than needing a repro. THREE FINDINGS, DELIBERATELY NOT MERGED: one is a hard contradiction (unique > visits), one is a split between two counters (two human totals), one is probably CORRECT behaviour that reads as broken (months not window-scoped). They are in one filing because they share a cause at the level that matters - nothing asserts that this report's numbers agree with each other - and the reporter says so: 'the arithmetic in this report is not being checked anywhere'. The report also names its own closing condition, which is a test rather than a fix: one call, three invariants."
---

# MEASURED 2026-10-02, and AV2 is answered without a new instrument

R4 asked for the gap to be characterised before AV2 was ruled. It did not need the
diagnostic that was scheduled for it: the split is in the source, and the release
manager supplied one day's user-agent distribution from the live log, which settled
the rest. **H0 is discharged. Every number below is measured.**

## 1. The gap is `asset_hits`, and the report never publishes it

`plugins/stats.pl`, `_apply_event` (around line 1984):

    $b->{cls}{$cls} += $sign;                      # EVERY event in the class
    ...
    return unless $cls eq 'human';
    $is_asset = _is_asset( $r->{path} ) unless defined $is_asset;
    if   ( $is_asset && $st < 400 ) { $b->{asset_hits} += $sign }
    else                            { $b->{hits}       += $sign }

So `cls{human}` counts every human-classed REQUEST and `hits` excludes successful
asset fetches. `totals.human_visits` is `$hits`; `by_day[].human` and
`traffic_classes.human.visits` are `cls{human}`. **The difference is exactly
`asset_hits`, and `asset_hits` is in no projection of the report** - which is why the
two figures could not be reconciled from the output.

Confirmed on the three saved reports: gap 2,870 (xisl 30d), 2,869 (xisl 90d), 0
(opendigital.cc - it serves no assets through the engine, which is why that site
shows no split at all).

## 2. `human_visits` counts 404s as visits

xisl.com status codes: 200 = 10,366, 304 = 460, **404 = 8,023**, summing to 18,849 =
`cls{human}`. A 404 has `$st >= 400`, so it misses the asset branch and lands in
`hits`. Therefore:

| | |
| --- | --- |
| `totals.human_visits` | 15,979 |
| of which 404s | **8,023** |
| real page views (10,826 successful - 2,870 assets) | **7,956** |

Half of what the report calls human visits are requests for pages that do not exist.

## 3. `unique_visitors` counts every class, and the manager page knows better

`stats.pl:2501`, at the call site, before any class test:

    $b->{ips}{$tok} = 1 if length($tok) && keys %{ $b->{ips} } < $IP_CAP;

Two structures exist - `ips` (all classes) and `cls_ips{$class}` (per class) - and the
two readers disagree. The manager page (line ~1109) uses `cls_ips{human}` **and says
why in a comment**:

> HUMAN visitors only. [...] Summing `$b->{ips}` instead would put scanners in the
> headline - 71.7% of traffic on the instrument - which is the opposite of what this
> whole filing is about.

`analyse_visitors` (line 3038) sums `$b->{ips}`. **The agent-facing export does the
thing the page's own comment warns against**, which is the whole of AV3: 4,359 uniques
beside 4,241 visits is two populations in adjacent fields, not a contradiction in the
data. `cls_ips` already exists, so the fix is to read what the page reads.

## 4. `human` is a FALL-THROUGH, not a measurement

`classify()` ends:

    return 'bot' if $ua =~ $BOT_RE;
    return 'logged_in' if $is_mgr || ( $is_auto_ep && $browser );
    return 'human';

`human` means *no automation rule matched*. And `_is_browser($ua)` **is computed** at
line 961 - then consulted only in the `ai` and `logged_in` branches. The `human`
return never asks whether the client is a browser, so a request with no user-agent at
all falls through to it.

**Measured, by running the release manager's real agent distribution through the
engine's own `--classify` probe** on an ordinary content path, so only the UA decides.
Top 40 agents, 16,438 requests:

| Class | Requests | Agents |
| --- | --- | --- |
| human | **12,634** | 22 |
| bot | 2,673 | 12 |
| ai | 1,131 | 6 |

Inside `human`:

| Requests | Agent | What it is |
| --- | --- | --- |
| **4,227** | `-` | **no user-agent at all** - the largest single "human" agent on the site |
| 341 | `WordPress/6.4.3` | a WordPress client, on a site with no WordPress |
| 325 | `...GeedoShopProductFinder...` | a product crawler wearing a Chrome string |
| 228 | `UnifiedPaths/1.0` | self-declared tool |
| 154 | `WP-Safe-Scanner/1.0` | **says "scanner" in its own name** |
| 123 | `lzs-fetch/1.0` | **our own fetcher** - `$AGENT_RE` catches `lazysite-agent/` and misses this |
| 86 | `SeltzSitemapFetcher/1.0` | self-declared fetcher |

**5,484 of 12,634 - 43% of the sampled `human` class - is an empty UA or
self-identifying automation.** A further 1,485 are truncated or implausible browser
strings (`Chrome/120.0.0.0` with no AppleWebKit; `AppleWebKit/537.36` with no Chrome
or Safari; `Firefox/47.0` on Windows 7): not called automation here, but not evidence
of a person either. This is the top 40 agents only, so **every figure is a floor**.

## What is NOT a defect, checked so nobody chases it

`data_from` is `2026-09-12` on both xisl reports, so the 30-day and 90-day windows
cover the same data. The near-identical totals (15,979 / 15,977) are that, not drift.

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

**R4 IS DISCHARGED, and H0 was not needed.** The gap turned out to be a known
quantity the report declines to publish, and the source said so. The diagnostic that
was scheduled to characterise it is withdrawn rather than built.

# Rulings, later the same day, on what the measurement found

**R8 - THE REPORT MUST EXPLAIN WHAT THE GROUP IS.** Put to the release manager as a
rename; the answer was neither of the offered names:

> "this does need an explanation to the user, to say that we can't know it is human,
> but we can know when it isn't, so whatever is human exists in this group."

So the requirement is **epistemic, not cosmetic**. The group is an UPPER BOUND on
human traffic: the engine cannot verify a person, it can only recognise automation, so
every human visit is in this group together with everything it failed to exclude. The
report says that, in those terms, where a site owner reads it.

**R12 - AND THE KEY IS RENAMED TO `unattributed`, IN THIS RELEASE.**

# A WRONG REASON I GAVE, RETRACTED - recorded because the next reader would inherit it

R8 was first written here with the key NOT renamed, on this reasoning: *"a rename is a
breaking change for every reader, dashboard and layout, so it should not ride along
with an arithmetic fix."*

**That was an assertion, not a measurement, and it is false.** The release manager
asked what purpose the parking served. Measured:

| Where | `human` as a class key |
| --- | --- |
| `plugins/stats.pl` | **8 usages**, plus `@CLASSES` at line 112 |
| `lib/` | none |
| `tools/` | none |
| any `.tt` template | none |
| any front-end file | none |

One file. No dashboard, no layout, no template. The sweep that produced the original
claim matched the WORD "human" in prose and in unrelated code, and I did not narrow it
before drawing a conclusion from it - the same failure this filing spends four sections
correcting in other people's reports.

**And the positive case runs the other way:**

- **This is the one release where consumers must look anyway.** `schema_version` goes
  2 -> 3, the counting basis goes 3 -> 4, and a class is added. Renaming later means a
  SECOND breaking change and a SECOND schema bump for the same defect.
- **Parking it would make R8's explanation a COMPENSATION for a key we know is wrong.**
  The note would exist to excuse the name. Rename the key and the same sentence becomes
  a plain description instead of an apology - and compensations compound.
- **`@CLASSES` is the single source and SM330 built it for this**: "a class added later
  cannot be silently omitted from some of them." The rename reaches `traffic_classes`,
  `by_day` and every projection by construction.

The real blast radius is the eight usages above plus external JSON consumers - who are
exactly the readers already obliged to adapt to schema 3.

**So `human` becomes `unattributed`**: what the engine actually did is fail to
attribute the traffic to a known agent. The report states the containment property in
the release manager's own terms - any human traffic is in this group, because the
engine can only recognise what is not a person.

**R9 - THE FALL-THROUGH GAINS A POSITIVE BROWSER TEST, AND AN EMPTY USER-AGENT GETS
ITS OWN CLASS.** A request with no user-agent is a fact worth reporting rather than a
residual, so `no_agent` becomes a class of its own: the 4,227 are visible and
separable instead of silently inflating the headline. The buckets still sum.

**R10 - THE RULES MATCH SELF-DECLARATION, NOT A VENDOR LIST.** `scanner`, `fetcher`,
`crawler`, `spider`, `-finder`, `WordPress/`, `curl/`, `wget/`, `python-requests` -
so the next tool of this shape is caught without anyone noticing it first. And
`lzs-fetch` joins `$AGENT_RE`: our own tooling in our own numbers is a defect, not a
judgement call.

**R11 - `/websocket` IS COUNTED OUTSIDE THE HUMAN GROUP.** The release manager
identified the cause: the domain replaced a site that used websockets, so a browser
somewhere is still reconnecting. **Not a defect in this engine, and not a visit
either** - 5,418 retries to a path that has never existed on this site. A persistent
reconnect to a path that has never resolved is automation by behaviour whatever its
user-agent says.

# THE CONSEQUENCE NOBODY MAY SKIP: this is counting basis 4

`stats.pl:140` carries `$COUNTING_BASIS = 3` and a comment that exists because this
has already gone wrong once:

> an operator asked why traffic dropped on 27 July, and the answer needed data from
> before `data_from` that no longer existed.

R9, R10 and R11 move traffic OUT of the reported group. Counts will **drop**, per
site, on the date each instance upgrades - a metric change wearing the clothes of a
traffic change, and a drop is the direction that generates alarm. So:

- `$COUNTING_BASIS` becomes **4**, with its own line in the ladder at `stats.pl:131`;
- a closed day file is never rewritten, so every day already rolled up keeps basis 3
  and the series carries an honest step rather than a silent one;
- `schema_version` goes from `2` to **3**: `traffic_classes` and `by_day` gain a key.
  Both are derived from `@CLASSES` (SM330), so adding `no_agent` propagates to every
  projection without a fifth hand-written copy - the design anticipated this.

Shipping any of R9-R11 without the basis bump recreates exactly the question SM338
was written to prevent, and this time for a fall.

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

# BUILT 2026-10-02 (e4036dbc): AV1-AV10, counting basis 4, schema 3

All ten rows are in, as one change - AV10 required it, and the three sabotage
cases below show why splitting them would have published a report contradicting
the last one.

| Ref | State |
| --- | --- |
| AV1 | `t/unit/plugins/46-one-report-does-not-contradict-itself.t`, GREEN. Six invariants over ONE call, on a fixture that reaches every counter |
| AV2 | Three-way split in `_apply_event`: `error_hits` for >= 400, `asset_hits` for a successful asset, `hits` for a successful page. All three published; they sum to the class |
| AV3 | `unique_visitors` reads `cls_ips{unattributed}`; `traffic_classes[].visitors` added, so the per-class counts the old sum stood in for are still there |
| AV4 | `totals.human_visits` **removed**. It was the same scalar as `pageviews`; one name goes, because there was only ever one counter |
| AV5 | `window_scoped`, enumerated per field rather than marked on the two that prompted the question. `events` is ABSENT from it on purpose - neither boolean is true of a field that is window-filtered AND ring-capped |
| AV6 | `unattributed`, with the upper-bound explanation in `notes` where an operator reads it |
| AV7 | `no_agent` as its own class, returning BEFORE the visit split |
| AV8 | `$BOT_RE` += `scanner|fetcher|finder|WordPress/`; `$AGENT_RE` += `lzs-fetch` |
| AV9 | `$NOISE_RE` += `websocket|socket.io|sockjs-node|\bws\b` |
| AV10 | `$COUNTING_BASIS = 4`, `schema_version` '3', the ladder entry - and `counting_basis` + `counting_basis_in_window` **published in the report**, which they never were |

**And one row that was not in the plan.** Writing AV1's third invariant found
that `status_codes` counts the `unattributed` class alone - the increment sits
below `_apply_event`'s early return - and the report named that population
nowhere: nine fixture requests produced six statuses with nothing to account for
the other three. The behaviour is right and is kept (a scanner sweep would
otherwise bury a site's real 404s). What was missing was the denominator, so
every published counter now names its population in a `populations` map. That is
SM888 S3 in the export rather than on the screen, and it was found by writing the
test the reporter asked for rather than by reading the code again.

## Two things I got wrong in this build, both measured false

**The parked rename.** The first draft of this filing parked AV6 on the claim
that renaming `human` would break every reader, dashboard and layout. That was an
assertion, not a measurement. Measured: 8 usages in ONE file, none in `lib/`,
`tools/`, templates or the front end. Retracted in the body below rather than
quietly corrected, and recorded as R12.

**The cache.** I wrote a comment in `_apply_event` saying an entry carrying the
literal string `human` could not survive because `schema_version` 3 would discard
the cache. It would not. The cache gate is `v`, which distinguishes the
server-log shape from the first-party shape and knows nothing about class names
or the counting basis; `schema_version` is a field in the OUTPUT. Nothing would
have dropped the cache and nothing would have errored - every existing day bucket
would have kept `cls{human}`, every breakdown is derived from `@CLASSES` which no
longer lists it, and that traffic would have **vanished from `traffic_classes`
and `by_day` while remaining inside `hits`**: a sum that does not add up, in the
release whose purpose is sums that add up. `_migrate_human_class` renames the key
on load instead. A rename and not a discard, because a basis-3 `human` count IS
this release's `unattributed` group drawn wider, and `counting_basis` already
explains the difference. Day FILES are untouched: a closed day is immutable and
carries its own basis, which is SM338 working rather than an omission.

## The fixtures were lying, and the rename is what exposed it

Three fixtures in `t/unit/plugins/` wrote the visitor log's user-agent as `u`.
The ingester reads `ua` - the key the processor's own writer emits. So every line
those fixtures produced reached `classify()` with an **empty user-agent**, the old
`return 'human'` fall-through swallowed it silently, and the tests passed while
asserting a class they were not exercising. Nothing in them tested the
first-party UA path at all. Renaming the class is what made it visible, because
an empty user-agent now has a name of its own.

`t/unit/manager/159` had the same shape of fault: its fixture payload named
`human`, and it kept passing after the rename because the draw list comes from
the payload's own keys - so it was asserting that the page draws whatever it is
given. Its own header says the page "held its own copy of the list - which is how
it fell a release behind"; so did the test. It now reads `@CLASSES` from the
plugin.

## Sabotage, five cases, exact-replacement

| Sabotage | Subtest that fails |
| --- | --- |
| 404s go back into the visit count | `every counter the invariants cover has something in it` |
| `unique_visitors` sums every class again | `unique visitors cannot outnumber their own visits` |
| an empty user-agent falls through again | `every counter the invariants cover has something in it` |
| `months` loses its `window_scoped` marker | `the report states its own basis and scope` |
| `human_visits` comes back beside `pageviews` | `nothing in the report claims to have measured a person` |

**The first attempt proved nothing on four of the five.** It used
`perl -0pi -e` with `\Q..\E` anchors; three regexes matched nothing, the file
was unchanged, and the suite passed. Redone in Python as exact string
replacement, asserting one occurrence BEFORE the run and the byte count after.
Same mistake as SM824's first attempt, one batch later.

**Worth recording about case 1:** the sum identity STILL HOLDS with 404s inside
`hits` - `hits` + `asset_hits` equals the class either way, because the split
moved which counter they are in and not how many there are. The detector is the
"every counter has something in it" guard, which exists to catch a fixture that
has stopped exercising a case. It is load-bearing here, not decoration.

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

| Ref | The work | Cx | Needs |
| --- | --- | --- | --- |
| AV1 | The invariant test: the group totals in `totals`, `by_day` and `traffic_classes` agree; `unique_visitors <= ` the group's visits; `status_codes` sums to a population the report names. **Lands GREEN beside the fixes**, which is what R5 held it for | S | AV2-AV4 |
| AV2 | **ANSWERED, not a ruling any more.** Publish `asset_hits`; stop counting 404s as visits; name each counter's population in the report. The two figures were requests-including-assets and requests-excluding-successful-assets, and neither was page views | M | nothing |
| AV3 | `unique_visitors` reads `cls_ips{<group>}`, as the manager page already does, instead of `ips` | S | nothing |
| AV4 | `human_visits` and `pageviews` are **the same scalar** (`stats.pl:3135`): one name goes, or each is filled from the counter it claims | S | AV2 |
| AV5 | `months`: a `window_scoped` field, or clip the rows. Presentation, not arithmetic | S | nothing |
| AV6 | **R8 + R12**: `human` becomes `unattributed` (8 usages, one file), and the report explains that the group is an upper bound - we cannot know a request is a person, only when it is not | S | nothing |
| AV7 | **R9**: a positive browser test on the fall-through, and `no_agent` as its own class | M | nothing |
| AV8 | **R10**: self-declaration tokens in `$BOT_RE`, and `lzs-fetch` in `$AGENT_RE` | S | nothing |
| AV9 | **R11**: a persistent reconnect to a path that has never resolved counts outside the group | M | nothing |
| AV10 | **Basis 4 and schema 3**, with the ladder entry. Ships WITH AV6-AV9 or not at all - the renamed key, the new class and the moved traffic are one schema change, not four | S | AV6, AV7, AV8, AV9 |

**One thing to get right while renaming:** `no_agent` events must NOT reach the
`hits` / `asset_hits` split. Those branches sit behind `return unless $cls eq 'human'`
(becoming `unattributed`), so an empty-UA request stops contributing to the visit
counters by construction rather than by a second rule - which is how the 4,227 leave
the headline without anything being subtracted anywhere.

# Related

[[SM579]] (the visitor outcome), [[reference_lazysite_stats_gotchas]],
[[feedback_buckets_must_sum_and_population_drawn_apart]] - which is this filing's
whole shape: buckets that do not sum, and two populations drawn apart without being
named.
