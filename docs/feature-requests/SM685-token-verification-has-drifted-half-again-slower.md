---
id: SM685
title: Token verification has drifted half again slower, and the gate cannot fail on it
raised: 2026-08-29
raised-by: engine agent
area: performance
status: shipped
status-note: "BUILT 2026-09-09 on claude/sm685-verify-without-the-subprocess: verification moved into Lazysite::Auth::Verify and the three CGI callers use it directly, so an authenticated request no longer compiles the users tool. verify_token_ms 62.6ms -> 0.6ms; the CLI path is kept visible as verify_token_cli_ms. The port was proven against the pre-refactor implementation (all 49 settings keys identical) rather than against the permanent test, which cannot show it - see the filing. ONE OPEN DECISION: the group-seeding trigger no longer fires on login, which narrows SM645 healing; it is in docs/decision-register.md. Previously SCHEDULED 2026-09-09 for 0.13.10 by the release manager, and MEASURED the same day - see below: roughly 80% of a token verification is compiling the 3,289-line users tool in a fresh process, so there is nothing to optimise inside it and the fix is to stop compiling it. Previously: OPEN. `verify_token_ms` measured 62.7ms against a 42.1ms baseline at the 0.11.5 cut - 1.49x, beyond the 1.25 tolerance - and `verify_password_ms` 1.18x on the same run. Neither fails the build: bench reports timings and gates on WORK COUNTERS, all five of which passed. So the slowdown is real, visible on every cut, and structurally unable to stop one. Token verification is on the path of every control-API and MCP call, so this is the hot path for exactly the agent traffic the platform is built around."
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

# BUILT 2026-09-09 on `claude/sm685-verify-without-the-subprocess`

All three recommendations above, as written.

`Lazysite::Auth::Verify` now holds the credential path - `read_users`,
`read_groups`, `effective_settings` and `verify_credential` - and
`lazysite-auth.pl`, `lazysite-manager-api.pl` and `lazysite-mcp.pl` call it
directly. The tool keeps `--api verify-credential` and delegates to the same
module, so there is one implementation rather than two that must be kept in
step.

## What it measures now

| Gauge | Before | After |
| --- | --- | --- |
| `verify_token_ms` | 62.6 ms | **0.6 ms** |
| `verify_token_cli_ms` (new) | - | 65.4 ms |
| `verify_password_ms` | 130.1 ms baseline | 93.1 ms |
| `work_users_tool_statements` | 3,289 | 3,204 |

`verify_token_ms` now times the path a REQUEST takes, which is the question the
gauge was always asking; the CLI's cost is kept under its own name because an
operator's every command still pays it. The 42.1 ms baseline it is compared
against is a historical subprocess figure, so the 0.01x is a mechanism change
rather than a like-for-like win - re-capturing the baseline at the next release
would make the series honest. `verify_password_ms` did not fall to nothing
because it is PBKDF2 doing real work, which is the point of it.

`work_users_tool_statements` keeps its value as a guard on the tool, but it is
no longer a proxy for request cost - the third recommendation, and worth
remembering the next time it refuses a release.

## That the answer did not change

A refactor of a security-critical path is only safe if the new answer is the
old answer, and the obvious test does not show that: the tool delegates to the
module, so both surfaces share one implementation and a corrupted value breaks
them together. The first draft of `t/unit/users/45` was written as an
equivalence proof and **passed with a deliberately wrong field**, which is how
the flaw in it was found.

The port was proven instead against the implementation as it stood before the
refactor, recovered from git and run beside the new one over a single store:
**all 49 settings keys identical**, capability map included. That check is a
one-off by nature and is not kept as a test. What `t/unit/users/45` does guard
is written into its own header, honestly: that verification works through the
module, that the first-use mark is consumed once, that the refusals behave, and
that the CLI surface still agrees - so a later re-implementation in the tool
diverges and fails there.

## One thing did change, and it is a decision, not a defect

`_ensure_groups_seeded` did NOT move into the module. Group seeding and
migration is a mutation - SM645 tops up manager groups and can write
group-settings - and it does not belong on the hottest read path in the system.
The tool still calls it before delegating, so every path through the tool heals
exactly as before.

But SM645 deliberately put that trigger on ordinary use so an upgraded site
adopted a release "the next time anybody touches it", and a login is the
commonest touch there is. Taking verification off the subprocess narrows that:
a site whose manager UI is ever opened still heals (group-add, setup-sysop, the
permissions grid, the capability-holders report, the tool's own group reads), a
site that is only ever logged into no longer does.

Two defensible shapes - heal behind a once-per-release stamp, or accept the
narrower trigger - so it is in `docs/decision-register.md` for the release
manager rather than settled inside a performance change.

## The fork bomb, and where the rule had to live

Between the first build and the green suite this change **took the host out** -
around a hundred `lazysite-users.pl` processes, spawning and respawning until
there was nothing left. It is worth writing down because the fault was in the
reasoning, not the typing, and the reasoning was good enough to survive review.

The tests stub credential verification by pointing `LAZYSITE_USERS_TOOL` at a
fake users tool. Moving verification in-process bypassed that seam, so
thirty-three files failed. The fix looked obvious and was defensible on its own
merits: **a deployment that nominates a users tool has nominated the authority
on credentials, so ask it** - an operator who redirects that variable and finds
credential checks quietly reading a different store has a real bug. So the
module honoured it.

The module is also loaded INSIDE the tool. `cmd_verify_credential` calls
straight into it; the child inherits the variable that named it; it reads the
variable and spawns the tool again. Each hop is a fresh interpreter, so nothing
overflows a stack and nothing raises deep recursion - it forks until the host is
gone. It stayed hidden through the MCP tests because those point the variable at
a *stub*, which answers and exits. It fires from
`t/unit/manager/112`, `114` and `t/integration/18`, which point it at the real
tool - and those only run in the full suite.

**The rule is sound; it was in the wrong place.** The three callers now decide
whether to shell out, because they are the only code that can make that choice
without being able to ask itself, and the module verifies and never spawns.
`t/unit/users/45` asserts that by shape - no `open2`, `system`, `exec`, `qx`,
backticks or `fork` anywhere in it, and no read of the variable that names the
tool it lives inside - so a future edit that reintroduces the delegation one
layer too low fails there rather than on the host. The assertion was checked by
putting the read back and watching it fail.

Two things generalise. A recursion whose every hop is a PROCESS has none of the
signals recursion normally gives you. And a seam that exists only in tests -
here, a stubbed subprocess boundary - hides the difference between what the
tests exercise and what production runs, which is what made the wrong fix look
like the right one.

## Ruled 2026-09-09 by the release manager

**The narrower healing trigger is accepted.** Group seeding stays in the tool
and does not run on the credential path. The reasoning that settles it: the
manager-group top-up is only NEEDED when an operator goes to grant a capability,
and going there is itself a trigger - so the narrowing is self-correcting for
the case it matters in. A site that is only ever logged into does not heal, and
an absent group-settings store now resolves to zero capabilities where it used
to be recreated in passing; both are accepted, and both are written here rather
than left to be rediscovered.
