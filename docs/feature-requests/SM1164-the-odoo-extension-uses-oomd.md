---
id: SM1164
title: "SM1164: the Odoo extension starts and uses oomd, a resident OOM"
subtitle: "lazysited supervises one oomd per site, the extension writes its config, every Odoo call goes through the daemon client with the in-process path as the fallback, and Status shows the daemon."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-18
raised-by: OOM agent at the owner's request (inbox L7 and its addendum, 2026-10-18)
area: odoo
status-note: "CANDIDATE. D0 shipped on n655 (t/unit/odoo/55); D1-D4 shipped on n657 (t/unit/odoo/60-62, t/unit/daemon/14), on OOM 0.33 as vendored with bin/oomd (SM1175). D5 (the bench) waits for the owner's install of 0.31+ on the host, so the status stays candidate. Sign-in, sign-out and the two-factor step stay in-process: oomd has no verb for them (see What shipped). Supersedes SM1082 C3's Odoo part."
---

# The request

Inbox L7, 2026-10-18 (OOM agent, at the owner's request): "the Odoo
extension starts and uses oomd, a resident OOM". The addendum gives the
names from OOM's spec `docs/specs/oomd-1.md` (OOM 0.31, being built). The
lab measured a cold read through the extension at 0.5-1 s against Odoo's own
55-85 ms; SM1144's bench on this host (2026-10-17) put module loading at
about three quarters of an Odoo token request. The owner ruled for a
resident OOM. This is SM1082 track C3's Odoo part, which waited for OOM.

# What lazysite already has

- **A supervisor.** `lazysited` (SM666): one child per service, backoff,
  `failed` for a flapping child, status through `Lazysite::Lifecycle`. One
  service today (the scheduler). It runs only while the daemon extension is
  enabled, as the user the request path writes as (SM760).
- **The run user.** That user is `www-data` on a plain-CGI site, shared
  with every other plain-CGI site on the host, and the pool's `USER=` on a
  pooled site. This is the fact behind Q1.
- **Binding parameter names** match `[a-z][a-z0-9_]{0,63}`
  (`Lazysite/Odoo/Binding.pm`), so a binding cannot emit 0.29's
  `set.<field>` names today.
- **Packs.** `odoo_packs` names Perl namespaces; nothing passes `pack_dirs`.

# The plan

## D0 - usable now on OOM 0.30 (S)

- `odoo_pack_dirs` in the extension's config, passed to OOM as `pack_dirs`
  (the site's own packs under its tree, plus `/usr/share/odoo-oom/packs` when
  `odoo-oom-packs` is installed). `<pack>.<op>` names bind like `core.read`.
- A binding may name a parameter `set.<field>` (the field part as Odoo field
  names are, lower case, digits, `_`), for `core.set` and `core.make`. Every
  other name keeps today's rule.

## D1 - the site's oomd.conf (S)

Written by the extension from its config, `0600`, beside its secrets:
the instance (`url`, `db`, `ssl_ca_file`, `timeout`), `credentials` as
labels (`conn:` the connection user's key file, `grant-<name>:` each MCP
grant's; `label:/path`, or `label:login:/path` for another login's key),
`pack_dirs`, the audit settings, `cache_ttl_version` (default 300 s: a
module installed in Odoo is seen within that time), `socket` (Q1),
`workers` (`odoo_daemon_workers`, default 4; the owner's ruling is to match
Odoo's own workers, which the operator sets, since lazysite cannot read
Odoo's config). Rewritten when the extension's config is saved; the daemon
is sent SIGHUP. No key ever goes into the conf; a request names a label.

**The socket** is `{site}/lazysite/run/oomd.sock` when that path is under
104 bytes (the Unix socket limit); otherwise oomd's default directory with
the site's domain as the name. `lazysite check` names which, and the
supervisor creates the directory.

## D2 - oomd as a lazysited service (M)

`Lazysite::Daemon::Service::Oomd`: runs
`oomd --name <site> --config <conf> --foreground` while the Odoo extension
is enabled and `odoo_daemon: on`; waits for `oomd <name> ready <socket>`;
SIGTERM to stop (30 s), SIGHUP on a config change; restarts on a crash
under the supervisor's backoff; restarts when the health verb's OOM version
differs from the installed one (read from `Odoo::Ops::Version`, which loads
nothing else). With the daemon extension off, or oomd not installed, nothing
starts and every call takes the in-process path.

## D3 - the call path (M)

Every engine call (`Lazysite::Odoo::call`, confirm, sign-in, sign-out, the
two-factor step) goes through `Odoo::Ops::Client::Daemon` with the same
arguments it passes in-process; a person's session id goes with each
request, and `actor` with `run` and with `approve` (the approval records it).
Every answer carries `via` (`daemon` or `in-process`); the call record keeps
it, and SM1144's `call` phase carries `desc="oomd"` or `desc="in-process"`,
so a page's Server-Timing shows which path it took.

- **Fallback:** on for a site (the client is given the extension's config,
  so a down daemon means a slower page, not a refused one), and the
  fallback is recorded. `odoo_daemon: required` turns it off: a down
  daemon refuses the call with OOM's `daemon-down` code and the extension
  says so. Tests that prove the daemon path pass `fallback => 0`.
- **The client is light:** 35 modules and about 28 ms against 99 and 105 ms
  for the in-process tree (OOM's measure); the tree loads only on a
  fallback.

## D4 - Status (S)

The operator's Odoo status shows the daemon: name, health, OOM version,
packs, workers, uptime; and `failed` with the supervisor's reason when it
flaps. `lazysite check` names a site with `odoo_daemon: on` whose daemon is
not running.

## D5 - measured (S)

SM1144's bench gains `odoo-oomd`, against the lab's local Odoo, beside
`odoo` and `odoo-direct`: the claim is the difference, read off a response.

# Order and size

- **V:** vendor OOM 0.31 (`tools/vendor-oom.sh --deb` with the 0.31 deb,
  release commit `04be130`), as n644 did for 0.27; `owns.deps` names
  `libodoo-oom-perl (>= 0.31)` for the daemon path only, and the in-process
  path keeps working on 0.27 and later.
- **D0** (wave 2, on n641's endpoint), then **D1-D4** on V, each with the
  real oomd started from the vendored tree in its tests.
- **D5** once the owner installs 0.31 on the host.

M-L in all.

# Questions asked of OOM, and OOM's answers (0.31, 2026-10-18)

Asked in `odoo/oom/inbox/2026-10-18-lazysite-on-oomd-four-questions.md`;
answered in the lazysite inbox, `2026-10-18-L7-oom-0.31-shipped-answers-and-differences.md`.

| Ref | Question | Answer |
|---|---|---|
| Q1 | The run user. "The site's own user" is `www-data` on every plain-CGI site, shared between sites; the default socket (`/tmp/oomd-<uid>/<name>.sock`) is then shared between sites too. lazysite will pass `socket =` under the site's own `lazysite/` directory. Is an explicit socket fully supported for `--check`, `status` and the client (`socket => $path`)? | Yes, everywhere; the directory must exist and the path stay under 104 bytes. The boundary is the Unix user: sites sharing `www-data` are not kept apart by oomd (they could read each other's key files already); sites that must be apart run on the pool, each as its own user. oomd also refuses a peer of another uid. |
| Q2 | The client's weight. Module loading is most of an Odoo request on CGI. Does `Odoo::Ops::Client::Daemon` load the in-process OOM tree only on the fallback? | Yes: 35 modules, about 28 ms; a test checks `%INC`. |
| Q3 | Fallback control. Can the caller turn the in-process fallback off (for tests, and for an operator who wants a failure, not a slow page)? | `fallback => 0` (the default without a `config`); a down daemon dies `transport` with code `daemon-down` and a `fix` line. A failure after the daemon took the request stays a plain `transport` error, since a write may have happened. |
| Q4 | Version check. Is the installed version read cheaply (without loading the tree) so the supervisor can compare it with the health verb's? | `Odoo::Ops::Version` (only `$VERSION`) or `/usr/share/odoo-oom/VERSION`. |

**Measured by OOM (its busy test host):** an API-key read 1,040-1,210 ms in a
new process, 84-103 ms through a warm oomd; a person's session read
1,100-1,180 ms against 156-177 ms. Eight parallel requests on eight workers
took about the time of one.

# Not in this

`core.credential` (change a password, turn two-factor on or off, as the
person) is a feature of its own on L4's sign-in dialog; it is noted here and
filed when L4's next slice is planned.

# What shipped (D0)

Branch n655, on OOM 0.32 as vendored by n648. Test:
`t/unit/odoo/55-a-site-pack-binds-and-a-binding-sets-a-field.t`.

- **`odoo_pack_dirs`.** A colon list of full paths in the extension's config
  (`plugins/odoo.pl`: config list, `owns.config_keys`, a manager-form field with
  its tooltip). `Lazysite::Odoo::connection` checks each entry once, when the
  config loads: it is resolved (symlinks and `..` included) and must be an
  existing directory under the site's docroot or lazysite tree, or
  `/usr/share/odoo-oom/packs`. Anything else refuses the whole connection with
  `odoo_pack_dirs: '<dir>' ...` naming it, because a pack is code. The resolved
  list is `pack_dirs` on the connection (and in the status answer) and goes to
  OOM's `Odoo::Ops::Registry->new( pack_dirs => ..., cache_dir => <store>/cache )`,
  so `<pack>.<op>` binds, lists and runs like `core.read`. With none set OOM reads
  its own environment and the packaged packs, as before.
- **`set.<field>` parameters.** A binding may name `set.<field>` (field as Odoo
  names fields: `[a-z][a-z0-9_]{0,63}`) in `params` or `fixed`;
  `Lazysite::Odoo::Binding` checks it against the operation's `set.<field>`
  declaration (`core.set`, `core.make`), so any other operation refuses it as a
  parameter it does not declare. `set.Name`, `set.`, `set.a.b` and every other
  name keep today's rule and are refused. A value fed from a request is still a
  plain value (str, int, bool): the declaration is `str`.
- **Test.** OOM's fake Odoo as transport: a site pack binds and runs; a pack
  directory outside the tree (another tempdir, `/etc`, a relative path, a `..`
  escape, a symlink out, a missing directory) is refused naming it; a
  `core.set` binding with `title=set.name` changes the field in the fake.
  Sabotage: with the base `Odoo.pm` the pack subtest fails, with the base
  `Binding.pm` the `set.` subtests fail.

# What shipped (D1-D4)

Branch n657, on OOM 0.33 as vendored by SM1175 (which also gave the snapshot
`bin/oomd`, so the tests start the real daemon from the repository and never
from the host, SM1081). Tests:
`t/unit/odoo/60-the-odoo-config-writes-oomds-config.t` (D1),
`t/unit/daemon/14-oomd-is-a-service-only-while-its-gates-hold.t` (D2),
`t/unit/odoo/61-a-call-goes-through-oomd-and-says-which-path-it-took.t` (D3),
`t/unit/odoo/62-the-odoo-status-shows-the-daemon-and-check-names-a-site-without-it.t`
(D4). They use `t/lib/OdooDaemonTest.pm`: a configured site, the vendored
`bin/oomd` started under the extension's service against OOM's fake Odoo
(`Odoo::Test::CliFake`), `PERL5LIB` set to the vendored lib, the vendored test
lib and this repository's lib (oomd's own `use lib` already puts the vendored
lib first), and every process stopped by the pid the test started.

- **The settings.** `odoo_daemon` is `off` (default), `on` or `required`; a
  value that is none of them is refused by name when the config loads, so a typo
  for `required` is never read as `off`. `odoo_daemon_workers` is 1-64, default
  4. Both are in the extension's config form with tooltips and in
  `owns.config_keys`.
- **D1, the conf.** `Lazysite::Odoo::Daemon` writes `lazysite/odoo/oomd.conf`
  0600 (a temporary file under umask 077, renamed over it), beside the keys:
  `url`, `db`, `login`, `timeout`, `max_response_bytes`, `allow_writes`,
  `ssl_ca_file`, `runs_dir` (`lazysite/odoo/runs`), `record_reads = 0`,
  `cache_dir`, `cache_ttl_version = 300`, `pack_dirs`, `workers`, `socket`,
  `log`, and `credentials` as labels: `conn:<key file>`,
  `grant-<hash>:<login>:<key file>` for an MCP grant's own account and
  `sched-<hash>:<login>:<key file>` for SM1161's scheduled keys (the label is the
  key account's own name, which fits oomd's label rule). Only a key that exists is
  named, because oomd refuses a config whose credential file it cannot read. No key
  is ever in it. The extension has no OOM audit settings of its own, so none are
  written; each run keeps OOM's audit beside its journal as before. It is
  rewritten when the config is saved (a new `on_save` hook, a declared hidden
  action of the extension, that `action_plugin_save` runs after the write the way
  `on_enable` runs after the toggle) and when a key is set or cleared (a new label),
  and the daemon is sent SIGHUP. With `odoo_daemon` off the file is removed.
- **The socket.** `lazysite/run/oomd.sock` when that path is under 104 bytes;
  otherwise `/tmp/oomd-<uid>/<name>.sock`, oomd's own default directory (stated
  explicitly, so the service and the CGI agree whatever each one's environment
  says). The name is the host instance's name (`/etc/lazysite/daemon/<domain>.conf`,
  conventionally the domain) or, with none, the directory's name and a short hash
  of its full path. The service creates the directory 0700; `lazysite check` says
  which of the two a site uses.
- **D2, the service.** `Lazysite::Daemon::Service::Oomd` is a thin parent over
  `oomd --name <name> --config <conf> --foreground` that waits for
  `oomd <name> ready <socket>`, forwards SIGTERM (oomd's own 30 s deadline) and
  SIGHUP, and returns non-zero when oomd exits so the supervisor's backoff and
  `failed` ceiling apply as they do to the scheduler. The supervisor lists it
  (`services($root, oomd => 1)`) only while `Oomd::wanted` holds: the Odoo
  extension enabled, a connection that loads, `odoo_daemon` on or required, oomd
  installed (`/usr/bin/oomd`; a test points `$COMMAND` at the vendored front
  door). The daemon extension itself is the supervisor's existing gate. The gate
  is re-read every 5 s; when it closes the supervisor stops oomd without blocking
  its other services and forgets its failures, and a later enable starts clean.
  Nothing starts on a guess: with any gate closed no process exists. It restarts
  oomd for a change of `odoo_packs` (OOM reads those from its environment, so a
  SIGHUP does not carry it) and, once per installed version, when the health
  verb's version is not the one `Odoo::Ops::Version` now says (read afresh each
  time, so an upgrade under a running service is seen). A leftover oomd of the
  same socket from a supervisor that died is told to stop before a new one starts.
  The run user is whatever lazysited runs as (SM760); the filing's Q1 answer stands.
- **D3, the call path.** With `odoo_daemon` on or required, `Lazysite::Odoo::_run`
  and `confirm` send the request through `Odoo::Ops::Client::Daemon` (always
  `fallback => 0`): the operation, the parameters assembled against its
  declaration, `credential` as the connection's label (or a grant's or schedule's
  own, or `{session => <id>}` for a session binding) and `actor` as the in-process
  context gives OOM's audit. A write is planned by the daemon, its plan saved in the
  plan store beside lazysite's own `meta.json`, which now also names the daemon's
  run; an `apply: immediate` binding and a confirm send `approve` with the actor
  (`binding:<id>`, or the plan's owner) and then `apply`. The person's session id
  is in the request and in no file (the test greps the whole site). A plan made
  in-process confirms in-process. `on` falls back in-process when the client or the
  daemon is absent, and the page is slower, not refused; `required` refuses with
  OOM's `daemon-down` code, said as the kind `daemon-down` and recorded
  `unanswered`. The fallback is lazysite's own in-process path (its packs, its
  session transport) rather than the client's `config` fallback, so there is one
  implementation of it. The call record has a new fixed field `via` (`daemon` or
  `in-process`), and `Lazysite::Timing::desc` gives SM1144's `call` phase
  `desc="oomd"` or `desc="in-process"` (`call;desc="oomd";dur=12.00`). The daemon's
  run folders (`lazysite/odoo/runs`) are pruned with the plans.
- **D4, Status.** `odoo-status` carries `daemon`: mode, name, socket and whether it
  is the site's own or the default directory, installed, running, and from the
  health verb the name, OOM version, packs, workers and uptime; when the
  supervisor has given up, `failed` and oomd's own last line of stderr as the reason
  (also on the daemon extension's per-service Status, as `oomd said: ...`).
  `lazysite check` names a site with `odoo_daemon` on whose daemon is not running
  (a warning; a failure for `required`, since every call is refused) with why when
  it knows, and says it is running when it is.

## What did not go through the daemon, and why

Sign-in, sign-out, the two-factor step and the identity refresh stay in-process.
The filing lists them with the engine calls, but oomd's protocol has no verb for a
sign-in: its requests are `run`, `check`, `apply`, `revert`, `resume` and `approve`
of an operation, and `health`. A sign-in is Odoo's web login (`Odoo::Transport::Session`),
not an operation, and `core.credential` is the person changing a password or
two-factor, which the filing puts out of this slice. They keep the page's
`call` phase `desc="in-process"`. If the owner wants them resident, OOM needs a
sign-in verb first; that is a question for OOM, not a lazysite change.

The binding, parameter and operation declarations a request is checked against
(`operation_class`) are still read from OOM's registry in this process, because a
binding is validated against what the operation declares before anything is sent.
That is OOM's lazy registry loading one class, and is the remaining in-process
cost of a daemon call; moving the declarations out of process would need OOM to
serve them.

## What could not be tested on this host

- The `/usr/bin/oomd` of production: the tests run the vendored front door, so
  that the host's package is never read. The service's production default
  (`$COMMAND = ['/usr/bin/oomd']`) is a one-line constant.
- A real Odoo: the fake Odoo (`CliFake`) answers; the daemon's behaviour against
  Odoo's own latency is D5, which needs the owner's install.
- Pool or Hestia deployments: the supervisor is run in-process, not under
  `lazysited@<domain>` and systemd. The same-uid arrangement (SM760) is the
  supervisor's, unchanged.
- A site path long enough to force the default socket directory is covered for
  the choice and the name (test 60), not by starting a daemon on it.
