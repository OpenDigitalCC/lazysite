---
id: SM1152
title: "SM1152: a stale registry is rebuilt after the request, not inside it"
subtitle: "A request that finds a registry stale serves the one it has and starts a detached rebuild under one lock; a content write starts the rebuild when its request is over; a registry that does not exist is still built on first need."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: release manager, from SM1082 Q5 (SM1069's measurement, SM666's class), 2026-10-17
area: performance
status-note: "SHIPPED on n642: lazysite-processor/registries.pm, lib/Lazysite/Manager/Files.pm, lazysite-manager-api.pl; t/unit/processor/133, t/unit/manager/352."
---

# What happened

SM1069 measured a registry rebuild at 1.5-3 s on a 1,800-rule fixture ("post,
registries stale", 5 s against 0.3 s when fresh), paid by whichever request
arrived after the TTL, or after a content write dropped the outputs. SM666 names
the class: work done on the back of a visitor's request. SM1082 lists the fix
as Q5: "Registry rebuild out of the request: the scheduler rebuilds after a
write; a stale registry is served meanwhile."

SM389 had already made losers of a stampede serve the stale file, but the
winner still rebuilt inside its own request, and the page-render path
(`update_registries` after a cache write) rebuilt inline whenever any output was
past its TTL.

# What shipped

- A stale registry that exists is served as it is. `_serve_registry` and
  `update_registries` call `_schedule_registry_rebuild`, which takes a per-root
  lock without waiting and forks a detached child (double fork, new session,
  descriptors 0-2 on /dev/null, so the web server is not held waiting). The
  child runs `update_registries` and exits. A request that finds the lock taken
  starts nothing, so concurrent stale requests start one rebuild.
- A registry that does not exist is still built in the request that needs it:
  there is nothing to serve. The same holds if no child can be started.
- The rebuild writes each output beside and renames it into place, so a reader
  is never served half a sitemap while one is rebuilding.
- A content write through the manager (save, delete, move) drops the outputs as
  before (SM087) and records that a registry is owed. When the manager request
  has finished, `start_registry_rebuild` (an END block in
  lazysite-manager-api.pl) runs the processor detached for it, so the rebuild
  starts as the write completes. The actions do not start it themselves, so a
  test, the control API or MCP leaves no process behind; those paths rebuild on
  the next request, as before. Only the host the manager request came in on is
  rebuilt this way.

The scheduler was not used: its jobs run as a configured account with
`run_jobs` on a tick of minutes, and the daemon holds none of the processor's
render state, so it would have needed its own copy of the registry build. A
detached child of the processor works on every deployment, daemon or not.

t/unit/processor/133 drives the real processor: a stale registry is served
unchanged and is fresh afterwards; a missing one is built for the request; two
requests against a slow rebuild start one. t/unit/manager/352 covers the write.
