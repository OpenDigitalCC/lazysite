---
id: SM1248
title: "SM1248: a change of odoo_packs reloads oomd with no gap"
subtitle: "oomd's config names the site's packs, and a change is taken by OOM's reload verb with the socket kept. The service no longer restarts oomd for one, so a call made meanwhile is never refused or sent in-process."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: "supervisor brief, task #373 item 3 (SM1211's open window; OOM 0.39 oomd-39)"
area: odoo
status-note: "SHIPPED (0.16.1) on n727: Lazysite::Odoo::Daemon writes `namespaces`; Lazysite::Daemon::Service::Oomd asks the `reload` verb on SIGHUP and starts oomd without ODOO_OPS_NAMESPACES; the restart for a changed odoo_packs is gone. t/unit/odoo/103, t/unit/daemon/14."
---

# What was asked

[[SM1211]] left one window open ("One window is OOM's"). oomd read its operation
namespaces from `ODOO_OPS_NAMESPACES` at its start. So when `odoo_packs` changed, the
service (`Lazysite::Daemon::Service::Oomd`, `_env_signature` changed) stopped oomd
and started it again. While it restarted there was no socket:

- with `odoo_daemon: required` every call was refused as `daemon-down`;
- with `on` it ran in-process (a slower page, recorded as `via: in-process`).

SM1211 also noted that "adding a pack without a restart would need an oomd verb that
loads a pack". OOM 0.39 ships that verb (oomd-39). The task: use the config's
`namespaces` and the `reload` verb, so a change applies with no gap, then remove the
restart path.

# What OOM 0.42 has, read from its source

Checked in `t/vendor/oom` (OOM b91d5e2, [[SM1247]]), not from memory:

- **The verb.** `lib/Odoo/Ops/Daemon.pm` accepts `{"v":1, "verb":"reload"}` on the
  socket. Its `_reload` reads the config again and forks the new workers. Each
  worker builds its registry and says READY or FAIL. Until every one has, no request
  is handed on: it waits. Then the new workers take over, the old ones finish the
  request in hand, and the generation rises. A worker that fails, or 30 seconds
  without an answer, ends the reload: the old workers keep serving, and the answer
  is an error of kind `config` naming why. SIGHUP does the same.
- **The client.** `lib/Odoo/Ops/Client/Daemon.pm` `sub reload ($self)` takes no
  argument. It answers `{ reloaded, generation, namespaces, packs, workers }`, or
  dies: with the refusal, or with `transport`/`daemon-down` when nothing answers.
- **The config key.** `lib/Odoo/Ops/Config.pm` knows `namespaces`, a comma list of
  Perl package names checked against a pattern; an empty value is refused. The
  registry (`Registry::extra_namespaces`) takes the config's list, **then the
  environment's**. A worker calls `use_config`, so a custom change's bare
  `Registry->new` (Runner) sees the config's list.
- `health` carries `generation` and `namespaces`.

# What shipped

- **oomd's config names the packs.** `Lazysite::Odoo::Daemon::render_conf` writes
  `namespaces = <odoo_packs>` when the list is not empty and the installed OOM is
  0.39 or later (`reloads_namespaces`).
- **oomd starts without `ODOO_OPS_NAMESPACES`.** OOM adds the environment's list
  after the config's, so a pack the environment named could never be taken out by a
  reload. The config is now the whole list.
- **SIGHUP is the reload verb.** On the service's SIGHUP (sent by
  `Lazysite::Odoo::Daemon::refresh` after a config save writes the conf), the
  service asks `reload` and logs the answer:
  - `oomd reloaded` with the generation and namespaces;
  - on a refusal, `oomd did not reload; the workers it had go on serving` with
    OOM's reason.

  The socket and the process stay. A call made while the new workers start waits
  for them; it is not refused, and it does not fall back.
- **The restart path is removed** (`_env_signature` and the restart it set). The
  restart for a new OOM version, when the health verb's version is not the installed
  one, stays: an upgraded package needs a new process.

# OOM before 0.39

The daemon path needs OOM 0.31 or later; lazysite's `OOM_MIN` is 0.03.

An oomd before 0.39 refuses a config key it does not know, and has no `reload` verb.
For such an OOM:

- the conf does not name the namespaces;
- oomd starts with `ODOO_OPS_NAMESPACES` set from `odoo_packs`, as before;
- SIGHUP is passed on, as before.

A changed `odoo_packs` then waits for oomd's next start, and the service logs a WARN
that says so. It is not restarted for it.

# Tests

- **t/unit/odoo/103**, new, runs the real oomd with `odoo_daemon: required`. The
  test's own environment names a pack the config does not. It checks that:
  - the conf names `odoo_packs`, and oomd serves only that;
  - a pack added is served by the same process at generation 2. Calls made every
    25 ms from the signal until then (64 in one run) were all answered by the daemon.
    The added pack's operation answers through the daemon, and the service logs the
    reload;
  - a pack taken out is gone from the daemon, though the environment names it;
  - a reload oomd refuses (a namespace with no module) leaves generation 3 serving,
    and the service logs why;
  - with the installed OOM taken as 0.38, the conf does not name the namespaces,
    oomd serves the environment's list, and a change is logged as waiting, with no
    restart.
- **t/unit/daemon/14**: "a change of odoo_packs is a restart" is now "a reload, not a
  restart". The same oomd serves the added pack, at a higher generation.

Sabotage, backups under tmp/:

- The service and `Lazysite::Odoo::Daemon` as they were fail 103 and 14. In 103 the
  calls made during the restart were refused (`daemon-down`), and the pid changed.
- The fix without removing `ODOO_OPS_NAMESPACES` from oomd's environment fails 103:
  the environment's pack is served, and is not gone when it is taken out.

# Not done

- **The save does not wait for the reload.** `refresh` signals the service and
  returns, as before. Whether the reload took is in the site log. The Odoo status
  does not show `generation`.
- **OOM 0.31 to 0.38.** The behaviour above keeps such a host working, but a pack
  change waits for oomd's next start. The release manager ruled on 2026-10-22 to keep
  this fallback rather than require 0.39 for the daemon.
