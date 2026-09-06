---
id: SM760
title: "SM760: the runtime and the request path were two unix users, so each read the other's files as empty"
subtitle: "The 0.13.3 field pass, 2026-09-06: the first real run refused every job for a capability the account held, and Status called a running runtime 'not started'. One cause - www-data writes the site, the panel user ran the daemon - and two silent readers."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-06 on claude/sm760-the-runtime-and-the-request-path-are-two-unix-users for 0.13.4. The deploy and `add --daemon` write USER= from the request path's user (www-data on the CGI flow; the pool's USER with --fcgi); _alive treats EPERM as alive; read_group_settings/_groups_membership WARN on an unreadable store; resolve_job_user refuses an unreadable store by file, error and unix user; Status carries a runtime_user check; Disable runs Status with a bounded wait and says stopped / still stopping (pid); the running state is asserted in t/unit/daemon/08; t/unit/daemon/10 covers the rest. Needs a cut, a deploy (which rewrites the host conf) and a restart of the running instance."
---

# The two filings

`2026-09-06-daemon-runtime-capability-read-refuses-every-job.md` - every job
refused "does not hold run_jobs" for an account the Groups page and the three
Status checks said held it; a restart did not clear it; the refusals switched
to `run_jobs` at the moment the group was edited on the Groups page.

`2026-09-06-daemon-status-has-no-running-state.md` - Status holding a live
pid, an active service and fresh run records, saying "scheduler has not been
started", verdict `inconsistent`, `healthy: 0`, with the same sentence it
correctly uses when stopped; and no reading at all while disabled.

# What was true

On the tarball host the request path (the manager API, the control API, MCP,
WebDAV) runs as `www-data` - the deploy's permissions pass says so and sets
the docroot `<user>:www-data` with setgid directories for exactly that. The
deploy wrote `USER=<panel user>` into `/etc/lazysite/daemon/<domain>.conf`,
so the runtime ran as the panel user. The two share one write plane:

- The request path writes the auth stores `0660` (`_write_json_atomic`,
  SM289/SM428). When the agent granted `analytics` and `manage_users` to the
  job account's group on the Groups page, `www-data` rewrote
  `groups-settings.json` as `www-data:www-data 0660`. The panel user is not
  in `www-data`. `read_group_settings` did `open ... or return {}`; every
  account then held nothing; `resolve_job_user` said "does not hold
  run_jobs". Before that edit the file had been the deploy's `664` and the
  heartbeat ran - which is why the failure appeared at the edit and widened
  to the heartbeat.
- The runtime writes its pid and state; Status, in the request path as
  `www-data`, read the pid and asked `kill 0`. Another user's process
  answers `EPERM`; `_alive` read a false `kill` as dead; the service was
  `inconsistent` with its own pid in `detail`.

Both are the shape memory calls *vacuous pass on empty*: a reader that turns
"cannot read" into "nothing there".

# What is built

**The rule.** `USER=` is the unix user the request path writes as. The
tarball deploy writes `www-data` (`LAZYSITE_CGI_USER` to override), or the
pool's `USER=` when `/etc/lazysite/pools/<domain>.conf` exists;
`lazysite-hestia-domain add --daemon` writes the pool user with `--fcgi` and
`LAZYSITE_WEB_USER` (default `www-data`) otherwise. OPERATOR.md states it.

**The readers say so.** `read_group_settings` and `_groups_membership` WARN
with the file, the error and the unix user when a store exists and cannot be
opened. `resolve_job_user` checks the stores are readable before asking what
they hold, and refuses by name: `the runtime (unix user 'x') cannot read
lazysite/auth/groups-settings.json: Permission denied - the runtime must run
as the unix user the request path writes as; the deploy sets USER= in
/etc/lazysite/daemon/<domain>.conf`. That is what the run record - and so
Status `runs` - shows on a host that is still wrong.

**Status knows.** A `runtime_user` check compares the host conf's `USER=`
with the user Status itself runs as, which is the request path's user, so it
needs no knowledge of the host; the remedy is the line to write and the
restart. `_alive` treats `EPERM` as alive, so a running runtime is `on`,
healthy, no remedy - the field's "one more row", now asserted.

**Disable says whether it stopped.** `on_disable` runs Status with a wait
bounded by the gate interval (`$GATE_EVERY + 5` s); the toggle line reads
"disabled and the runtime is stopped" or "still stopping (pid N)".

# What the field will see

After the cut: the deploy rewrites the host conf with `USER=www-data` and
restarts the running instance. The runtime, now `www-data`, reads the group
settings `www-data` wrote; the jobs run; Status reads `kill 0` on its own
user's process and says `on`. The state the agent preserved (plugin enabled,
`daemon_job_user` set, group grants in place) is exactly the state that
should now run.

# Could a lint have caught it?

The agent's proposal - one resolver, and a test that the pre-flight check
and the run-time gate agree - is already the case: both call
`resolve_job_user`. They disagreed because they ran as different unix users
reading the same file, which no single-process test sees. What catches it is
the readers refusing to be silent (`t/unit/daemon/10` makes the store
unreadable and asserts the refusal names the file, not the capability) and
the deploy rule pinned by test. A lint that every `open ... or return {}` on
a store under `lazysite/auth/` names its failure would generalise the first
half; not built here.
