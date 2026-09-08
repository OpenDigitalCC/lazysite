---
id: SM768
title: "SM768: an unopenable connector store is not an empty one"
subtitle: "0.13.6 on edge: with lazysite/connectors/ unwritable after the failed 0.13.5 install, connector-secret-set refused by name while connector-list answered has_secret: 0 for a secret that was there the whole time. The rule SM766 generalised - a store reader never turns an unopenable file into an empty answer - had not reached the store this same release added."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-08 on claude/sm768-an-unopenable-connector-store-is-not-an-empty-one. Every connector-store reader returns undef for a file that exists and cannot be opened (cannot_read logs file, error, unix user) and every action treats undef as a refusal: connector-list answers has_secret null with secrets_readable 0 and a warning; secret-set and delete write nothing over a store they could not read; a call is refused rather than sent without its credential; a rate cap that cannot be checked refuses. Write and read errors name the file under lazysite/connectors/ and the unix user, never the host path. cannot_read reads errno before getpwuid (it logged error= blank). t/lint/121 covers Connectors.pm and refuses a -f/-e guard in front of its opens; t/unit/manager/159 proves each answer with the store chmod 000."
---

# What the field saw

Build 0.13.6 on edge, token account holding `manage_connectors`. In one
minute, against one store:

- `connector-secret-set` → refused, by name: "cannot write
  .../lazysite/connectors/secrets.json: Permission denied".
- `connector-list` → `ok: true`, `has_secret: 0`.

When 0.13.6 restored the permissions, `connector-list` said `has_secret: 1`
before any secret had been set again. The secret was never deleted; the
reader could not open the file and rendered that as "no secret".

# What was true

`_read_json` opened the store with `or return ( cannot_read(...) // {} )`,
so the fault was logged - SM766's rule - but the answer was still `{}`, and
`{}` reads as "nothing set" in every caller. Worse, a `-f` guard stood in
front of the open: a directory the process may not search fails the stat,
and that path never reached `cannot_read` at all.

Three consequences beyond the listing, none observed on edge because the
write path refused first, all reachable on a host where the store is
readable by nobody and writable by the wrong user:

- `connector-secret-set` read `{}` and would have written it back with one
  secret in it - every other connector's secret gone.
- `call` read the secret as undef and would have sent the payload without
  its credential.
- `_calls_in_last_hour` read the call record as empty and the rate cap
  passed on a count it could not make.

Two smaller faults, found on the way: the write-path error printed the
host's absolute path (the standing rule says never), and `cannot_read`
called `getpwuid` before reading `$!`, so its log line carried `error=`
blank - the one field the rule exists to carry.

# What is built

- `_read_json` and the call-record readers return `{}` for ENOENT and
  **undef** for a file that exists and cannot be opened, with no stat guard
  in front. `cannot_read` logs file, error and unix user.
- `connector-list` answers `has_secret` as `1`, `0` or `null`, adds
  `secrets_readable`, and a `warning` naming the file under
  `lazysite/connectors/` and the unix user when the secret store is out of
  reach. If the connector store itself cannot be opened the listing is
  `ok: 0` with the same sentence.
- `connector-secret-set` and `connector-delete` refuse when either store
  cannot be read: nothing is written over what could not be read.
- `call` is refused - recorded and logged, `why: secret store unreadable` -
  rather than sent without a credential; a capped connector whose call
  record cannot be read is refused rather than counted as zero.
- Write errors say `cannot write connectors/<file>: <error> (unix user X)`.
- `t/lint/121` covers `Manager/Connectors.pm` and holds that no `-f`/`-e`
  guard stands in front of its opens. It fails on the old file both ways.
- `t/unit/manager/159`: with `secrets.json` at mode 000 the listing says
  null and why, set and delete refuse, the call refuses and the refusal is
  in the record; with `calls.jsonl` at 000 a capped call refuses.

# What is not built, and where it goes

The field's stronger form - a lint that covers **every** engine-owned store
by catalogue rather than by a list of directories - and the same `-f`-guard
class in `Auth/Settings.pm`, `Auth/Acl.pm` and `Auth/Session.pm` (each
guarded open there does reach `cannot_read`, so the fault is logged, but a
directory the process cannot search still reads as an empty store) are
SM770, a candidate.
