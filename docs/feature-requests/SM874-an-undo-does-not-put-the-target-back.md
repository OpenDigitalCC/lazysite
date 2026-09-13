---
id: SM874
title: "SM874: the apply's safety snapshot covers the wrong site, and undoing an apply cannot remove what it added"
subtitle: "1315S-03, tier A. SM412 gave action_backup_create a `root` because the apply's snapshot 'used to tar the whole docroot whatever the target' - then fixed it inside apply_and_configure. The control API passes `snapshot => 0` to opt out of that path and takes its own, unscoped. And a restore is an overlay, so an apply that ADDS files cannot be undone by one, while the undo bar promises it can."
brand: plain
status: shipped
raised: 2026-09-12
raised-by: site agent (1315S-03, tier A manual check)
area: backups, site-packages, control-api
---

# What was found

The site agent, walking the tier-A check that gates STABLE, applied a package to
a second domain and confirmed the undo through every dialog:

> "After completing all three steps, the target is unchanged. [...] edge2's
> content root now holds [the primary's directories]. Every prerestore snapshot
> is **16.6 MB**. edge2 is a small site. A 16.6 MB 'pre-apply snapshot' is the
> wrong size to be a snapshot of edge2."

They marked the inference as inference and asked for a minute of code reading.
The inference was right, and there are **two** defects behind it.

# 1. The apply's safety snapshot is unscoped, on the one surface a person clicks

`lazysite-manager-api.pl`, in `action_site_backup_apply`, resolved the target
content root twenty lines earlier and then took:

```perl
my $safety = action_backup_create('prerestore');   # no root
```

**SM412 built the `root` parameter for exactly this.** Its own comment:

> "The safety snapshot before a site-package apply used to tar the whole docroot
> whatever the target - so on a multi-domain instance, applying to a
> content-rooted domain (sites/edge2) tried to read the PRIMARY domain's tree."

SM412 fixed it inside `apply_and_configure`. But this surface passes
`snapshot => 0` to opt **out** of the shared path, and substituted its own
unscoped call. So the defect SM412 removed from the library stayed alive on the
control API, which is the surface the manager UI uses.

Reproduced (`tmp/repro-sm874-apply-undo.pl`): a two-domain fixture where the
snapshot came back with **12 members, 3 under the target and 5 of the primary's
own pages**. Scoped, it is 3 members and none of the primary's.

## Why four releases of tests did not see it

- `t/unit/manager/61` is SM412's test. It drives `apply_and_configure` - the
  **library**, where the fix works and always did.
- `t/unit/manager/59` checked the control API by matching
  `action_backup_create\('prerestore'\)` **in the source**, asserting *"and that
  is what it took"*. It proved the call existed. It could not see what the call
  covered.

A regex over a caller is not a test of the caller. The assertion has been
rewritten to require the scope, and the behaviour is now driven in
`t/unit/manager/62` against a real two-domain fixture.

# 2. A restore is an overlay, so an undo cannot undo an apply

`action_backup_restore` writes the archive's files over the site and removes
nothing. `apply_and_configure` has a `clean` option; the restore had no
equivalent. So:

```
apply    → target gains about.md, index.md is replaced
undo     → index.md reverts to the original   ✓
           about.md is still there            ✗
```

The undo bar's dialog said *"This puts the site back as it was immediately
before the apply."* That is false the moment a package adds a file. **The field
apply added 241 files.**

# The fix

**`root => $croot`** on the control API's snapshot, and **`replace => 1`** on
the undo path - which clears the target folder before writing the snapshot back.

Deletion is why `replace` is opt-in and narrowly guarded:

- **only within the archive's own scope**, the common directory
  `_archive_scope` already computes for the safety snapshot;
- **refused outright when there is no scope.** A primary-site archive has no
  single common directory, so "clear first" would mean clearing the docroot.
  That is the case this must never guess - [[SM306]] took a site private by
  acting on an absent path, and the lesson recorded then was to refuse;
- the safety snapshot is taken **before** the clear, and covers the same scope,
  so the deletion is itself reversible;
- the directory itself is kept, only its contents go, so ownership and the
  setgid bit that lets the CGI write there survive.

The four states are shown side by side in `tmp/sm874-before-after.sh`: as
shipped, fix 1 alone (scoped snapshot, undo still leaves the added file), both
fixes (target exactly as it was), and the refusal.

## And the three dialogs became one accurate one

`undoApply` confirmed, then called `restoreBackup`, which confirmed again - and
the two now say different things, because an undo replaces and a restore
overlays. The agent's first two attempts read as *"undo does nothing"* precisely
because they had answered part of a chain. Two confirmations that contradict
each other are worse than one that is accurate, so the undo defers to the
restore's, which is written for the mode it is passed.

The generic restore wording was also wrong on its own terms: it promised
*"newer files stay"*, and no newer-file logic exists anywhere in the restore.
It now says what it does - files of the same name are replaced, files not in the
snapshot are left alone.

# What is NOT established

The agent's instance showed the target **entirely** unchanged, with the
primary's files in its content root. The reproduction here shows a *partial*
undo - the changed file reverted, the added file stayed - because the unscoped
snapshot happened to contain the target subtree too. Those are different
outcomes and the difference is not explained by anything in this filing.

Both defects above are real, reproduced and fixed. Whether they are the whole of
what the agent saw wants the instance, not this repository. **1315S-03 should be
re-walked on the beta that carries this fix** rather than marked closed on the
strength of a local reproduction.

# Related

[[SM412]] (the scope, built and not wired to this caller), [[SM769]] (backups
had never worked on the Hestia layout - the reason this ref was ranked as the
one with most to go wrong), [[SM306]] (refuse rather than guess at an absent
path), [[feedback_verify_the_gate_tests_what_you_think]],
[[feedback_a_declaration_the_code_ignores]].
