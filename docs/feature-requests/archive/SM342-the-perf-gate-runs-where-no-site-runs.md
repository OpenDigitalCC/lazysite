---
title: "SM342 - the perf gate runs where no site runs"
subtitle: "Every benchmark figure this project holds was taken on a development host with a local, uncontended, fast disk. Real sites are on shared hosting with contended storage, and the operations that matter most are I/O-bound."
brand: plain
status: shipped
status-note: "SHIPPED 2026-08-17 on the release manager's instruction that the gate \"should be comparative, to make sure work doesn't increase or to make sure optimised - it isn't pass/fail\". That is the right shape and it resolves the filing's own tension: a duration measured here says little about a contended disk, so timings are now REPORTED with their ratio to the baseline and never fail a build, while WORK - counted by the operation itself, exact and host-independent - is what fails. The cheapest remedy the filing listed turned out to be the right one. The sharp counter is the warm read: a second call with nothing new in the log must read ZERO bytes, and a zero that becomes non-zero is [[SM340]] returning. Measured on the fixture: cold 524,392 bytes across 30 files, warm 0."
---

# What the confound is

```datatable
columns: | Where the numbers come from
widths: 5cm | X
bold: 1
tone: medium
---
`tools/bench.pl` | a development host, local uncontended disk, engine run directly
A real site | shared hosting, storage contended by every other tenant, reached through a web server
---
```

The operations this gate covers are not CPU-bound. The statistics export reads
every retained log and rewrites four files per call. A render reads Markdown and
writes an HTML cache. Credential verification is deliberately expensive in CPU
and is the exception rather than the pattern.

So the gate measures the component that varies least between the two
environments, and is close to blind to the one that varies most.

# Measured from the field, which a development host cannot do

Contributed by the partner agent on edge/0.10.11, all three calls on the same
instrument so the comparison is within-host and inherits none of the confound
this filing is about.

```datatable
columns: Call | Response | Time | What it isolates
widths: 2.6cm | 3cm | 2.2cm | X
bold: 1
tone: medium
---
`whoami` | 4,115 bytes | 484 ms | the calling surface's own floor - no stats path
`day` | 4,115 bytes | 3,441 ms | engine work, minimal payload
`window` | 1,098,265 bytes | 4,168 ms | the same, plus 267x the payload
---
```

**The payload hypothesis is refuted by its own test.** It was run to check
whether a megabyte of JSON was hiding in the 3.5 seconds: a 267-fold increase in
response size costs 0.73 s. Payload is a minor term.

So roughly **2.96 s is engine work invariant to both window size and payload
size** - re-ingestion plus the four unconditional writes - against 630.7 ms for
the same operation on the development host.

## What that isolates

The two corpora differ: 13,013 visits over 34 days on the instrument against
4,500 over 30 in the fixture - 2.9x the events, 1.13x the days. Scaling the
development host's terms by those factors predicts about **1.0 s** of engine
work.

The instrument measures 2.96 s. **The remaining ~3x is the storage**, and it is
the term neither instrument was built to see.

## The two agents reached this from opposite ends

Worth recording as method rather than as narrative. The partner built a model
from the development figures, predicted 1.56 s, measured 3.5 s, and identified a
missing term of 2.2x - without knowing what it was. The confound was named
independently, from the other side, by someone who knew both machines. Neither
route alone would have produced a number; the model gave the size of the gap and
the observation gave its cause.

# Why it is worth a filing rather than a caveat

**It certifies in the wrong direction.** A change that adds file writes - which
is a normal thing for this engine to do - costs little on a fast local disk and
can cost a great deal on contended storage. The gate would pass it. The
inverse is also true and less dangerous: a change that trades writes for CPU
would look worse here than it is in the field.

**Every measurement this project has from real hosting was taken by a partner
agent timing its own tool calls.** [[SM340]] was found that way - asking for one
day cost what asking for a year cost - and so were the figures above. Nothing in
the project itself routinely produces a number from an environment resembling
where the product runs, and the two that exist arrived because somebody outside
it was curious.

**It compounds with the two known gaps.** [[SM327]] established that a 2x
tolerance permits unbounded accretion; SM340 established that a hot path had no
coverage at all. Both were about what the gate looks at. This is about where it
stands, and a tighter tolerance on a figure from the wrong machine buys less
than it appears to.

# What would actually help, in rough order of cost

Say what the environment was
: the baseline already records host, Perl and load average ([[SM327]]'s
  provenance work). It does not record anything about the storage. A figure
  whose disk characteristics are unknown cannot be compared to one taken
  elsewhere, and today nothing stops that comparison being made.

Report I/O separately from CPU
: a per-op split would make the transferable part of a measurement visible. A
  change that moves CPU is portable news; a change that moves writes is news
  about a machine.

Measure the operations by their work, not only their time
: bytes read, files written, syscalls. These are host-independent and they are
  what actually got worse in SM340 - it re-read every retained log on every
  call, and that statement is true on any disk. A gate on work done would have
  caught it anywhere, including here.

Take one figure from real hosting
: the hardest and the most honest. It needs somewhere to run and a way to get
  the number back, and it should not be invented before the cheaper items above
  are done. Note that the figures above are exactly this, obtained without any
  of that machinery - which suggests the first version is a documented manual
  procedure rather than an automated one.

  A manual procedure also has a property the automated version loses, and it is
  the one this filing is about: it produces a number somebody has to look at and
  sign off, rather than one that passes silently. The failure mode here is a
  gate certifying something nobody read.

DONE - decomposed on deployment, 2026-08-17
: it worked as sketched. With the cache loading, the day call on the instrument
  costs 1052 ms against a 421 ms surface floor, so the **per-call write term on
  contended storage is roughly 630 ms** - assembly plus the four unconditional
  rewrites. That is the field figure this filing asked for, and it arrived as a
  by-product of testing a release rather than from any machinery.

  Set against 425 ms for the whole operation on the development host, including
  its re-ingestion. The writes alone cost more in the field than everything did
  here, which is this filing's argument in one comparison.

The sketch, as originally written
: decompose it once [[SM340]] is deployed
: the instrument cannot separate re-ingestion from the per-call writes while
  they are welded together in one number. After the fix, `call 1 - call 2` is
  the re-ingestion term and `call 2 - the surface floor` is the write term paid
  every call. That second figure is the contended-storage number this filing
  wants, and it arrives as a by-product of testing the release.

# What this filing does not claim

The existing figures are not worthless. They are valid HOST-RELATIVE
comparisons, which is what `tools/bench.pl` says it produces and what it is
used for - and it caught nothing wrong here because nothing here regressed.

The defect is narrower: the gate cannot see a class of regression that this
product is specifically exposed to, and nothing currently says so at the point
where someone reads a passing result.

# What shipped

**The export counts its own work** - log files opened, bytes ingested, day files
written - and reports it. An operation is the only thing that can count exactly
what it did; inferring it from outside is guesswork on a shared machine.

**Two measurements, and the second is the interesting one.**

```datatable
columns: | What it is | Baseline
widths: 4cm | X | 2.6cm
bold: 1
tone: medium
---
`work_cold_log_*` | a full ingest with no cache - the size of the job, scales with retention | 524,392 bytes / 30 files
`work_warm_log_*` | the next call, nothing new in the log - there is nothing to do | **0 / 0**
---
```

The warm figure is the [[SM340]] detector. When the cache was never loaded, the
warm read was the ENTIRE retained log, every call, on every site. A zero that
becomes non-zero is that defect returning, and it reads the same on any disk.

**Timings are reported, never failed on.** Each op prints with its ratio to the
baseline, and drift is called out in both directions - `SLOWER than baseline
(reported, not failed)` and `FASTER / LESS WORK than baseline`, because a gate
that only speaks when something got worse cannot confirm that an optimisation
landed.

This immediately surfaced what [[SM327]] found and the 2x tolerance hid:
`verify_token_ms` reports at **1.26x** baseline. Visible now, and not a build
failure, which is the honest treatment of a number that is partly about this
machine.

**A count is what fails.** Exact, host-independent, and an increase means the
code is doing more than it did - so the message says so rather than implying a
slow machine.

# Verification

- A baseline records enough about its environment that a reader can tell whether
  a comparison across two of them is meaningful.
- A change that adds file writes to a hot path is visible in the gate's output,
  on any host.
- The gate's own output does not imply coverage it does not have.

# Related

[[SM327]] (the tolerance, and the baseline provenance this extends), [[SM340]]
(the hot path with no coverage, whose correction produced this), and
`tools/bench.pl`.
