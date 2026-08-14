# Dimension 4 - Performance - lazysite 0.10.9

- Audited artefact: tag `v0.10.9` at `f8bee33`, in a clean worktree
- Date: 2026-08-14
- Regime: Commercial
- Prior verdict: WARN (2026-08-14, at 0.10.8)

## Verdict

**WARN**, unchanged, and for exactly the reasons stated last time. The two
remedies named then were build-side and neither was done. This run then
demonstrated the underlying problem more clearly than the last one argued it.

## Findings

### F4.1 - The baseline still predates the work it gates (WARN, carried)

```json
"captured_at" : "2026-07-02T08:41:10Z",
"tolerance" : 2
```

Unchanged. It now predates three minor lines rather than two. A baseline that
predates the work it gates cannot detect a regression introduced by that work.

### F4.2 - No registry-generation op (WARN, carried)

SM293 step 3 moved the registries onto the request path and no benchmark op
covers them. Unchanged.

### F4.3 - This run cannot tell drift from load, which is the finding (WARN)

`bench.pl --check` passed. The numbers:

| Op | Baseline | This run | vs baseline |
|---|---:|---:|---:|
| `render_cache_hit_ms` | 60.0 | 87.3 | +45% |
| `render_miss_ms` | 83.6 | 120.2 | +44% |
| `verify_password_ms` | 120.8 | 173.9 | +44% |
| `verify_token_ms` | 32.7 | 58.0 | +77% |

**These figures are not reported as drift.** The audit ran other work on the
same host, and a measurement taken under unknown load is not evidence about the
code. A comparable run six hours earlier on the same tree gave 65.1 / 89.9 /
132.9 / 41.7, which is itself well above baseline.

That ambiguity is the finding. With a six-week-old baseline, a 2x tolerance and
no record of host conditions, **nobody can distinguish a loaded host from a
slower engine** - and the gate reports "within tolerance" either way, so nobody
has to try.

Three things would fix it, none large: re-capture at each cut; record the load
conditions alongside the numbers; and add a warn-level band well below the 2x
hard stop so drift is visible without making the gate flaky.

### F4.4 - The pooled front door measured itself properly (PASS, noted)

SM294 shipped with a like-for-like comparison - same URL, same authentication
state - giving 71.9 ms to 0.53 ms on an anonymous page and 107.3 ms to 96.9 ms
on a signed-in one, with the reproduction script committed. The first version of
that comparison measured a cached anonymous hit against a signed-in miss and
appeared to show a 34% regression that did not exist.

That is the standard the four ops above are not being held to.

## Evidence

- `dist/config/bench-baseline.json` - capture date and tolerance.
- `perl tools/bench.pl --check` on the audited tree - rc 0, figures above.
- `tmp/sm294-bench.pl` - the like-for-like comparison.
