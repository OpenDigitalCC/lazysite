---
title: "SM255 - Domain writes escape content history, and the guarantee cannot see them"
subtitle: "config-set commits lazysite.conf; domain-set writes the same file and commits nothing. The write-path guarantee does not scan Manager::Domains, so neither the omission nor a future one fails the build."
brand: plain
status: candidate
status-note: "DECIDED 2026-08-08 by the operator: any write to lazysite.conf must use the same mechanism whatever its source, because the distinction is invisible to the person the history is for - so the commit belongs INSIDE one unified write path, not at each caller. Not yet built. Found 2026-08-08 while repairing a stale entry in the git-guarantee registry after SM238 moved a function. Predates that work - Manager::Domains has NEVER been in the scanner's module list. Two questions, one mechanical and one a real decision: extending the scanner is easy, deciding whether domain configuration belongs in content history is not."
---

# SM255 - domain writes escape content history

## Why

`lazysite/lazysite.conf` is one of the two versioned config files. The control
API's `config-set` says so explicitly and commits:

```perl
log_event( 'INFO', 'config-set', 'config key set', ... );
# SM085: lazysite.conf is one of the two versioned config files.
require Lazysite::Git;
Lazysite::Git::commit_paths( $DOCROOT, $auth_user,
    'edit lazysite/lazysite.conf', 'lazysite/lazysite.conf' );
```

`Lazysite::Manager::Domains` writes the same file - `domain_add`, `domain_set`
and `domain_remove` all rewrite `lazysite.conf` through its own `_write` - and
contains **no reference to `Lazysite::Git` at all**.

So registering a domain, repointing its content root, or changing its layout,
theme or access groups leaves no entry in content history, while changing an
unrelated key through `config-set` does. Same file, two behaviours, and nothing
records which was intended.

## Why it was never caught

`t/unit/lib/18-git-guarantee.t` exists precisely so that a new write path cannot
be added without being classified as hooked or exempt-with-a-reason. Its scanner
walks `^action_` subs in seven modules:

```
Files  Upload  Backups  Plugins  Layouts  Themes  Sessions
```

**`Domains.pm` is not among them**, and its subs are not named `action_*`. So the
guarantee has never seen the domain write paths, and adding another one today
would still not fail the build. The guard's coverage silently stops at a module
boundary.

That is the more important half of this request. A guarantee that does not cover
a surface is worse than an absent one, because the green build is read as
assurance.

## The decision, taken 2026-08-08

The operator's answer reframes the question, and is better than the way it was
put:

> A user won't distinguish - so they should behave the same. Any write to the
> conf file should use the same mechanism, irrespective of the source of the
> write.

That is not "should domain writes commit?" but "why are there two mechanisms
writing one file?" The commit is a property of **writing lazysite.conf**, not a
property of the action that happened to do it. An operator does not know or care
whether a change arrived through `config-set`, `domain-set` or the CLI; they know
the file changed, and it should be recorded once, the same way, every time.

So the target is **one write path for `lazysite.conf`**, and the commit belongs
inside it rather than at each caller. `Manager::Common::_write_conf_key` is the
existing candidate; `Domains::_write` is the divergent one. Whichever survives,
the rule is that no caller commits and no caller may skip committing, because
neither is a decision a caller should be making.

That also disposes of the "should not" argument recorded earlier: it turned on
domain registration being a different KIND of act from a config edit, and the
operator's point is that the distinction is invisible to the person the history
is for.

## What to do

1. **Unify the conf write.** One function writes `lazysite.conf`, commits it, and
   every caller - `config-set`, the domain verbs, the CLI - goes through it.
   `Domains::_write` rewrites the whole file while `_write_conf_key` sets one
   key, so the unified path needs both shapes; that is a refactor, not a
   one-line move, and it is the substance of this request.

2. **Extend the guarantee to cover `Manager::Domains`.** The scanner keys on
   `^action_`, and these subs are named `domain_*`, so it needs a per-module
   pattern rather than one shared regex. Worth checking at the same time whether
   any other module escapes for the same reason.

3. **Commit once per operation, not once per key.** `domain_add` writes several
   keys through repeated `_set_line`/`_write` calls. With the commit inside the
   write path that becomes a real risk - a single registration would produce
   several history entries and read as several acts. The unified path needs a way
   to batch, or the domain verbs need to compose one write.

## Verification

- Every write path in `Manager::Domains` is classified in the guarantee registry.
- Adding a new one without classifying it fails the build.
- Registering a domain produces exactly ONE content-history entry, and the conf
  change is visible in it.
- A `config-set` and a `domain-set` produce the same kind of entry - an operator
  reading the history cannot tell which surface made the change, because it does
  not matter to them.
- No caller of the conf write decides whether to commit.
- No other module is missing from the scanner for the same reason.

## Not in scope

- Changing what `config-set` does. It is the behaviour the others are being
  measured against.
- The audit trail, which already records these actions and is a different
  guarantee (`t/unit/lib/16-audit-guarantee.t`).
