---
id: SM1103
title: "SM1103: a write with no path is refused by name, and a refused create says who tried to write where"
subtitle: "A path sent in the body of an action that reads it from the query is refused, a content write with no path is a missing parameter, a folder is never a save's target, and a permission failure names the file, the folder, the process and the folder's mode."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: edge-testing agent, 0.15.6/0.15.7 test plans (U1)
area: manager
status-note: "SHIPPED on n612: lazysite-manager-api.pl (the SM1047 path block), Manager::Files _folder_target_refusal / _site_root_refusal, Manager::Common _perm_diagnosis; t/unit/manager/348."
---

# What happened

The 0.15.6/0.15.7 results file, "Root items, unchanged":

> P1 / P2: manager saves still fail on 0.15.7 with "Cannot write file:
> Permission denied". [...] After the operator ran `lazysite check --fix`
> (about 19:50Z), saves still fail the same way. The failing call is
> `write_file_checked`'s `open '>', "$path.$$.tmp"` (EACCES) [...] In the same
> folders, at the same time, these succeed: WebDAV PUT [...]; MCP write_file;
> acl-set and acl-remove moving a page out of and back into the docroot.

And row V4: "A failing manager save audits `save` / fail with the write's
reason. The target is still recorded as "/" rather than the page saved."

The tester then withdrew the finding
(`2026-10-16-correction-manager-saves-were-never-broken.md`):

> My manager-call script sent `{"path": ..., "content": ...}` in the JSON body,
> so every save it made had NO path. `validate_path('')` resolved to the
> docroot, and `write_file_checked` then opened `<docroot>.<pid>.tmp`. That file
> sits in the docroot's PARENT [...] which www-data cannot write: the EACCES.
> The audit's target "/" on every failure was the clue, and I misread it.
>
> **A `save` with no path does not refuse; it tries to write the docroot.** [...]
> It should answer `missing-parameter: path is required (in the query)` [...] A
> body-supplied `path` that is ignored deserves the same named refusal.

Read from the code before the correction arrived, it agreed: an absent query
`path` became `'/'` (`$path = $params{path} // '/'`), `save` declares its path
`in => 'query'` only, so a body `path` was never read, and nothing in
`action_save` stopped a directory being the write target. Every CGI surface
(manager API, DAV, MCP) runs as the same user; the pool's front door relays
each one the same way. The error itself named no file, folder or identity, and
its `check --fix` hint pointed at a repair that could not help.

# What shipped

- **A `path` in the body of an action that reads it from the query** is refused,
  for every action whose declaration says `path` is `in => 'query'`:
  `missing-parameter`, "path was sent in the body; save reads it from the query
  string (?action=save&path=/x.md, not '/x.md' in the JSON body). Nothing was
  changed." The audit row's target is the path the body carried. Done for
  `path` only: no handler of a query-declared `path` reads the body's, while
  some handlers do fall back to the body for other parameters (`host`), so a
  rule for every query-declared parameter would break clients that work.
- **A content write (`content_write`: save, delete, mkdir, move, copy,
  lock, unlock, renew-lock, migrate-to-local) with no path, or an empty one**,
  is `missing-parameter`: "path is required (in the query)", audited with the
  detail `missing-parameter: path is required (in the query)`. An explicit `/`
  still reaches the handler, where an upload into the root folder means it.
- **A folder is never what a save writes.** `action_save` and
  `action_save_binary` refuse a target that is a directory, the site root
  included, by name (`is-a-folder`), before anything is created - for MCP and
  the control API as well as the manager.
- **The site root is never what a delete, move or copy takes** (`site-root`).
- **A permission failure says who tried to write where.** When
  `write_file_checked` cannot create its temp file (EACCES/EPERM) the error
  names the file, its folder site-relative (`'/blog'`, `lazysite/...`, the
  private store's twin, or "a folder outside the site" - never a host path), the
  user and group the process writes as, the folder's owner, group and mode, and
  which class of the mode refuses: "Cannot write file: Permission denied
  creating 'a.md.1234.tmp' in '/locked' as www-data:www-data; the folder is
  ispadmin:www-data 0555 - it is not writable by its group (run: lazysite check
  --fix)". The `check --fix` hint is given only when the mode refuses and the
  folder is in the site; when the mode allows the write the sentence says the
  refusal is not the mode. The same facts, with the absolute path, are logged at
  ERROR.

Tested by `t/unit/manager/348-a-failed-save-names-who-and-where.t`, which fails
against each of the three changed files restored from main.
