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
status-note: "CANDIDATE, planned 2026-10-18. OOM 0.31 built (04be130), Q1-Q4 answered. D0-D4 buildable now against a vendored 0.31; host tests need the owner's install. Supersedes SM1082 C3's Odoo part."
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
