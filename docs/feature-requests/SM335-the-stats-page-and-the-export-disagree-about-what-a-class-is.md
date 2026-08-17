---
title: "SM335 - the Stats page and the export disagree about what a visitor class is"
subtitle: "The manager page reports human, logged_in, ai, bot and noise. The export reports human, ai, bot, noise and scanner. Neither list contains the other, and the page an operator reads is the one that cannot show a scanner at all."
brand: plain
status: candidate
status-note: "FILED 2026-08-16, found while shipping [[SM330]] and NOT fixed with it, because it is not the same defect and the remedy is a judgement rather than a correction. SM330 was one fact written out four times with one copy wrong. This is two surfaces with genuinely different vocabularies: `scanner` is a VISITOR-LEVEL promotion computed in the export's two-pass tally, and the manager page's window readers classify per request and never run that pass - so the page cannot report a scanner without acquiring the pass, and `logged_in` exists only on the page because the export deliberately reports the audience rather than the operator. Recorded rather than reconciled on the spot."
---

# What was found

Two surfaces read the same traffic and name its parts differently.

```datatable
columns: Class | Manager Stats page | AI export
widths: 4cm | 4.4cm | X
bold: 1
tone: medium
---
`human` | yes | yes
`ai` | yes | yes
`bot` | yes | yes
`noise` | yes | yes
`logged_in` | yes | no
`scanner` | **no** | yes
---
```

On the instance measured, `scanner` is **71.7% of all events**, against 17.2%
human. So the surface a site owner actually opens is the one that cannot show
the largest class of traffic on their site.

**The page is not missing a number; it is putting it somewhere else.** Its five
classes are exactly the five `classify()` returns and they account for every
request it counts, so nothing there sums short. A scanner's probe requests land
in `noise`, and the requests that scanner made either side of them - the
homepage hit, the sweep [[SM332]] catches - land in `human`. The total is right
and the attribution is wrong, which is harder to notice than a total that is
wrong.

That is [[SM330]]'s defect on a more visible surface, arrived at by a different
route: SM330 was one list copied and miscopied; this is two lists that were
never the same list.

# Why it is not the same fix

`scanner` is not a property of a request. It is a **visitor-level promotion**:
[[SM213]] flags a token that probed, and then reclassifies that token's other
requests - which is the whole point, because a scanner's homepage hit is the
part that corrupts the human numbers. That promotion happens in `_tally_batch`,
which only the export path runs. `scan_stats` and `scan_first_party` classify
each request as they read it and keep no per-visitor state.

So the page does not omit `scanner` from a list it could have shown. It has no
mechanism that produces one.

`logged_in` runs the other way: the export drops it deliberately, because the
export is about the audience and the operator's own sessions are not audience.

# What the options are

Give the window readers the visitor-level pass
: the honest fix, and the one that makes the page agree with the export. It
  means a two-pass read where there is currently one, on the path that renders
  a page rather than the path that writes a durable file. Worth measuring
  before choosing - the readers already hold the batch, so it may be cheap.

Have the page read the durable day files
: they already carry all five classes, correctly, and [[SM329]] has just added
  `asset_hits` to them. The page would then show what the export shows by
  construction rather than by agreement. The cost is that the page stops being
  a live read of the log.

  **This is the option the verification constraint favours.** The partner agent
  who found the disagreement holds `ui:false`, so the manager page is not
  reachable from the surface that can measure the export - nobody can currently
  check the two against each other from one vantage point. An option where the
  page and the export agree by construction needs no such check; an option where
  two implementations are kept in step needs one that does not exist.

Leave it, and say so where it is read
: the page's arithmetic is not wrong on its own terms - its five classes are
  exactly the five `classify()` returns, and they account for every request it
  counts. What differs is where the traffic LANDS: a scanner's probes sit in
  `noise` and the requests it made either side of them sit in `human`. So there
  is no shortfall to name, and a note saying "this page classifies per request"
  would be true and would not help anyone reading a number that is 71.7% out.
  Recorded as an option because it is the status quo, and the status quo should
  have to argue for itself alongside the others.

# What changed since this was filed, and what it costs to do properly

Assessed 2026-08-17, after [[SM339]]/[[SM341]]/[[SM343]] landed. Two of the
three options moved.

**Option 2 became viable.** "Have the page read the durable day files" was
filed when those files were frozen at the last call made during their day
([[SM343]]) and carried no timestamp ([[SM341]]). Reading them would have shown
the page truncated history. They are complete and dated now, so the option is
sound where it was not.

**Option 1 is larger than the filing implies.** "The readers already hold the
batch, so it may be cheap" is wrong. `scan_first_party` and `scan_stats` STREAM
- they classify and count line by line, and never hold the batch at all, which
is deliberate on a 90-day log. Visitor-level promotion needs the probe tokens
known before any counting, so it needs either a second pass over the files
(doubling I/O, which [[SM342]]'s work counters would now correctly report as a
regression) or the whole window buffered.

The export already buffers exactly this data, so buffering is not unprecedented
- and unifying both readers onto `_tally_batch` would be the real fix, removing
the duplicated counting logic that [[SM329]] had to correct in three separate
places. That is a ~240-line refactor of the manager Stats page's entire data
contract.

## The recommendation, and why it is not mine to take

**Unify the readers onto `_tally_batch`** - option 1 done properly rather than
bolted on. It gives the page `scanner` while keeping it a live read, it makes
the two surfaces agree by construction rather than by two implementations being
kept in step, and it deletes a duplication that has already produced defects.

It is not a small change and it alters what an operator sees on a page they use.
The trade is a page that reads a buffered window instead of streaming it, and
the beneficiary is every future change to the counting rules, which currently
have to be made twice and were once made only once.

`logged_in` stays page-only either way, and that is correct: the export reports
the audience and an operator's own sessions are not audience. The page being a
superset of the export is coherent; the page being 71.7% wrong about who is
visiting is not.

# Built 2026-08-17, and it forces two decisions before it can land

The unification works. `scan_first_party` and `scan_stats` no longer count
anything: they drive the same ingest the export drives and project the resulting
day buckets into the page's shape. The page gains `scanner`, keeps `logged_in`,
stays a live read, and the second counting implementation is gone. The bucket
grew two fields it lacked (`bytes`, `cls_ips`) and the log parser now returns
the byte count its own pattern was already capturing and discarding.

Two consequences fall out that are **not** mine to decide, because each changes
what an operator sees or can do.

## 1. `anonymise_ip` becomes inert

The shared tally **always** anonymises - `_visitor_token(_anon_ip($ip))`, a /24
truncation then a hash. That is deliberate in the export, which states
`anonymised: true` unconditionally and never had a setting.

The page's reader honoured `anonymise_ip: false` and keyed visitors on the raw
address. After unification that setting has no effect at all.

An inert setting is the defect class this project keeps closing, so the choice is
to **remove the setting** - the honest option, and consistent with the export
having never offered it - or to make the tally honour it, which would put
un-anonymised addresses into a durable store that has been carefully built not
to hold them.

I would remove it. But removing an operator-visible privacy control is a
decision, not a refactor.

## 2. The page's numbers stop being recomputed from scratch

The old reader re-read the window on every call, so a change to
`noise_paths`, `ai_user_agents` or `anonymise_ip` re-classified the whole window
immediately. The shared tally is incremental: a rule change applies to events
ingested afterwards, and events already counted keep the classification they
were given.

That is the same property [[SM338]] exists to record for the counting basis, and
it is defensible - arguably more honest than silently re-writing history when a
setting changes. It is also a visible behaviour change: an operator who adds a
`noise_paths` entry will no longer see yesterday reclassified.

If that is wanted, the mechanism already exists: `--recount` ([[SM339]]) rebuilds
the window from the retained logs under current rules. The setting change would
need to say so.

## What the tests say

Two assertions in `t/unit/plugins/01-stats.t` fail, and both encode the OLD
contract rather than a defect: `anonymised IPs collapse to one` (the raw-IP
keying above) and an error message the page produced itself and the shared
ingest words differently.

They are left failing deliberately. Rewriting a test to match new behaviour is
how a contract change gets made silently, and this one should be made on
purpose.

# Verification

- The Stats page and the export, run against the same log, agree about how much
  of the traffic is a person.
- A site whose traffic is majority scanner does not read as majority human on
  the manager page.
- `logged_in` continues to be excluded from the export, and the reason stays
  recorded where it is applied.

# Related

[[SM330]] (the same shape in the export index, and the `@CLASSES` declaration
that fixed it there), [[SM213]] (the visitor-level pass that produces
`scanner`), [[SM332]] (which adds a second way into that class and so makes the
gap wider), and `starter/manager/stats.md`.
