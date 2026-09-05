# Dimension 6 - Security - the daemon service, pre-0.13.1

- Audited artefact: `main` at `53df9a44`, clean worktree
- Date: 2026-09-05
- Regime: Commercial
- Prior verdict: none - first review of this service

## Verdict

**PASS**, with one structural note the documentation dimension carries. The
service adds no external interface, no listener, no egress and no new
authentication; it adds a long-lived, privilege-dropped process acting **without
a request**, and the design closes the question that raises - "as whom, and
allowed what?" - correctly and in the right place. The one property that would
have been a security finding (a process restarted forever) is D1's F1.1 and is
recorded here as its resource-exhaustion face.

## Method

STRIDE read of the new process against the threat model in `docs/SECURITY.md`,
with the code as the evidence: the privilege drop in `tools/lazysited.pl`, the
identity gate in `Scheduler.pm`, every subprocess call in scope, every file the
runtime writes and its mode, the unit's sandbox directives, and the provisioning
tool's inputs. Then the question the threat model does not yet ask: what can a
sysop do with `daemon_job_user`?

## Findings

### F6.1 - Elevation: the process never acts as root or as `system` (PASS)

- The unit starts as root only because `User=` cannot be templated from a
  domain; `lazysited.pl` sets groups, then uid, then **checks both real and
  effective uid left 0** before loading any daemon code - the `lazysite-pool.pl`
  pattern, verbatim. Root without `--user` is refused with a sentence that says
  why. Exercised only in the unprivileged branch by the suite (D3); D5 carries
  the "never run on a real host" caveat.
- A job runs as a lazysite **account** holding `run_jobs`; `system:*` is refused
  by name before the capability lookup. The account then faces the ordinary
  capability gate per job (`needs`), read by the test from the manager's own gate
  table. There is no scheduled-work exemption anywhere in scope.
- The job set is engine code. No configuration surface can add a job (asserted:
  `t/unit/daemon/02` writes `job_evil:` into the daemon's own config and the set
  is unchanged).

### F6.2 - Tampering and injection: no shell, no string-loaded code (PASS)

Every subprocess in scope is list-form (`open '-|', $^X, $tool, @args` in
`Jobs.pm`; `run_or_fail($systemctl, ...)` in the Hestia tool). The domain the
tool interpolates into a unit-instance name passes `check_domain` first. The
service registry and the job table are barewords. `daemon_job_user` is consumed
only as a hash key into the group store, as a log field, and as an environment
variable for the stats subprocess; a value cannot escape a `key: value` line.

### F6.3 - Information disclosure: nothing new leaves the host (PASS)

No socket, no egress (phase 1 by decision). The runtime writes `lazysite/daemon/`
(pid files, the run record - job names, outcomes, the actor, counts) under the
docroot, as the site's own Unix user, with the engine's `umask 0002`. That is the
same trust domain as the site's content; there is no privilege boundary between
the daemon's state and the sysop's files, **by design** - the daemon acts as the
site. The Hestia conf under `/etc/lazysite/daemon/` is root-owned 0644 and holds
`DOCROOT=` and `USER=`, neither secret. Log lines carry actor and job names, no
credential and no visitor data. The sessions sweep *removes* personal data (IP,
UA on expired rows) that previously persisted until a login; that is a reduction
in exposure, and the record says how many rows went.

### F6.4 - Denial of service: bounded at the unit, unbounded in the loop until F1.1 lands (WARN, cross-ref D1)

`Restart=on-failure` with `StartLimitBurst=5` in 300 s bounds a runtime that
cannot start (a configuration error). Inside a running supervisor, a service
that dies at once is currently forked again every ~2 s for ever (D1 F1.1) -
per instance. That is a fork-per-two-seconds per misconfigured site, not a
fork bomb, but on a 300-instance host it is a self-inflicted load with no log
line to find it by. Closes with F1.1.

`_stop_children` waits without a timeout; a wedged job blocks the supervisor's
own shutdown until systemd's `TimeoutStopSec` (default 90 s) kills the cgroup.
Acceptable; note for D5.

### F6.5 - The `daemon_job_user` setting is a delegation, and the docs name the safe shape (PASS, note)

A sysop with `manage_config` names the job account; the account must hold
`run_jobs`, which only `manage_users` can grant. A `manage_config`-only sysop
therefore cannot manufacture a job identity - but can point the scheduler at
any *existing* `run_jobs` holder, including a person. The consequences are
bounded by the closed job set (nothing runs that the engine would not run for
that account through the manager), and the plugin's config note says a purpose
account is preferred and why. The threat model should record this delegation
explicitly (D7/D8): it is a new way for one capability to act with another's
grants, even though what it can do with them is fixed.

### F6.6 - The sandbox directives are appropriate and were reasoned (PASS)

`NoNewPrivileges`, `ProtectSystem=full`, `PrivateTmp`, `PrivateDevices`,
`RestrictSUIDSGID`, `ProtectKernelTunables`, `ProtectControlGroups` - the
SEC-2026-07 set, matching the pool. `/etc` read-only is fine because the process
reads only under the docroot after the drop; `PrivateTmp` is fine because every
atomic write in scope is temp-beside-target, not `/tmp`.

## Recommendations, by impact

1. Land F1.1 (the loop bound) before the cut.
2. Add the register entry and the trust-boundary line (D7 F7.2, D8 F8.1): a
   scheduled actor without a request, and the `daemon_job_user` delegation.
3. When a host exists: run the root path once under observation (`ps -o
   user,pid,cmd` for the supervisor and child; `cat /proc/<pid>/status | grep
   -E 'Uid|Gid|Groups'`) and record it in the security register as the first
   observed privilege drop.
