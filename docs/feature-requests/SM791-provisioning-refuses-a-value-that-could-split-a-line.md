---
id: SM791
title: "SM791: provisioning refuses a value that could split a line"
subtitle: "Security review, 0.13.8. Two one-line guards in the root-run Hestia provisioning: write_kv_file emits KEY=VALUE with no newline check, and check_domain anchors with ^...$ so a domain ending in a newline passes. Neither is exploitable in the current flow and the filing says so - the injected tail carries no '=' - which is exactly why they are cheap to close before something else calls them."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-08 on claude/secrev-residue-daemon-and-dav. check_domain anchors \A...\z, and write_kv_file refuses any value containing CR or LF - the guard placed in the shared writer rather than in each caller, because the registry and pool writers use it too and the next caller may not have the domain alphabet protecting it."
---

# The finding

`tools/lazysite-hestia-domain.pl` runs as root during provisioning and writes
the root-owned `/etc/lazysite/daemon/<domain>.conf` that `lazysited@.service`
consumes as an `EnvironmentFile`.

- `write_kv_file` prints `"$k=$v\n"` with no validation, so a newline in a
  value splits the line; a value carrying a newline *and* an `=` would let
  systemd honour an injected setting. The same shape is in the tarball flow's
  heredoc.
- `check_domain` tests `/^[A-Za-z0-9][A-Za-z0-9._-]*$/`, and Perl's `$` matches
  before a trailing newline - the only route by which a newline reaches a
  value.

**Not exploitable as it stands**, and the brief establishes that rather than
asserting it: the only caller-influenced part of `DOCROOT` is the domain, whose
alphabet has no `=` and no space, so an injected tail is a bare path that
systemd ignores as malformed. The inputs are the root operator's, not a
sysop's.

# What is asked

Two guards, because `write_kv_file` is shared with the registry and pool
writers and the next caller may not have the domain alphabet protecting it:

- `write_kv_file` refuses a value containing CR or LF.
- `check_domain` anchors `\A...\z`.

# Provenance

`inbox/2026-09-08-daemon-provisioning-newline-guards.md`. Accepted as filed,
including its own assessment that neither is a live break.
