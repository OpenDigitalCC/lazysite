# Dimension 4 - Performance - lazysite eight-dimension review

- Audited tree: `main` at `v0.10.8` (`ec6fe0a`)
- Date: 2026-08-14
- Regime: Commercial
- Prior verdict: PASS (2026-07-18)

## Verdict

**WARN**. The benchmark gate exists, is committed, is host-relative with
recorded provenance, and runs in the release gate - which is more than most
projects of this size have. But it has stopped tracking the system it measures:
the baseline is six weeks and two minor lines old (F4.1), and the one
structural change in this period that moved work onto the request path - the
registries becoming generated-on-request - has no benchmark op at all (F4.2).

Combined with a 2x tolerance, the gate would currently pass a system that had
become 90% slower on every measured path while saying nothing about the paths
it does not measure.

## Method

- Read `dist/config/bench-baseline.json` and `tools/bench.pl`'s gate logic.
- Compared the four benchmarked ops against the request paths the 0.10.x work
  created or changed.
- Ran `tools/bench.pl --check` on the audited tree.

## Findings

### F4.1 - The baseline predates two minor lines (WARN)

```json
"captured_at" : "2026-07-02T08:41:10Z",
"host" : "ai-dev",
"tolerance" : 2
```

Captured 2026-07-02, before the 0.9.x line and the whole of 0.10.x. The design
is deliberately host-relative and expects re-capture on the CI/deploy host, so a
stale date is not automatically wrong - but a baseline that predates the work it
is gating cannot detect a regression introduced by that work. It can only detect
a regression introduced *after the next re-capture*.

The 2x tolerance compounds this. `tools/bench.pl`'s own comment records that
"measured spread on a quiet host is ~3 per cent", which means the gate is set
roughly 60 standard deviations wide. That is a sensible guard against host
variance and a poor guard against gradual drift: six 12% regressions in a row
pass every time, and the seventh is compared against a baseline nobody has
re-captured.

Recommendation: re-capture at each stable cut (it is one command), and consider
a second, tighter tolerance that warns rather than fails - so drift is visible
without making the gate flaky.

### F4.2 - The registries moved onto the request path and are not benchmarked (WARN)

SM293 step 3 stopped writing `sitemap.xml`, `llms.txt`, `robots.txt`,
`feed.rss` and `feed.atom` to disk. They are now generated on request and
cached. This was a deliberate and well-argued decision - it removes a class of
staleness bug and keeps a high-demand file off disk - and the user explicitly
accepted mild staleness in exchange.

But it moves a **full content walk** onto a request path that previously served
a static file, and none of the four benchmarked ops covers it:

| Op | Path |
|---|---|
| `render_cache_hit_ms` | a cached page |
| `render_miss_ms` | a full page render |
| `verify_token_ms` | token credential verification |
| `verify_password_ms` | password verification |

The cost is bounded by the cache, so the steady state is fine. The uncached case
is a site-wide scan triggered by an anonymous, unauthenticated request for a
well-known URL - which is also the request a crawler makes, and the one an
attacker would repeat after a cache invalidation. Nothing here says it is slow;
the point is that nobody has measured it, on the release where it changed.

The July review left "`lang_status`'s content walk unbenchmarked" as a deferred
D3/D4 item. That is still open, and this is the same shape: content walks are
the project's characteristic scaling risk and are the thing the bench does not
cover.

### F4.3 - The measured baseline documentation is honest about what is stable (PASS, noted)

`docs/architecture/performance.md` states its absolute numbers are
environment-dependent and names the *relative* figures as the ones to compare
across environments (cache-hit vs miss overhead, scan scaling, the token-vs-
password gap). That is the right way to publish a benchmark and it is followed
consistently.

The module-loading analysis is likewise candid: ~50 ms of the ~58 ms the
processor takes to print anything is module loading, and the cache-hit path does
4-8 ms of real work on top of that floor. Naming the floor is what makes the
FastCGI work's value legible.

### F4.4 - The pending SM294 work measures itself properly (noted, not in the audited tree)

Recorded because it is the pattern the recommendations ask for. The pooled front
door on `claude/sm294-front-door-under-the-pool` was measured like-for-like -
the same URL and the same authentication state in both configurations - giving
71.9 ms to 0.53 ms on an anonymous page and 107.3 ms to 96.9 ms on a signed-in
one, with the reproduction script committed alongside.

The methodological note matters more than the numbers: the first version of that
comparison measured a cached anonymous hit against a signed-in miss and appeared
to show a 34% regression that did not exist. A benchmark comparing two different
requests is worse than no benchmark, because it produces a number.

## Evidence

- `dist/config/bench-baseline.json` - capture date, host, tolerance.
- `tools/bench.pl:6-8`, `:114-124` - the gate and its tolerance logic.
- `docs/architecture/performance.md:33-75`.
- `lib/Lazysite/FrontDoor.pm:45` - the retired registry routes.
