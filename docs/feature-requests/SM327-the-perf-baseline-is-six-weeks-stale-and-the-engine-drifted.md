---
title: "SM327 - re-capturing the baseline would have hidden a real regression"
subtitle: "Every operation is 9-26% slower than the 2026-07-02 baseline on the same host, same Perl, same iteration count. The 2x tolerance passes all of it."
brand: plain
status: shipped
status-note: "SHIPPED 2026-08-18, both halves. THE TOLERANCE IS 1.25 and the reasoning sits with the number: the drift arrives as accretion rather than one step, so a 2x gate can never catch it - nothing single is ever large enough - while 1.25 would have caught the one real step and stays well clear of a ~1.5% noise floor. Not tighter still, because a flaky gate gets ignored, which is worse than a wide one, and SM342 deliberately reports timings rather than failing on them since a busy host and a slower engine look identical in milliseconds. AND THE MORE IMPORTANT HALF: `--baseline` now REFUSES to re-capture over a regression, naming each op with its ratio and both figures. That is the filing's actual argument - re-capturing was the queued housekeeping task, the compliance gate asks for it, and doing it would have raised the baseline to the slower numbers, cleared a warning and made the regression the new definition of correct. --accept-regression proceeds; the flag is not meant to be hard to type, it is meant to make somebody state that these numbers are RIGHT rather than merely current, which is what a baseline claims. FILED 2026-08-16 INSTEAD OF re-capturing the baseline, which was the queued task. The compliance gate warns that the baseline is stale and the obvious action is `bench.pl --baseline`. Measuring first showed that would bake in a consistent 9-26% regression and permanently remove the ability to notice it - clearing a warning by lowering the bar, which is the defect class this project keeps filing. NOT re-captured. The drift is real and wants attributing before any new baseline is taken."
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

# Attributed, 2026-08-16

Benched across the release line in throwaway worktrees, one run per tag, against
a ~1.5% run-to-run noise floor measured at HEAD.

```datatable
columns: Tag | verify_token_ms | Note
widths: 3cm | 3.4cm | X
bold: 1
tone: medium
---
baseline (2026-07-02) | 32.7 | -
v0.7.15 | 35.2 | -
v0.7.22 | 36.2 | -
v0.7.24 | 36.4 | flat
v0.7.26 | **39.3** | **+2.9 ms, the one step above noise**
v0.7.28 | 39.4 | flat
v0.9.17 | 39.8 | -
v0.10.0 | 39.7 | -
v0.10.8 | 41.6 | -
v0.10.11 | 41.7 | -
---
```

**There is no single culprit.** One step exceeds the noise floor - v0.7.24 to
v0.7.26, +8% - and the remaining +6 ms is accretion: a milligram per release,
none of it individually visible, none of it anywhere near a 2x tolerance.

That reframes this filing. "Attribute it before re-baselining" assumed a step
change to find and revert. What is actually there is a ratchet with nothing
holding it, and the tolerance is the reason: **a gate that only fails at 2x
permits unbounded accretion, because no single release ever doubles anything.**

## What the one real step contains

The v0.7.24-v0.7.26 window is 40 commits and includes SM163, which made
`touch_credential` record credential use on the API-token and WebDAV paths. That
calls `read_settings()` on **every token verification**, and `read_settings` was
not memoised - it opened, slurped and `decode_json`'d the whole user-settings
file each time.

Measured directly: **1.3727 ms per read** of a settled 40-user file, against
0.0045 ms once memoised (SM334). That is roughly HALF the 2.9 ms step, so it is a
real contributor and not the whole of it - the rest is elsewhere in those 40
commits, and finding it would cost more than it is worth at this granularity.

Worth stating because it was nearly overclaimed: `verify_token_ms` is dominated
by credential hashing, which is deliberately expensive. A 1.4 ms saving on a
41.7 ms operation does not show up in the bench at all, and the memoisation's
value is in the requests that read settings several times, not in this number.

# What to do, in order

Attribute it before re-baselining
: **done, see above.** One step above noise, the rest accretion. No revert
  recovers it.

Then decide the tolerance - THIS IS NOW THE MAIN ITEM
: the attribution says the drift arrives as accretion, so a 2x gate cannot ever
  catch it. Something in the region of 1.15-1.25x would have caught the one real
  step and would catch the next one, while staying well clear of a 1.5% noise
  floor. The figure should be deliberate and stated, not merely tighter - a
  flaky gate gets ignored, which is worse than a wide one.

Then re-capture, deliberately
: with the drift explained and either accepted or fixed. A baseline is a claim
  that these numbers are RIGHT, not merely current, and it should only be taken
  when someone believes that.

# Related

The 0.10.9 review's D4 finding (the baseline was not re-captured, recorded as
build-side work identified and not done), `tools/bench.pl`, and
`tools/lazysite-compliance.pl`, whose stale-baseline warning is correct and whose
obvious remedy is the wrong one.
