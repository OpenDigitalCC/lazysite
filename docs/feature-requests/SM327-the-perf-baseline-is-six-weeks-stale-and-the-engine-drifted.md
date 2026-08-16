---
title: "SM327 - re-capturing the baseline would have hidden a real regression"
subtitle: "Every operation is 9-26% slower than the 2026-07-02 baseline on the same host, same Perl, same iteration count. The 2x tolerance passes all of it."
brand: plain
status: candidate
status-note: "FILED 2026-08-16 INSTEAD OF re-capturing the baseline, which was the queued task. The compliance gate warns that the baseline is stale and the obvious action is `bench.pl --baseline`. Measuring first showed that would bake in a consistent 9-26% regression and permanently remove the ability to notice it - clearing a warning by lowering the bar, which is the defect class this project keeps filing. NOT re-captured. The drift is real and wants attributing before any new baseline is taken."
---

# What was measured

Three consecutive runs, host `ai-dev`, Perl v5.40.1, 20 iterations - identical to
the baseline's own provenance. Load average 0.22, 0.42, 0.46.

```datatable
columns: Operation | Baseline | Run 1 | Run 2 | Run 3 | Drift
widths: 4.6cm | 2cm | 1.8cm | 1.8cm | 1.8cm | X
bold: 1
tone: medium
---
`render_cache_hit_ms` | 60.0 | 64.2 | 65.9 | 66.5 | +9%
`render_miss_ms` | 83.6 | 90.6 | 92.0 | 90.8 | +9%
`verify_password_ms` | 120.8 | 133.0 | 135.2 | 130.5 | +10%
`verify_token_ms` | 32.7 | 41.7 | 41.1 | 41.1 | **+26%**
---
```

Run-to-run spread is 2-3%. The gap to baseline is 9-26% and present in every run
of every operation. That is drift, not noise.

# Why nobody noticed

The gate's tolerance is **2x**. A 26% regression passes it comfortably, and the
gate has reported "all ops within tolerance of baseline" on every release
including the four cut this fortnight.

`tools/bench.pl` already says so, in a comment added during the last review:

> without this a figure cannot be interpreted. A run on a loaded host and a
> genuinely slower engine look identical in the numbers, and the 2x tolerance
> passes both - so nobody ever finds out which they are looking at.

That comment was about recording the load average. The same sentence turns out
to describe the tolerance itself.

# Why the baseline was NOT re-captured

Re-capturing was the queued task, and the compliance gate asks for it: the
baseline is dated 2026-07-02 and warns as stale at a stable cut.

Doing it would have raised the baseline to the current, slower numbers and
removed any way to see that the engine had got slower. A warning would have
cleared, the gate would have gone green, and the regression would have become the
new definition of correct.

**That is the shape this project has spent a fortnight removing from other
people's code**: a control reporting success because the bar moved. It should not
be introduced into the perf gate to clear a housekeeping warning.

# What the drift is not

Ruled out by measurement rather than assumption:

- **not the host** - `ai-dev` both times, recorded in the baseline
- **not the Perl** - v5.40.1 both times, recorded in the baseline
- **not machine load** - three runs at 0.22 to 0.46, and the spread between them
  is 2-3% against a 9-26% gap
- **not iteration count** - 20 both times

# What to do, in order

Attribute it before re-baselining
: the baseline predates 0.8.0 and the current tree is 0.10.10, so the drift spans
  many releases. `verify_token_ms` at +26% is the one to start with: it is on
  every authenticated API and MCP request, and it is the only operation whose
  drift is meaningfully worse than the others. Benching a few intermediate tags
  on this host would localise it in an hour.

Then decide the tolerance
: 2x is wide enough that a doubling of any operation ships silently. Whatever it
  is narrowed to should be a deliberate figure with a reason, not merely tighter
  - a gate that is flaky gets ignored, which is worse than one that is wide.

Then re-capture, deliberately
: with the drift explained and either accepted or fixed. A baseline is a claim
  that these numbers are RIGHT, not merely current, and it should only be taken
  when someone believes that.

# Related

The 0.10.9 review's D4 finding (the baseline was not re-captured, recorded as
build-side work identified and not done), `tools/bench.pl`, and
`tools/lazysite-compliance.pl`, whose stale-baseline warning is correct and whose
obvious remedy is the wrong one.
