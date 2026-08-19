---
title: "SM379: the deploy watcher exits after a deploy, and does it with the success code"
subtitle: "`set -e` is a shell option, not a function-local one. deploy() re-enabled it before returning the updater's status, so the caller's `set +e` was undone from underneath it and returning 2 - which means the rollout SUCCEEDED - killed the watcher."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-08-19. deploy() and its caller no longer toggle -e at all; `|| rc=$?` never trips it, so there is no option to leave in the wrong state. MEASURED both ways against the real function with the transport stubbed: original survives only a perfectly clean deploy (exits on 2 and on 9), fixed survives all three. This is why 0.10.14 sat in dist unnoticed - 0.10.13's deploy ended 'ROLLOUT SUCCEEDED, FLEET HAS FINDINGS', which is status 2, so the watcher died on a success. The earlier baseline-swallow hypothesis was wrong and is retracted."
---

# The mechanism

`deploy()` ended:

```bash
set +e
ssh "$HOST" "... lazysite-hestia-update-all.sh ..."
rc=$?
set -e
return "$rc"
```

`set -e` is a **shell** option. That final `set -e` takes effect
immediately, so the function returned a non-zero status with `-e` freshly
re-enabled - and the caller's own `set +e`, taken specifically to make
this call safe, had already been undone from underneath it. The failing
command was then the *call* to `deploy`, and the watcher exited.

::: widebox
**It exited with the updater's own status, which is what made it
invisible.** Status 2 is [[SM344]]'s "rollout succeeded, the fleet has
findings" - a *successful* deploy. So the watcher deployed, printed the
success text, and died. From outside that reads as "it deployed once and
stopped", because that is precisely what it did.
:::

# Measured

The real `deploy()` with the transport stubbed, driven three times:

```datatable
columns: Updater exit | Original | Fixed
widths: 5.0cm | 3.0cm | X
bold: 1
tone: medium
---
0 - rollout clean | survived | survived
**2 - rollout succeeded, fleet has findings** | **EXITED 2** | survived
**9 - rollout failed** | **EXITED 9** | survived
---
```

The original survived only a perfectly clean deploy. On this fleet,
findings are the normal state.

# A branch that could never run

The caller has a failure arm:

```
Deploy of %s FAILED (status %s); skipping (bump again to retry)
```

It was **unreachable**. Any non-zero status killed the shell at the call,
so nothing ever reached the `case`. A message written to reassure an
operator that the watcher was still going could only be printed by a
watcher that was not.

# What this explains, and what it retracts

0.10.14 sat in `dist/` unnoticed after it was cut. The tarball was
present and the watcher was not running: 0.10.13's deploy had ended
`ROLLOUT SUCCEEDED, FLEET HAS FINDINGS` - status 2 - and killed it.

**The baseline-swallow hypothesis was wrong** and is retracted here. It
was a reasonable guess and it had precedent (0.9.11, 0.9.14), which is
exactly why it needed testing rather than adopting. The watcher was not
mis-computing a baseline; it was not running.

# The fix

No option juggling anywhere:

```bash
ssh "$HOST" "..." || rc=$?
return "$rc"
```

`|| rc=$?` never trips `-e`, so nothing needs saving or restoring and
there is nothing to leave in the wrong state. The caller does the same:
`rc=0; deploy "$next" || rc=$?`.

# Where this script lives

It runs on the operator's machine, not the server, and it is currently
held in `inbox/` - which is a handover and is gitignored, so the fix
would be lost the moment the inbox is tidied. A durable copy is
committed alongside this filing at `tools/lazysite-deploy.sh`, with the
host taken from the environment and no default naming anyone's
infrastructure.

# The fix is redundant on purpose, and that showed up in testing

Both `deploy()` and its caller were changed, and **either alone is
sufficient**: `rc=0; deploy "$next" || rc=$?` in the caller consumes the
status whatever `-e` is doing by then.

That surfaced while verifying: reverting only `deploy()` left every
behavioural test passing, and only the source assertion failed.
Reverting **both** reproduces the defect. Worth knowing before anyone
"simplifies" one of them away on the grounds that the other covers it -
they are two independent guards against the same shell behaviour, and
removing either leaves the remaining one carrying the whole thing.

# Verification

- The real `deploy()` returning 2 and 9 leaves the watcher running.
- A clean deploy is unchanged.
- No `set +e` or `set -e` remains inside either function.
- The failure arm is now reachable, which can be seen by a non-zero
  status producing its message instead of an exit.

# Related

[[SM344]] (status 2 means the rollout succeeded - the code being
returned here), [[SM331]] and [[SM345]] (the flags this watcher passes).
