---
id: SM685
title: Token verification has drifted half again slower, and the gate cannot fail on it
raised: 2026-08-29
raised-by: engine agent
area: performance
status: partial
status-note: "SCHEDULED 2026-09-09 for 0.13.10 by the release manager, and MEASURED the same day - see below: roughly 80% of a token verification is compiling the 3,289-line users tool in a fresh process, so there is nothing to optimise inside it and the fix is to stop compiling it. Previously: OPEN. `verify_token_ms` measured 62.7ms against a 42.1ms baseline at the 0.11.5 cut - 1.49x, beyond the 1.25 tolerance - and `verify_password_ms` 1.18x on the same run. Neither fails the build: bench reports timings and gates on WORK COUNTERS, all five of which passed. So the slowdown is real, visible on every cut, and structurally unable to stop one. Token verification is on the path of every control-API and MCP call, so this is the hot path for exactly the agent traffic the platform is built around."
---


# MEASURED 2026-09-09, and the cause is not a slow path

Open since 2026-08-29 and reported on every cut without anyone taking it apart.
Two numbers, taken on an idle box:

    20 compiles of tools/lazysite-users.pl   1.0 s      ~50 ms each
    verify_token_ms                          ~62 ms

**So roughly 80% of a token verification is compiling a 3,289-line
user-management tool**, in a fresh `perl` process, to answer one question. The
verification itself is around 12 ms.

That reframes the whole filing. This is not a slow algorithm and there is
nothing to optimise inside it: `verify_token_ms` is a *file size* measurement
wearing a stopwatch. It also explains the drift exactly - the 42.1 baseline was
captured when the file was smaller, and every line added since has been paid on
every authenticated request. SM800 added eight and the bench refused the
release, which was the counter doing precisely its job.

# What fixing it means

The callers are `lazysite-auth.pl`, `lazysite-manager-api.pl` and
`lazysite-mcp.pl`, each shelling out to `lazysite-users.pl --api
verify-credential`. **The subprocess is not needed for privilege reasons on
that path**: the tool's `drop_to_tree_owner` exists so a CLI run as root cannot
write a root-owned tree, and the CGI callers already run as the site user.

So the fix is to stop compiling the tool to answer this:

1. **Move credential verification into a small module** the three callers
   `use` directly - the store readers it needs are already in
   `Lazysite::Auth::Settings`. No process, no compile, and `verify_token_ms`
   becomes a measurement of the verification rather than of the file.
2. **The tool keeps its `--api verify-credential`**, calling the same module,
   so the CLI and anything shelling out are unaffected.
3. **`work_users_tool_statements` stops being a proxy for request cost** once
   the tool is off the request path - it stays useful as a guard on the tool
   itself, but the thing it was standing in for is gone.

Half a day, and it is a refactor of a security-critical path, so it wants the
whole suite and a bench before and after rather than a quick landing.

# Why it has not been done

It has never been scheduled, and each release has had something more urgent.
Worth stating plainly: it is not urgent, nothing is failing, and it is getting
slowly worse - 32.7 ms at the original baseline, 42.1 at the current one, ~62
now. The bench reports it on every cut and cannot fail a build on it, which is
the arrangement that lets it persist.

# What was measured

At the 0.11.5 cut (`6c39ba79`, 2026-08-28, idle-ish host):

| Timing | Now | Baseline | Ratio |
| --- | --- | --- | --- |
| `verify_token_ms` | 62.7 ms | 42.1 ms | **1.49x** |
| `verify_password_ms` | 153.2 ms | 130.1 ms | 1.18x |

Baseline captured 2026-08-26 on the same machine, same perl (v5.40.1). The
tolerance is 1.25, so token verification is comfortably beyond it and password
verification is heading the same way.

This is not a one-off reading. An earlier session in this line measured the same
drift (50ms to 58ms), attributed it to machine load, re-measured on an idle host
and found it reproduced, then bisected it to **accretion across ten commits**
rather than any single change. It has since got worse, not better.

# Why the gate cannot catch it

`bench.pl --check` reports timings and gates on work counters (SM342, SM663).
That is the right design - wall-clock on a shared build host is noise, and a
timing gate would fail builds for reasons that have nothing to do with the code.
The work counters are the instrument that can fail.

The consequence is that a genuine, compounding slowdown produces a line of
output at every cut that nobody is obliged to act on. Ten commits each adding
four percent is invisible to a per-commit check and invisible to a work-counter
check, because none of them changes the amount of work in a way the counters
count - they change how long the same work takes.

# Why it matters more than the number suggests

`verify_token` is on the path of **every** control-API request and every MCP
tool call. It is not a page-render cost paid once; it is paid per call, by the
agent traffic this platform exists to serve. A partner running a discovery sweep
of a few hundred calls pays the regression a few hundred times.

# What it needs

1. **Find where the time went.** The bisect said accretion, not a single commit,
   which means profiling `verify_token` directly rather than diffing commits.
   The likely candidates are work that was added to the verify path for
   correctness - capability resolution, scope derivation, plugin state - each
   defensible alone.
2. **Decide what the counters should count.** If the added work is real work,
   a work counter that captures it would make the next such drift fail the gate
   instead of printing a line. That is the durable fix: the reason this was
   invisible is that the instrument does not measure the thing that grew.
3. **Consider a ratcheting baseline.** A baseline refreshed at each cut hides
   accretion by construction, because every release becomes the new normal. If
   the baseline is refreshed, the ratio against a FIXED older baseline should be
   reported alongside it.

# What this is not

Not a proposal to gate on wall-clock. That was settled and settled correctly.
The ask is that a compounding regression on the hottest path in the system
should be able to fail something, and today it cannot.

# Related

[[SM342]] (why timings report rather than gate), [[SM663]] (the work counter as
the real instrument - filed after I claimed bench fails at 2x, which it does
not), [[SM662]] (the capability gate fingerprint, which is some of the work now
on this path).

# Not started
