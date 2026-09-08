---
id: SM782
title: "SM782: the manager manages what it lists, a package refusal names the scope, and a config key can be missing or cleared"
subtitle: "137E-03 on 0.13.7, four things found around the eviction test: the installer's pre-upgrade archives were listed as manual snapshots, counted toward no cap and refused by backup-delete as 'Not a lazysite snapshot name'; site-backup-delete refused a manage_domains token with 'You do not have access to this package' and no rule; config-set reported a missing key as an empty invalid one and could not clear backup_retention back to the default it ships with."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-08 on claude/sm782-the-manager-manages-what-it-lists (stacked on SM781). backup-list lists lazysite-backup-<date>-<time>-pre-<version> as kind upgrade, scope engine, and backup-delete removes it; the delete refusal names the two name shapes it manages. The package refusal (SM578's rule) says a token reaches a package only through a WebDAV scope containing its content root, names the package's root and the grant's scopes, and that the sysop's session is exempt. config-set refuses a missing key by name and lets canonical_ip, asset_max_age and backup_retention be cleared to their defaults; an empty backup_retention reads as the default silently in both readers (engine and installer). t/unit/manager/20, 46 and 10 assert each."
---

# What the field saw

1. Three `lazysite-backup-…-pre-0.13.x.tar.gz` archives listed as `manual`,
   untouched by the keep=3 eviction that removed a newer backup, and refused
   by `backup-delete`: "Not a lazysite snapshot name". Listed, unmanaged,
   and the message said the name was wrong rather than unparsed.
2. `site-backup-delete` with `manage_domains` over a token: "You do not have
   access to this package." - thirteen times; the sysop's session deleted
   all thirteen. No rule named.
3. `site-backup-delete` declares `name` as `query_or_body`; a body was
   answered "A site package name is required".
4. `config-set` with `{backup_retention: 3}` → "Config key '' is not
   settable"; `{key: backup_retention, value: ""}` → "A value is required",
   so the shipped state (empty = the default) was unreachable.

# What was true

1. The installer's pre-upgrade archive holds the engine files the previous
   install recorded, so an upgrade can be undone (install.pl
   `create_backup`). The manager's listing knew five kinds and defaulted
   the rest to `manual`; the delete accepted four name shapes and this was
   not one; the evictor keys on the kind prefix, so it never saw them.
   install.pl rotates its own, so nothing was lost - but nothing could be
   removed by hand either, and the reader was sent to the wrong place.
2. SM578: a token grant reaches a package only through a WebDAV scope that
   contains the package's content root; a token naming no scope reaches
   none; a package with no content root (the primary) is reachable by no
   token. The rule is deliberate; the sentence did not carry it.
3. The dispatcher reads `$req->{name} // $params{name}` on a POST, so a
   JSON body is honoured. A body that is not JSON (form-encoded, or with a
   different content type) decodes to nothing, which is the answer the
   field got. Not changed; answered in the reply with the shape that works.
4. A missing `key` fell through to the allow-list check as `''`; the
   clear was permitted for `canonical_ip` only; and the engine's reader
   logged a WARN for an empty value on every read.

# What is built

- `backup-list`: `lazysite-backup-<date>-<time>-…` is kind `upgrade`, scope
  `engine`. `backup-delete` removes it; the refusal for any other shape
  names the two shapes the action manages.
- `_package_grant_refusal`: "A token grant reaches a site package only
  through a WebDAV scope that contains the package's content root; this
  package has 'sites/x' | no content root (the primary domain) and this
  grant names <scopes> | no scope. The sysop's own session is exempt; a
  token needs a dav_scope covering the package, or the sysop removes it."
- `config-set`: `key is required (send {"key": "<name>", "value":
  "<value>"} in the JSON body)`; `canonical_ip`, `asset_max_age` and
  `backup_retention` may be cleared to their defaults; an empty
  `backup_retention` reads as the default silently in `Lazysite::Util` and
  in install.pl's mirror.
- Tests: t/unit/manager/20 (the installer archive listed as upgrade/engine,
  deleted, the refusal's two shapes), 46 (the refusal names the scope rule
  and the grant's scopes), 10 (missing key; clear to default; a key with no
  default still needs a value).
