# Dimension 1 - Correctness and groundedness - the daemon service, pre-0.13.1

- Audited artefact: `main` at `53df9a44`, in a clean worktree, after the five
  0.13.1 Tier 1/2 branches landed
- Date: 2026-09-05
- Regime: Commercial
- Scope: `lib/Lazysite/Daemon/**`, `lib/Lazysite/Lifecycle.pm`,
  `tools/lazysited.pl`, `plugins/daemon.pl`, `debian/lazysited@.service`,
  `lazysite-hestia-domain add --daemon`, `Lazysite::Manager::Sessions::sweep_expired`
- Prior verdict: none - first review of this service

## Verdict

**REFUSE** at the audited commit; **cleared on `claude/sm755-supervisor-restart-path`**
(F1.1, F1.2, F1.3 fixed with reproductions as tests; F1.4 carried). The supervisor's restart path - the one property the plugin
description promises ("a service that keeps dying is reported as FAILED rather
than restarted forever") - does the opposite, and no test executes it. Everything
else in scope is sound; the two lesser findings are a dead branch with a
misleading message and a divergent config parser.

## Method

`perl -c` on every file in scope (all pass). perlcritic at the project profile
(severity 3): all clean. Then a structured read against the framework's
failure-mode catalogue, with the two experiments below run to settle what reading
could only suspect. The reviewer wrote most of this code in the preceding two
days, which is a reason to read it adversarially rather than a reason to trust
it.

## Findings

### F1.1 - A crashing service is restarted forever, uncounted, and reported healthy (REFUSE)

`Supervisor::run` counts a failure only in the branch where the supervisor
notices the child gone *before* reaping it:

```perl
next if $child{$name} && _alive( $child{$name} );   # zombie: kill 0 succeeds
if ( $child{$name} ) { $fails{$name}++; ... }        # only if not yet reaped
...
while ( ( my $gone = waitpid( -1, WNOHANG ) ) > 0 ) {
    delete $child{$n} if $child{$n} == $gone;         # reaped: forgotten
}
```

The order of events for a child that exits is: it becomes a zombie; on the next
loop `_alive` (`kill 0`) **succeeds on a zombie**, so the service is treated as
running; the reap loop then deletes it from `%child`; on the following loop
`$child{$name}` is absent, so `$fails` is never incremented, no `service exited`
WARN is written, the backoff is never applied (`$next_try` is set only when
`fork` itself fails), the ceiling is unreachable, and `_spawn` runs again.

**Measured** (`tmp/review-0131/crashloop.pl`: a service that `_exit(1)`s at
once, `daemon_restart_backoff: 2`, 12 seconds):

```
status while running: verdict=on service=on
'service started' lines: 7
'service exited' lines:  0
```

Documented behaviour would have been: exits counted, waits of 2, 4, 8 s, FAILED
after the seventh. Actual: a restart every ~2 s indefinitely, `status()`
reporting `on` whenever the zombie exists, and nothing in the log to say so. On
a host with hundreds of instances this is also a fork every two seconds per
misconfigured site.

Catalogue: `plausible-but-wrong` (the reap loop and the failure count were
written as if the same event would reach both), compounded by `invalid-test` by
omission - `t/unit/daemon/` never runs `Supervisor::run` with the plugin enabled
(D3 measures Supervisor at 45.7% statement coverage; lines 300-321, 337-359 and
377 are the loop, spawn and stop, all at zero).

**Remedy.** Treat the reap as the exit event: when `waitpid` returns a pid in
`%child`, increment `$fails`, log the WARN with the exit status, set `$next_try`
from the backoff. Make `_alive` reap-aware for the supervisor's own children
(`waitpid($pid, WNOHANG)` before `kill 0`). Add `t/unit/daemon/06` with a dying
service asserting counted exits, growing waits, FAILED at the ceiling, and
`status()` saying `failed`. Build-side; fix branch named in the overview.

### F1.2 - `should_run` is consulted once; disabling the plugin does not stop a running daemon (WARN)

The gate is checked at the top of `run()` and never again. The unit file and the
Hestia README both say "both switches must be on for anything to run"; after
start, only the host's switch matters until the next restart. ADR 0009's
"disabled means off" is honoured at start and not thereafter. This is
`architectural-drift` against the runtime's own stated contract, small in blast
radius (a sysop who disables the plugin and sees jobs continue until an operator
restarts the unit) and cheap to fix: re-evaluate `should_run` each loop and, when
it flips off, stop the children and exit 0 - which is the exit code the unit
already treats as "disabled, do not restart".

D5's experiment 7 measures the current behaviour.

### F1.3 - The "account does not exist" branch is dead, and a typo is reported as a missing grant (WARN)

`Scheduler::resolve_job_user` refuses `unless ref $caps eq 'HASH'` with "does
not exist or holds no capabilities". `caps_for` always returns a hashref (every
`@CAP_KEYS` key, 0 or 1), so the branch never fires and a mistyped
`daemon_job_user` is refused as "does not hold run_jobs". True, and the wrong
reason: the remedy for a typo is not "grant run_jobs". This is the refusal-clarity
class (SM750) inside the new service. `Auth::Settings::account_names()` exists
for exactly this question. Note that a fix obliges the fixtures to create the
account as well as the grant.

### F1.4 - The daemon reads its own config file with a fourth `key: value` parser (WARN, low)

`Supervisor::conf_value` is a first-match line scan; the Plugin Manager page
that WRITES `lazysite/daemon.conf` reads it back through
`Manager::Plugins::_read_kv_lines`, a last-match map with trim semantics. They
agree on well-formed files and disagree on a duplicated key. Catalogue:
`divergent-implementation`. Export the manager's reader (or a
`plugin_conf($docroot, $file)` over it) and have the daemon use it.

### F1.5 - What holds (PASS)

- **Disabled means no process.** `run()` returns 0 before creating the state
  dir; `t/unit/daemon/01` asserts the directory is absent; `t/unit/daemon/03`
  proves the unit's `Restart=on-failure` reasoning against a real `lazysited.pl`
  exit.
- **The identity gate fails closed in every direction** - no account, `system:`
  by name, missing `run_jobs`, missing per-job capability - and a refusal does
  not consume the schedule slot (`t/unit/daemon/02`, `05`).
- **`needs` is read from the manager API's own gate table** by the test, so a
  job cannot drift to needing less than the manager charges for the same work.
- **The stats rollup runs the real plugin** under the job and closes yesterday
  unread - SM343's failure made impossible by construction, asserted on the
  durable file, not on the log.
- **The sessions sweep applies the reader's rule**, byte-for-byte on the kept
  row; the test caught `my ( @keep, $removed ) = ( (), 0 )` slurping into the
  array before it shipped.
- **The lifecycle contract** derives the verdict in one place; `healthy` carries
  no remedy, unhealthy always does (`t/unit/lib/50`).
- **The Hestia flag** writes exactly the keys the unit reads (`t/tools/66`
  checks both directions) and the package creates the directory.
- **Privilege drop** follows `lazysite-pool.pl` exactly: groups first, then
  `setuid`, then a check that both real and effective uid left 0; refuses to run
  as root without `--user`. Exercised only in the unprivileged branch (D3, D5).

## Recommendations, by impact

1. Fix F1.1 with the reproduction as the test, before the cut. It is the one
   finding that would embarrass the service on its first real host.
2. F1.2 in the same branch: one `should_run` call per loop and a clean exit.
3. F1.3: `account_names()` check ahead of `caps_for`, with the fixtures given a
   `users` line.
4. F1.4: share the reader. Can follow the cut.
