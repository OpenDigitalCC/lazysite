---
title: "SM342 - the perf gate runs where no site runs"
subtitle: "Every benchmark figure this project holds was taken on a development host with a local, uncontended, fast disk. Real sites are on shared hosting with contended storage, and the operations that matter most are I/O-bound."
brand: plain
status: candidate
status-note: "FILED 2026-08-17, out of a correction to [[SM340]]. A 206 ms saving measured here was compared against a 3.5 s cost measured on the instrument, and the gap attributed to calling-surface overhead and corpus size - both real, neither the main term. The main term is that the same code was run against very different storage. Filed as its own item because the confound is not specific to SM340: it applies to every figure in the baseline and to the gate that compares against them. This is the third member of a family - [[SM327]] found the tolerance too loose to catch accretion, SM340 found a hot path with no coverage at all, and this is the coverage that exists being taken somewhere the product does not live."
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

Decompose it once [[SM340]] is deployed
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
