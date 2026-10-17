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
status-note: "CANDIDATE, planned 2026-10-18. D0 buildable now on OOM 0.30. D1-D4 built against oomd-1 with a fake daemon; land after OOM 0.31 ships and its second note confirms the names. Q1-Q4 asked of OOM. Supersedes SM1082 C3's Odoo part."
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
grant's), `pack_dirs`, the audit settings, `socket` (Q1), `workers`.
Rewritten when the extension's config is saved; the daemon is sent SIGHUP.
No key ever goes into the conf; a request names a label.

## D2 - oomd as a lazysited service (M)

`Lazysite::Daemon::Service::Oomd`: runs
`oomd --name <site> --config <conf> --foreground` while the Odoo extension
is enabled and `odoo_daemon: on`; waits for `oomd <name> ready <socket>`;
SIGTERM to stop (30 s), SIGHUP on a config change; restarts on a crash
under the supervisor's backoff; restarts when the health verb's OOM version
differs from the installed one. With the daemon extension off, or oomd not
installed, nothing starts and every call takes the in-process path.

## D3 - the call path (M)

Every engine call (`Lazysite::Odoo::call`, confirm, sign-in, sign-out, the
two-factor step) goes through `Odoo::Ops::Client::Daemon` with the same
arguments it passes in-process; a person's session id goes with each
request. When the client answers `via: in-process` the call record says so,
and SM1144's `call` phase carries `desc="oomd"` or `desc="in-process"`, so
a page's Server-Timing shows which path it took.

## D4 - Status (S)

The operator's Odoo status shows the daemon: name, health, OOM version,
packs, workers, uptime; and `failed` with the supervisor's reason when it
flaps. `lazysite check` names a site with `odoo_daemon: on` whose daemon is
not running.

## D5 - measured (S)

SM1144's bench gains `odoo-oomd`, against the lab's local Odoo, beside
`odoo` and `odoo-direct`: the claim is the difference, read off a response.

# Order and size

D0 now (wave 2, on n641's endpoint). D1-D4 built against oomd-1 with a fake
oomd in the tests (the protocol is JSON lines), held until OOM 0.31 ships and
its second note confirms the names; then the fake is checked against the
real daemon and D5 runs. M-L in all.

# Questions asked of OOM

Filed to `odoo/oom/inbox/2026-10-18-lazysite-on-oomd-four-questions.md`.

| Ref | Question |
|---|---|
| Q1 | The run user. "The site's own user" is `www-data` on every plain-CGI site, shared between sites; the default socket (`/tmp/oomd-<uid>/<name>.sock`) is then shared between sites too. lazysite will pass `socket =` under the site's own `lazysite/` directory. Is an explicit socket fully supported for `--check`, `status` and the client (`socket => $path`)? |
| Q2 | The client's weight. Module loading is most of an Odoo request on CGI. Does `Odoo::Ops::Client::Daemon` load the in-process OOM tree only on the fallback? |
| Q3 | Fallback control. Can the caller turn the in-process fallback off (for tests, and for an operator who wants a failure, not a slow page)? |
| Q4 | Version check. Is the installed version read cheaply (without loading the tree) so the supervisor can compare it with the health verb's? |

# Not in this

`core.credential` (change a password, turn two-factor on or off, as the
person) is a feature of its own on L4's sign-in dialog; it is noted here and
filed when L4's next slice is planned.
