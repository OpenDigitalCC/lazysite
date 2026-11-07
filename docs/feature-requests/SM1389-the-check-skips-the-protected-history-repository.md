---
id: SM1389
title: "SM1389: the check's stray-copy walk skips the protected-history repository"
subtitle: "lazysite check reported the protected folders' history repository as public copies of protected files, because its files share paths with the docroot's content-history repository, and called the site not serviceable. The walk skips that repository and nothing else."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "the lazysite developer agent (the 0.16.6 edge deploy's check report)"
area: check
status-note: "SHIPPED (0.16.7) on n764: report_stray_public prunes ProtectedHistory::_git_dir_in(<store>); a moved layout's copy is still reported. t/tools/04."
---

# What happened

`tools/lazysite-check.pl`'s `report_stray_public` walks the whole private store
and reports every relative path that also exists in the docroot, as a FAIL: a
protected file with a public copy the front end could serve. Since SM1324
(0.16.5) the store holds the protected folders' history, a second git repository
at `<store>/lazysite/git` (`Lazysite::ProtectedHistory`). Its `HEAD`, `config`,
`description`, `info/exclude`, `refs/heads/main`, `logs/HEAD` and any object
identical to one in the docroot's content-history repository at `lazysite/git`
share those relative paths, so a site with both reported them all, and the 0.16.6
edge deploy called the site NOT SERVICEABLE.

# What shipped

The walk prunes the history repository, found by `ProtectedHistory::_git_dir_in`,
the module's own helper, so the two cannot drift. A comment says why: the
repository is the engine's, never moved content.

**Only the repository, not all of `<store>/lazysite/`.** The brief proposed
pruning the store's whole engine directory. Measured first
(`tmp/n764-layout-move-probe.pl`): a rule on `lazysite/layouts/<layout>`, a path
the file surfaces write, moves the layout into `<store>/lazysite/layouts/`. That is
content, and a copy left in the docroot beside it is a stray copy, so pruning the
whole directory would hide it. The narrower prune hides nothing a rule can move.

# Tests

t/tools/04: with both repositories present (HEAD, config, description,
info/exclude, refs/heads/main, logs/HEAD and an object at the same paths) the check
prints the OK line and reports no stray copy; with a layout in the store's
`lazysite/layouts` and a copy in the docroot, that copy is reported and the
repository is not. With lazysite-check.pl as on main the first assertion fails.
