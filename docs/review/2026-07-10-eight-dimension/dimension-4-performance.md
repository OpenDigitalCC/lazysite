---
title: "Dimension 4 - Performance - lazysite eight-dimension review"
subtitle: "v0.6.10 (5aa6f27), 2026-07-10, Commercial regime"
brand: plain
---

## Verdict

PASS - the declared baseline is met (all four ops between 0.96x and 1.09x of baseline, well inside the 2x tolerance), the gate is wired into `tools/release.sh` so a regression is unshippable, the render op now honestly times both the cache-hit and the cache-miss pipeline, the baseline carries host/perl/date provenance with a host-mismatch warning, and the SM140 recorder's "negligible, bench-gated" cost claim is substantiated by measurement. The residual is bench breadth, not bench integrity: the manager-API and WebDAV hot paths remain unbenchmarked (the prior review's recommendations 4 and 5, still open and untracked in the backlog register).

## Method

Assessed at tag `v0.6.10`, commit `5aa6f27` (working tree equals the tag). Framework: `/srv/projects/toolchain-development/TOOLCHAIN.md`, Dimension 4 detail ("the project meets its declared performance baseline ... under normal load") and the by-design prevention catalogue ("a benchmark regression beyond the threshold refuses the release for commercial regimes"). Prior review: `docs/review/2026-07-01-eight-dimension/dimension-4-performance.md` (v0.5.35), each finding re-verified against the current tree. Commands run:

- `perl tools/bench.pl --check` run to completion first, on a quiet machine, before the (contending) coverage gate.
- Read `tools/bench.pl`, `dist/config/bench-baseline.json`, `docs/architecture/performance.md`; grep of `tools/release.sh` for gate wiring and ordering; `docs/development.md` to confirm `release.sh` is the release path of record.
- SM140 recorder verification: read `_access_record` / `_access_conf` in `lazysite-processor.pl` (recording default-on, one conf read plus one `O_APPEND` write per request), confirmed the bench fixture has no `stats.conf` so the recorder runs inside every benched render iteration, and compared the baseline capture date (2026-07-02) against the recorder's landing (0.6.8, 2026-07-10) - the measured deltas therefore contain the recorder's full cost.
- 0.6.7 resilience verification: read `_tt_render` in `lazysite-processor.pl` (the retry-without-compile-cache path) and `t/integration/13-layout-compile-cache.t`.

## Findings

### F4.1 - Declared baseline met; gate passes (PASS)

`perl tools/bench.pl --check` at `5aa6f27` (exit 0):

```datatable
columns: Op | Measured | Baseline | Ratio | Gate limit (2x)
widths: 4.2cm | 2.2cm | 2.2cm | 1.8cm | X
bold: 1
tone: light
---
render_cache_hit_ms | 62.4 ms | 60.0 ms | 1.04 | 120.0 ms
render_miss_ms | 84.9 ms | 83.6 ms | 1.02 | 167.2 ms
verify_password_ms | 124.0 ms | 120.8 ms | 1.03 | 241.6 ms
verify_token_ms | 35.8 ms | 32.7 ms | 1.09 | 65.4 ms
```

Output: `perf: all ops within tolerance of baseline`. The stable relative figure the docs lean on - token verification roughly 3.5x cheaper than password verification - holds (35.8 vs 124.0 ms). The baseline was captured on 2026-07-02, before the whole 0.6.x feature line; every op still sitting within 9% of it is itself evidence that ten releases of feature work (notifications, SMTP validation, the capability migration, first-party analytics) have not degraded the hot paths.

### F4.2 - Gate wired into release.sh (FIXED, was WARN)

`tools/release.sh` now runs, in order: `prove -r` on the staged tree, `bench.pl --check` (refusing on regression - "benchmark regression; not releasing"), the instrumented `coverage.sh --check`, then the SBOM strictness gate. The bench gate is deliberately sequenced before the slow coverage gate, and `docs/development.md` confirms `release.sh` is the only way a tag is cut. The prior review's F4.3 (gate declared but unenforced) is closed: the Commercial by-design refusal is mechanical since 0.5.36.

### F4.3 - Baseline provenance and tolerance policy (FIXED, was WARN)

`dist/config/bench-baseline.json` now records `host` (ai-dev), `perl` (v5.40.1) and `captured_at` (2026-07-02T08:41:10Z), written automatically by `--baseline`; `--check` prints the provenance line and warns explicitly when the running host differs from the capturing host. The tolerance is tightened from 3x to 2x (the prior review's recommendation 6 asked for 1.5-2x), with a per-op `tolerances{op}` override mechanism in the JSON - currently unused, so all four ops gate at 2x. Measured spread on this host is a few per cent, so 2x is flake-free while refusing a genuine doubling. The prior F4.2 is closed; a further per-op tightening (for example 1.5x on the two render ops, whose spread is smallest) remains available but is no longer a conformance matter.

### F4.4 - Render op honesty (FIXED, was WARN)

The prior review demonstrated that the headline `render_ms` op timed the cache-hit path only. The op is now split: `render_cache_hit_ms` (renamed honestly - the path most visitors hit) and `render_miss_ms`, which deletes `index.html` before each iteration so all 20 timed iterations exercise the markdown + Template Toolkit pipeline and the cache write. The op table in `docs/architecture/performance.md` describes both accurately. The measured hit-vs-miss gap (62 vs 85 ms) also quantifies the cache's value per request - about 22 ms of render work saved on a simple page, on top of which the cache-hit path avoids loading the render-only modules.

### F4.5 - SM140 first-party recorder: the cost claim is substantiated (PASS)

`docs/feature-requests/SM140-first-party-analytics.md` claims the recorder costs "one syscall trio on top of a CGI process start - negligible (bench-gated)". Verified on three legs:

- **Mechanism.** `_access_record` in the processor does one `stats.conf` read plus one `sysopen`/`syswrite`/`close` in `O_APPEND` mode per request (lines are below `PIPE_BUF`, so concurrent appends cannot interleave); the retention prune runs only on the first write of a new day. Recording is wrapped in `eval` and fails silent-but-logged, so it can never break serving.
- **Bench-gated in fact, not just in intent.** Recording defaults on (`first_party => 1` absent a `stats.conf`), and the bench fixture site has no `stats.conf` - so every benched render iteration includes the recorder.
- **Measured.** The committed baseline predates the recorder (captured 2026-07-02; the recorder landed in 0.6.8 on 2026-07-10), so today's deltas contain its full cost: +4% on cache-hit (2.4 ms), +1.6% on miss (1.3 ms), inside normal run-to-run spread.

The claim holds, and any future regression in the recorder (say, an accidental per-request prune) lands inside a gated op.

### F4.6 - 0.6.7 TT compile-cache resilience: no performance cliff (PASS)

The 0.6.7 field fix (`_tt_render`) wraps every layout render in `eval` and, on any failure, retries once on a fresh Template instance with `COMPILE_DIR`/`COMPILE_EXT` removed. Cost analysis:

- **Happy path** - zero added cost: same instance, same options, the only addition is the `eval` frame. The benched ops confirm no regression.
- **Degraded path** (unwritable `lazysite/cache/tt`) - each layout render pays one failed attempt plus a full in-memory template compile per request, instead of taking the whole site down (TT 2.x) or 500ing (TT 3.x) as before. The cost is bounded, applies only to cache-miss and manager renders (the public cache-hit path serves `.html` without touching TT), is WARN-logged per request ("rendered without the TT compile cache") so it is observable, and `lazysite-check` gained a `cache/tt` writability probe with `--fix`. `t/integration/13-layout-compile-cache.t` pins all three behaviours.

A resilience change of this shape can silently institutionalise a slow path; here it cannot - the degraded mode is loud in the log and detected by the health checker.

### F4.7 - The unbenchmarked hot paths remain unbenchmarked (WARN, carried over)

The prior review's F4.5 stands in reduced form. The bench now covers the real render pipeline (closing the largest gap), but:

- **Manager-API endpoint latency** is still not benchmarked. The 0.5.24 lesson (a page quietly accumulating N cold-start CGI calls) has no gate; recommendation 4 of the prior review (a `users-page` round-trip op) was not implemented.
- **WebDAV throughput** is still not benchmarked - no PROPFIND depth-1 op, no PUT op - and `docs/architecture/performance.md` still carries its own open action: "Confirm the depth-1 cost against a large directory in the close-out report".
- **Scan-heavy render** (`scan:` pages, the aggregation path) is unbenchmarked; `render_miss_ms` uses a simple page.

None of these is tracked in `docs/feature-requests/BACKLOG.md`, so the open recommendations live only in the prior review document. Classification: WARN on breadth - the declared baseline is met and gated, but "normal load" for this product includes manager and DAV traffic that no op represents.

### F4.8 - Documentation currency (minor)

`docs/architecture/performance.md` is accurate on the gate, the op table, provenance and tolerance. The hand-measured table near the top (44/78/83 ms on an i7-1260P) is from a different host than the gated baseline and is clearly caveated as environment-dependent; acceptable, though a pointer to the gated numbers as the figures of record would prevent confusion.

## Prior findings - disposition

```datatable
columns: Prior finding (v0.5.35) | Disposition at v0.6.10
widths: 7cm | X
bold: 1
tone: light
---
F4.2 baseline provenance unrecorded; 3x tolerance | FIXED - host/perl/date recorded, host-mismatch warning, tolerance 2x with per-op overrides
F4.3 gate not wired into release.sh | FIXED - runs in release.sh before the coverage gate; regression refuses the release
F4.4 render_ms measured the cache-hit path | FIXED - split into render_cache_hit_ms + render_miss_ms; docs corrected
F4.5 manager-API, DAV, scan-heavy paths unbenchmarked | OPEN - render-miss gap closed; the rest remain, untracked in the backlog
```

## Recommendations

1. Add a manager-API op timing the `users-page` endpoint round-trip (the documented pre-0.5.24 worst case), pinning the one-call fix against regression - the prior review's recommendation 4, unchanged. Where: `tools/bench.pl` via the existing `open2` harness; re-capture the baseline. Effort: M. Satisfies: cold-start-times-call-count guarding (F4.7).
2. Add a DAV op: PROPFIND depth-1 against a generated directory of ~500 entries, and optionally a 1 MB PUT - closing the open question `performance.md` itself records. Effort: M. Satisfies: partner-path normal-load coverage (F4.7).
3. Record the two items above (and the scan-heavy render variant) in `docs/feature-requests/BACKLOG.md` so the residual bench-breadth work survives outside review documents. Effort: S. Satisfies: traceability of the open D4 work (F4.7).
4. Add a scan-heavy variant of `render_miss_ms` (an index page with `scan:` over ~50 generated pages, matching the hand-measured case in `performance.md`). Effort: S. Satisfies: the aggregation path joins the gate (F4.7).
5. When recommendation 1 or 2 next touches the baseline, consider per-op tolerances of 1.5x on the two render ops (measured spread is a few per cent) via the existing `tolerances` map. Effort: S. Satisfies: a tighter refusal on the paths that dominate visitor UX (F4.3).
