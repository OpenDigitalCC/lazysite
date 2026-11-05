---
id: SM1324
title: "SM1324: a protected folder keeps history by choice"
subtitle: "Protected content was kept out of the content history by design. A folder rule may now carry history: true, and the folder's versions are kept in a second repository in the private store, read under the folder's own rule."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-04
raised-by: "the release manager, ruling 50 (Q5, T-16), on a protected agent-first intranet's gap G5"
area: access
status-note: "SHIPPED (PENDING) on n743: `history` on a folder rule, on every surface that sets the rule, covering nested rules unless one says false; a second repository at <store>/lazysite/git; the history readers apply the file's read rule and restore its write rule; the operator deletes a folder's history with `lazysite acl purge-history` (rulings 98-100). t/unit/manager/420."
---

# What was asked

Ruling 50 (2026-11-04): history for each protected folder, opt-in. Set by an operator or
the folder rule's owner, through the surfaces that set the folder's access rule. The store
is private, outside the served tree, with the protection of the content. History reads
apply the folder's rule, so history never widens who may read. Off by default.

[[SM683]] laid out the design in 2026-08: a second repository beside the private store,
never a second work tree of the public one, and the summary closed to the read rule first
(done in 0.11.6).

# What shipped

`history` on a folder rule
: A boolean on the rule, read as `draft` is: absent leaves it as it is, an unrecognised
  value is refused (`kind: invalid`, `field: history`). Set through `Files::action_acl_set`,
  which every surface calls, so the owner check there decides who may set it: the operator,
  or the rule's owner. Refused on the site-wide rule (it moves nothing into the store) and
  on a path that is not a folder.

The surfaces
: the manager's protected-section panel (Keep history / Stop keeping history); the control
  API's `acl-set` (`history` in the body, declared; also in the list form); MCP
  `set_permissions` (`history`, boolean); `lazysite acl set --history` / `--no-history`, and
  `show` says so. The audit line of an `acl-set` names `history` when the rule carries it.

The repository
: `Lazysite::ProtectedHistory`. The work tree is the private store and the git dir is
  `<store>/lazysite/git`: outside the served tree, 02770 as the store is, at the engine's
  reserved name, which no content path can take. Its own object store. It is created the
  first time a folder keeps history, with an empty first commit; nothing is adopted. Only
  paths a history rule covers are ever staged.

Recording
: `Lazysite::Git::commit_paths` and `commit_move` record, once, for every write hook (the
  manager, WebDAV, MCP, uploads, restores): a path is kept when the site's content history
  is enabled, a rule moves it into the store, and the nearest rule that SAYS `history`
  says true. So a folder's `history: true` covers the rules nested in it, a nested rule's
  explicit `history: false` takes its path out, and a rule that says nothing inherits
  (ruling 100). False is stored, and a rewrite that omits the field keeps it. A move within kept folders carries the rename trailer, so history follows the
  file. Setting the flag records the folder's current content as its first version.
  Clearing it, or removing the rule, stops recording and keeps what was recorded.

Deleting it (ruling 99)
: `lazysite acl purge-history PATH --actor USER`. The operator only (`local`, or an account
  in the operator group: `Acl::file_rule_bypass`, the manager's own test); anyone else is
  refused. Audited as `history-purge` on origin `cli`, refused or done, naming the actor and
  how many versions went. `ProtectedHistory::purge` replays every commit on a scratch index
  with the folder taken out (authors, dates and messages kept, a commit left empty dropped),
  then expires the reflog and prunes, so the bytes leave the object store. The rule and the
  files are not touched. It is an `acl` sub-command, the nearest existing shape to the
  `lazysite history purge` the ruling suggested: `acl` is where history is set, and it
  needs no new top-level verb.

Reading
: `git-history` / `list_versions`, `git-show` / `view_version`, `git-restore` /
  `restore_version` read the private repository for a file in the store. They already
  resolved their target through `_git_target`, which applies the file's read rule; a
  restore goes through `action_save`, which applies the write rule. A kept file answers
  `versioned: true` and `history_kept_by`; one that is not says how to keep it. The
  overview (`git-history-summary`, `list_content_history`) adds the private repository's
  files before its read-rule filter. MCP `list_content_history` gave the filter no caller,
  so it hid every protected file from everyone; it now passes the caller.

# Rulings

- 98: the site's content history must be on as well. A site that pauses its history
  pauses this one too.
- 99: clearing the flag or removing the rule keeps the recorded versions (still read under
  the folder's rule); the operator deletes them with `purge-history`.
- 100: a folder's `history` covers nested rules unless one says `history: false`.
- 101: the public repository's pre-protection versions are left (a separate candidate).

# Not done

- The public repository's versions of a file from before its folder was protected stay
  where they are ([[SM683]]'s third step).
- A backup restore (`commit_all`) records nothing in the private repository.
- `lazysite check` does not probe the private repository's health or permissions.

# Tests

- **t/unit/manager/420** (new). Off: a protected folder keeps no history and no private
  repository is made. On: the repository is outside the document root, 02770, holds the
  first version and the edit, and the public one holds none of the edit. A non-reader
  cannot list, view or restore, and the overview leaves the file out; a reader without
  write cannot restore, and a writer's restore is the newest version. A folder only; the
  site-wide rule and an unrecognised value are refused. A protected folder beside a kept
  one keeps nothing. Clearing it keeps the first version. `lazysite acl set --history`.
  A nested rule that says nothing inherits; one that says false - a folder's, or a page's
  stem rule - is kept out, from the first version on (the first version asks each file the
  rule lookup the recording asks, never a path prefix), and keeps its false through a rewrite. Removing the rule keeps the history;
  `purge-history` refuses a manager who is not the operator (audited, nothing deleted), and
  for an operator account and `local` deletes it from the log and the object store, audited,
  leaving the file.

Sabotaged one at a time, each fails the test: no recording hook; reading the public
repository; no read rule on the history readers; no read-rule filter on the overview; no
private files in the overview; `history` accepted on any path; the flag ignored; the flag
not read from the request; inheritance ignored; false not stored; false not excluded from
the first version (and the prefix-matched first version, which missed a stem rule); the operator check; the purge's audit row; the object-store prune.
