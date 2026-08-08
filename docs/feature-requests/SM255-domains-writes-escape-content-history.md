---
title: "SM255 - Domain writes escape content history, and the guarantee cannot see them"
subtitle: "config-set commits lazysite.conf; domain-set writes the same file and commits nothing. The write-path guarantee does not scan Manager::Domains, so neither the omission nor a future one fails the build."
brand: plain
status: candidate
status-note: "Found 2026-08-08 while repairing a stale entry in the git-guarantee registry after SM238 moved a function. Predates that work - Manager::Domains has NEVER been in the scanner's module list. Two questions, one mechanical and one a real decision: extending the scanner is easy, deciding whether domain configuration belongs in content history is not."
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

## The decision underneath

Extending the scanner is mechanical. Deciding what the domain writes *should* do
is not, and the answer is not obvious:

**They should commit.** `lazysite.conf` is declared versioned, the file is the
same file, and an operator asking "when did this domain's content root change?"
has nowhere else to look. Domain configuration is exactly the kind of change
whose history matters after an incident.

**They should not.** Content history is for *content*, and the argument that
`config-set` commits is an argument about one key at a time, not about bulk
domain registration. A `site_apply` already commits the content it writes
(SM158); domain registration might reasonably be audit-trail work rather than
content-history work - and the audit trail does already record these actions.

The second reading is weaker than it first appears, because the audit trail
records *that* a change happened and content history records *what changed*. For
a conf file they are not substitutes. But it is a real position and it should be
argued rather than assumed.

## What to do

1. **Answer the question above**, and record the answer in the registry as either
   a hook or an exemption with its reason - the registry's exemption entries are
   the right place for "domain config is deliberately not versioned, because …".

2. **Extend the guarantee to cover `Manager::Domains`.** The scanner keys on
   `^action_`, and these subs are named `domain_*`, so it needs a per-module
   pattern rather than one shared regex. Worth checking at the same time whether
   any other module escapes for the same reason.

3. **If they should commit**, they should commit *once* per operation. `domain_add`
   writes several keys through repeated `_set_line`/`_write` calls; a commit per
   key would produce a misleading history of a single act.

## Verification

- Every write path in `Manager::Domains` is classified in the guarantee registry.
- Adding a new one without classifying it fails the build.
- If hooked: registering a domain produces exactly one content-history entry, and
  the conf change is visible in it.
- If exempt: the reason is recorded, and `config-set`'s differing behaviour on the
  same file is explained rather than left as an inconsistency.
- No other module is missing from the scanner for the same reason.

## Not in scope

- Changing what `config-set` does. It is the behaviour the others are being
  measured against.
- The audit trail, which already records these actions and is a different
  guarantee (`t/unit/lib/16-audit-guarantee.t`).
