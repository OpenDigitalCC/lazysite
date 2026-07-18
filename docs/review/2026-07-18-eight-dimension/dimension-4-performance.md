---
title: "Dimension 4 - Performance - lazysite eight-dimension review"
subtitle: "v0.7.28 (6780878), 0.8.0-stable candidate, 2026-07-18, Commercial regime"
brand: plain
---

# Verdict

PASS - the declared baseline is met (all four ops within ~10% of the 2026-07-02
baseline, well inside the 2x gate tolerance), the gate is wired into
`tools/release.sh` before the slow coverage gate so a regression is unshippable,
and the two performance-relevant changes since 0.7.0 are both benign on the hot
path: the conf-mtime cache change adds exactly one `stat()` per request (a
correctness cost the render already pays for via `resolve_site_vars`), and the
new i18n / language-set code sits entirely on rare error/chrome and control-API
routes, lazy-loaded so it never enters the cache-hit serve. The residual is bench
breadth, carried from the prior review but now **tracked** in the backlog: the
manager-API, WebDAV and scan-heavy paths still have no benchmark op, and the
lang_status content-walk (a new O(files x roots) path) joins them as an
unbenchmarked - though rare and off-hot-path - addition.

# Method

Assessed at tag `v0.7.28`, commit `6780878` (working tree equals the tag).
Framework: `/srv/projects/toolchain-development/TOOLCHAIN.md`, Dimension 4 detail
("the project meets its declared performance baseline ... under normal load") and
the by-design prevention catalogue ("a benchmark regression beyond the threshold
refuses the release for commercial regimes"). Prior review:
`docs/review/2026-07-10-eight-dimension/dimension-4-performance.md` (v0.6.10,
PASS), each finding re-verified. Commands run:

- `perl tools/bench.pl --check` run to completion on this host.
- Read `tools/bench.pl`, `dist/config/bench-baseline.json`,
  `docs/architecture/performance.md`; grep of `tools/release.sh` for gate wiring
  and ordering.
- Read the conf-mtime cache path (`try_serve_cache`,
  `resolve_site_vars`, `lazysite-processor.pl:1060-1097` and `3247-3252`) to cost
  the added `stat()`.
- Traced the new i18n/lang call sites across the CGIs
  (`grep chrome_string / I18n / Lang / lang_status / DomainAccess`) to confirm
  they are off the hot path, and read `Lazysite::Lang::lang_status` for its
  algorithmic cost.

# Findings

## F4.1 - Declared baseline met; gate passes (PASS)

`perl tools/bench.pl --check` at `6780878` (exit 0):

```datatable
columns: Op | Measured | Baseline | Ratio | Gate limit (2x)
widths: 4.2cm | 2.2cm | 2.2cm | 1.8cm | X
bold: 1
tone: light
---
render_cache_hit_ms | 61.5 ms | 60.0 ms | 1.03 | 120.0 ms
render_miss_ms | 84.9 ms | 83.6 ms | 1.02 | 167.2 ms
verify_password_ms | 132.7 ms | 120.8 ms | 1.10 | 241.6 ms
verify_token_ms | 38.1 ms | 32.7 ms | 1.17 | 65.4 ms
```

Output: `perf: all ops within tolerance of baseline`. The baseline was captured
on 2026-07-02, before the entire 0.7.x line (multilingual, domain access, the
domains manager, the cache-correctness fix). Every op still sitting within ~17%
of it - and the two render ops within 3% - is itself evidence that the feature
line did not degrade the hot paths. `verify_token_ms` at 1.17x carries the
largest relative move but the smallest absolute op (38 ms), well inside
tolerance; the stable relative figure the docs lean on (token verification
~3.5x cheaper than password) holds (38.1 vs 132.7 ms). The host warning did not
fire, so this run is on the capturing host (ai-dev).

## F4.2 - Gate wired into release.sh, correctly ordered (PASS, carried FIXED)

`tools/release.sh` runs, in order: `prove -r` on the staged tree
(`:215`), `bench.pl --check` (`:225-226`), the instrumented `coverage.sh --check`
(`:238-239`), then the strict SBOM gate (`:263`). The bench gate is deliberately
sequenced before the ~15-minute coverage gate so a perf regression fails fast.
The Commercial by-design refusal ("a benchmark regression beyond the threshold
refuses the release") is mechanical and unchanged since 0.5.36.

## F4.3 - The conf-mtime cache change: one added stat(), off the critical cost (PASS)

The cache-correctness fix (F3.7 of the D3 review) makes a cached page depend on
`lazysite.conf`'s mtime, not only the `.md`'s. The performance question the brief
raises is the cost of the added `stat()`:

- **In `try_serve_cache`** (`lazysite-processor.pl:1072`): one
  `( stat $CONF_FILE )[9]` per cache-hit serve. This is a single `stat(2)` on a
  file whose inode is already hot (the same conf was read microseconds earlier by
  `resolve_site_vars` on the same request). At ~1-2 microseconds against a
  ~61 ms cache-hit render, the cost is ~0.003% - below measurement noise, and the
  benched `render_cache_hit_ms` (1.03x) confirms no regression.
- **In `resolve_site_vars`** (`:3247-3252`): the memoisation is keyed on
  `(conf mtime, request host)`, so it too `stat()`s the conf - but this replaces
  no cheaper prior behaviour and is what makes the resolver self-invalidating
  under FastCGI. The function already `read_file`d the conf on a cache miss; the
  added `stat()` on a hit is the price of correctness under a persistent worker,
  and it is one syscall, not a re-parse.

The change trades one `stat()` per request for cache correctness (no stale
Content-Language / chrome after a conf-only edit). That is the right trade and it
is invisible in the gated ops. No performance cliff.

## F4.4 - New i18n / language-set code is off the hot path (PASS)

The SM179 code paths are confirmed rare and, where they exist, lazy:

- **`Lazysite::I18n::chrome_string`** is invoked only for engine-emitted chrome:
  the processor's bare-404 fallback and auth reject pages
  (`lazysite-processor.pl:4959` via `_chrome`; `lazysite-auth.pl:1278-1302`). In
  the processor it is loaded with `require Lazysite::I18n` **only on first use**
  (`:1853-1862`) - so a normal render (cache hit or miss) never even loads the
  module, let alone reads an override file. The overlay JSON is memoised per
  `(docroot, lang)` (`I18n.pm:40-59`), so even a chrome-heavy error route reads
  the file at most once.
- **`Lazysite::Lang::lang_status`** is reached only from the manager control-API
  `lang_status` action (`lazysite-manager-api.pl:621,1805`) and `set_members`
  from the same file's whoami/nav path and `lazysite-mcp.pl:44` - all
  authenticated, low-frequency control routes, none on the public serve path.
- `_chrome_lang` (`:1844`) calls `resolve_site_vars`, which is memoised, so even
  the chrome path adds no extra conf read.

None of these appears in the four benched hot-path ops, and correctly so - they
are not "normal load" for a content site. One note for completeness (F4.6):
`lang_status` itself is not cheap in the abstract (it walks the source content
tree and hashes each file), but it runs only on operator/agent demand.

## F4.5 - Baseline provenance and tolerance policy still sound (PASS, carried)

`dist/config/bench-baseline.json` records `host` (ai-dev), `perl` (v5.40.1) and
`captured_at` (2026-07-02T08:41:10Z), and `--check` prints the provenance line
and warns on a host mismatch (`bench.pl:115-119`). Tolerance is 2x with a per-op
`tolerances{op}` override map (currently unused). The baseline is now ~16 days
and one minor feature-line old but every op sits within 17% of it, so it remains
a faithful reference; a re-capture is warranted when recommendation 1 or 2 next
adds an op (which forces a `--baseline` anyway).

## F4.6 - Unbenchmarked paths: prior three carried, lang_status added (WARN, tracked)

The prior review's F4.7 stands, and the multilingual work adds one path to the
same list:

- **Manager-API endpoint latency** - still unbenchmarked (no `users-page`
  round-trip op); the cold-start-times-call-count lesson (0.5.24) still has no
  gate.
- **WebDAV throughput** - still unbenchmarked (no PROPFIND depth-1, no PUT);
  `docs/architecture/performance.md:85-86` still carries its own open action to
  "confirm the depth-1 cost against a large directory in the close-out report" -
  unaddressed in this close-out.
- **Scan-heavy render** - still unbenchmarked; `render_miss_ms` uses a simple
  page.
- **NEW: `lang_status` content walk** - `Lazysite::Lang::lang_status`
  (`Lang.pm:143-197`) is O(source files x non-source roots), hashing every source
  file once (`_file_hash`) and `stat`ing each sibling. For a large translated site
  (hundreds of pages x several languages) this is a non-trivial control-API
  action with no benchmark and no declared bound. It is off the hot path (F4.4),
  so it is not a serve-latency risk, but it is unrepresented normal load for the
  manager surface on a large multilingual site.

**Improvement since the prior review**: these items are no longer untracked. The
three carried items are recorded in `docs/feature-requests/BACKLOG.md`
(line 171-172, item d: "bench breadth: manager-API users-page op, DAV
PROPFIND/PUT op, scan-heavy render variant (D4)"), closing the prior review's
complaint that the open D4 work lived only in a review document. `lang_status`
should join that item. Classification: WARN on breadth - the declared baseline is
met and gated, but "normal load" for this product now includes manager, DAV and
large-multilingual-site control traffic that no op represents.

## F4.7 - Documentation currency (minor)

`docs/architecture/performance.md` is accurate on the gate, the op table,
provenance and tolerance, but still carries the open action about the DAV depth-1
cost (`:85-86`) as an unresolved close-out item - it should either be discharged
(add the op, recommendation 2) or explicitly deferred with the backlog reference.
The hand-measured table remains clearly caveated as environment-dependent.

# Prior findings - disposition

```datatable
columns: Prior finding (v0.6.10) | Disposition at v0.7.28
widths: 7cm | X
bold: 1
tone: light
---
F4.7 manager-API / DAV / scan-heavy paths unbenchmarked, untracked | PARTIAL - still unbenchmarked, but now TRACKED in BACKLOG.md item (d); lang_status content walk added to the same class (F4.6)
F4.2/F4.3/F4.4 (gate wiring, provenance, render honesty) | STILL FIXED - re-verified at this tag; gate order and provenance intact (F4.2, F4.5)
```

# Recommendations

1. Add a manager-API op timing the `users-page` endpoint round-trip (the
   documented pre-0.5.24 worst case), via the existing `open2` harness in
   `tools/bench.pl`; re-capture the baseline. Where: `tools/bench.pl`,
   `dist/config/bench-baseline.json`. Effort: M. Satisfies:
   cold-start-times-call-count guarding (F4.6).
2. Add a DAV op (PROPFIND depth-1 against ~500 entries, optionally a 1 MB PUT),
   discharging the open action `performance.md:85-86` records. Where:
   `tools/bench.pl`. Effort: M. Satisfies: partner-path normal-load coverage and
   the outstanding perf-doc action (F4.6, F4.7).
3. Add `lang_status` to the tracked bench-breadth backlog item and add a
   `render_miss_ms` scan-heavy variant; consider a `lang_status` op against a
   generated multilingual fixture (source pages x N roots) so the O(files x roots)
   walk gets a bound. Where: `docs/feature-requests/BACKLOG.md`, `tools/bench.pl`.
   Effort: S (backlog) / M (op). Satisfies: the multilingual control path joins
   the gate (F4.6).
4. When recommendation 1 or 2 next re-captures the baseline, consider per-op
   tolerances of 1.5x on the two render ops (measured spread a few per cent) via
   the existing `tolerances` map, tightening the refusal on the paths that
   dominate visitor UX. Where: `dist/config/bench-baseline.json`. Effort: S.
   Satisfies: a tighter refusal on the hot paths (F4.1).
