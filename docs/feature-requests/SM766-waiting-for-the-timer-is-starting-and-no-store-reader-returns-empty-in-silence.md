---
id: SM766
title: "SM766: waiting for the timer is 'starting', and no store reader returns empty in silence"
subtitle: "From the 0.13.4 field pass, 2026-09-07 - a pass on every claim, with one observation and one rule offered. Both taken."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-07 on claude/sm766-starting-while-the-timer-waits-and-no-silent-empty-reader for 0.13.5. Supervisor: a service with no pid while the host timer is armed reads `starting` ('waiting for the host timer'), not `inconsistent`. Lazysite::Util::cannot_read is the one reporting reader-failure helper (WARN with file, error, unix user; silent only on ENOENT); every read-open in lib/Lazysite/Auth and lib/Lazysite/Daemon whose failure returns goes through it; t/lint/121 holds that, with `# not a store` as the one exemption (/proc)."
---

# From the results brief

`2026-09-07-edge-0.13.4-test-results.md`: 134E-01 PASS on every claim - the
runtime runs as the request path's user, `runtime_user` states the
comparison, `verdict: on` and `healthy: 1` with no remedy, all three jobs ran
as the job account with counts that changed between cycles, Disable said the
runtime stopped and the timer left it alone, re-enable came back on a new
pid, and two readings minutes apart were discriminating (the fast job moved,
the hourly ones did not). 134E-02 PASS. The scheduler did its maintenance
unattended for the first time.

Two things offered, both taken:

**The observation.** Enabled-but-awaiting-the-timer read `verdict:
inconsistent`, `healthy: 0`. Transient, self-clearing, and "a strong word
for a normal, expected wait; anything keyed on `healthy` will blip on every
enable". The lifecycle contract already has the word for "not running, and
something is about to do something about it": `starting`. A service with no
recorded pid while the host conf exists and its timer is enabled now reads
`starting` - "has not started yet; the host timer starts the runtime within
five minutes" - and the whole reads "the daemon is switched on and waiting
for the host timer to start it". `healthy` stays as the contract defines it
(on or off); `starting` is the honest transient.

**The rule.** "A store reader must never turn an unopenable file into an
empty answer" - the mechanism that made SM760's permissions fault look like
a capability fault. SM760 fixed the two readers that bit and left the rule
as "not done". Now: `Lazysite::Util::cannot_read($what, $path)` WARNs with
the file, the error and the unix user (silent only when the file is simply
absent) and returns undef so a caller keeps its empty shape; the users,
groups, group-settings, OAuth, ACL, domains, session and secret readers, and
the daemon's pid, state, run-record, host-conf and daemon.conf readers all
go through it. `t/lint/121` holds that every read-open under
`lib/Lazysite/Auth` and `lib/Lazysite/Daemon` whose failure branch returns
or skips does so through `cannot_read`; the one exemption is marked `# not a
store` (`/proc/<pid>/stat`, where absence is the ordinary case).

# Not done

The agent could not provoke the by-name refusal from outside on a correctly
configured host, and neither can a test on this box without a second unix
user; `t/unit/daemon/10` covers it with `chmod 000`, which is the same
reader path.
