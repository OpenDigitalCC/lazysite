---
title: "Dimension 4 - Performance - lazysite eight-dimension review"
subtitle: "v0.5.35 (de12238), 2026-07-01, Commercial regime"
brand: plain
---

## Verdict

WARN - the declared benchmark gate runs and passes (all three ops within 3x of baseline, 5 seconds wall), but it is not wired into `tools/release.sh`, the 3x tolerance only refuses catastrophic regressions, and the headline `render_ms` op demonstrably times the cache-hit path rather than the render pipeline - leaving the paths that dominate real user experience on plain-CGI hosts (cold-start multiplied by call count, cache-miss render, DAV throughput) unguarded.

## Method

Assessed at tag `v0.5.35`, commit `de12238`. Framework: `/srv/projects/toolchain-development/TOOLCHAIN.md`, Dimension 4 detail ("the project meets its declared performance baseline ... under normal load"; waivable with a recorded reason) and the by-design prevention catalogue ("a benchmark regression beyond the threshold refuses the release for commercial regimes"). Commands run:

- Read `tools/bench.pl`, `dist/config/bench-baseline.json`, `docs/architecture/performance.md`; `git log --follow` on the baseline file; grep of `tools/release.sh` for gate wiring.
- `perl tools/bench.pl --check` run to completion (after the test suite had finished, to avoid load interference).
- Two scripted probes reproducing `bench.pl`'s render fixture: one confirming the first render writes `index.html`, and a sentinel test (overwrite the cache file, re-invoke the processor, observe the sentinel returned verbatim) proving subsequent invocations serve the cache.

## Findings

### F4.1 - Declared baseline exists and the gate passes (PASS)

`perl tools/bench.pl --check` at `de12238` (5.2 s wall, exit 0):

```datatable
columns: Op | Measured | Baseline | Ratio | Gate limit (3x)
widths: 4.2cm | 2.2cm | 2.2cm | 1.8cm | X
bold: 1
tone: light
---
render_ms | 62.4 ms | 65.1 ms | 0.96 | 195.3 ms
verify_password_ms | 125.7 ms | 132.3 ms | 0.95 | 396.9 ms
verify_token_ms | 34.6 ms | 32.7 ms | 1.06 | 98.1 ms
```

Output: `perf: all ops within 3x of baseline`. The declared baseline is met; no waiver is recorded or needed (the Commercial regime warrants the dimension). The stable relative figure the docs lean on - token verification roughly 4x cheaper than password verification - holds (34.6 vs 125.7 ms).

### F4.2 - Baseline quality: host-pinned in spirit, unrecorded in practice (WARN)

`dist/config/bench-baseline.json` documents itself as host-relative ("re-capture on the CI/deploy host") but records neither the host, the perl version, nor the capture date. `git log --follow` shows exactly one commit ever: `b5a259d` (2026-06-24, conformance WP-3). Today's measurements sit within 6% of the baseline, which strongly suggests the same host - but that is inference, not a record. If a release were ever cut from a different host, a pass or fail against these numbers would be meaningless and nothing in the file would say so.

The 3x tolerance is deliberately gross to absorb host variance, and it does make the gate flake-free - but it also means `render_ms` can reach 195 ms (a 3x user-visible slowdown) before anything refuses. For a Commercial regime whose by-design rule is "a benchmark regression beyond the threshold refuses the release", the threshold exists, so this conforms mechanically - it just guards only against catastrophe. Classification: WARN.

### F4.3 - Gate not wired into release.sh (WARN)

`tools/release.sh` runs `prove` and the SBOM strictness gate only; `bench.pl --check` appears nowhere in it, in the `Makefile`, or in any hook. The gate costs 5 seconds - there is no runtime justification for its absence. The last recorded run is the 0.4.0 QC close-out (CHANGELOG, 2026-06-24): "`tools/bench.pl --check` ... floors hold" - roughly 35 edge releases ago. Classification: WARN - the Commercial by-design refusal is declared but not enforced.

### F4.4 - render_ms measures the cache-hit path, not the render pipeline (WARN)

`bench.pl` builds a tempdir site, then times `qx($^X lazysite-processor.pl)` for `/index` - after two warm-up iterations. Probes confirmed: the first invocation writes `index.html` next to `index.md`, and a sentinel planted in that file is returned verbatim by the next invocation ("second invocation SERVED THE CACHE"). So the warm-ups populate the cache and all 20 timed iterations exercise perl start-up plus the cache-hit serve - the markdown parse, TT render and cache-write pipeline is executed exactly twice, unmeasured, during warm-up.

Consequences: no gate covers a regression in the render pipeline itself (the code most feature work touches), and the op description in `docs/architecture/performance.md` ("a processor render of a simple page") is inaccurate. The number is still useful - it pins the cold-start floor plus cache-hit serve, which is the most common visitor path - but it is not what it claims to be. Classification: WARN.

### F4.5 - The costs that dominate real UX are unbenchmarked (WARN)

On a plain-CGI host every request pays a fresh perl start (~50 ms module-load floor per `docs/architecture/performance.md`), so real page latency is cold-start multiplied by the number of CGI calls a page makes. The project has already been bitten by exactly this class: the 0.5.24 fix (`a8154c0`, "faster Users page") collapsed three manager CGI calls - one of which spawned two further subprocesses - into a single `users-page` endpoint because per-call cold start dominated the page. Nothing benchmarks manager-API endpoint latency or pins per-page call counts, so a regression of that class (a page quietly growing back to N calls) is invisible to every gate.

Also unbenchmarked:

- The cache-miss render path (see F4.4) and its scaling on `scan:`-heavy pages.
- WebDAV throughput: PROPFIND depth-1 cost on a large directory - `docs/architecture/performance.md` itself says "Confirm the depth-1 cost against a large directory in the close-out report", still open - and PUT streaming, the partner-publishing hot path.

Classification: WARN - the declared baseline covers three ops; the framework asks that the baseline reflect "throughput, latency, resource usage under normal load", and normal load for this product is cold-start-bound CGI and DAV traffic.

## Recommendations

1. Wire `perl tools/bench.pl --check` into `tools/release.sh` beside the `prove` step (it adds 5 seconds). Where: `tools/release.sh`, staged tree. Effort: S. Satisfies: the Commercial by-design performance refusal (F4.3).
2. Split the render op: keep `render_cache_hit_ms` (the current behaviour, renamed honestly) and add `render_miss_ms` that deletes `index.html` (or touches `index.md`) before each iteration, then re-capture the baseline and correct the op table in `docs/architecture/performance.md`. Where: `tools/bench.pl`, `dist/config/bench-baseline.json`, the docs. Effort: S. Satisfies: a gate over the actual render pipeline (F4.4).
3. Record provenance in the baseline: host identifier, perl version and capture date written by `--baseline` into the JSON, and printed by `--check` so a cross-host comparison is visible when it happens. Effort: S. Satisfies: baseline meaningfulness (F4.2).
4. Add a manager-API op timing the `users-page` endpoint round-trip (the documented worst case before 0.5.24), pinning the one-call fix against regression. Where: `tools/bench.pl` via the existing subprocess harness. Effort: M. Satisfies: cold-start-times-call-count guarding (F4.5).
5. Add a DAV op: PROPFIND depth-1 against a generated directory of, say, 500 entries - closing the open question `performance.md` itself records - and optionally a 1 MB PUT. Effort: M. Satisfies: partner-path normal-load coverage (F4.5).
6. Once the gate runs on a pinned release host (recommendation 1 plus 3), tighten the tolerance per-op - for example 1.5-2x using the median of three `--check` runs - so the gate refuses meaningful regressions, not only catastrophes. Effort: S. Satisfies: a threshold that actually protects UX (F4.2).
