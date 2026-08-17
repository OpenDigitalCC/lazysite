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

# Why it is worth a filing rather than a caveat

**It certifies in the wrong direction.** A change that adds file writes - which
is a normal thing for this engine to do - costs little on a fast local disk and
can cost a great deal on contended storage. The gate would pass it. The
inverse is also true and less dangerous: a change that trades writes for CPU
would look worse here than it is in the field.

**The one measurement anybody has from real hosting was taken by accident.**
[[SM340]] was found because a partner agent timed its own tool calls and noticed
that asking for one day cost what asking for a year cost. Nothing in this
project routinely produces a figure from an environment resembling where the
product runs.

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
  the number back, and it should not be invented before the cheaper items
  above are done.

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
