---
title: "SM659: three kinds of principal share two ambiguous words, and first run creates a role account called `manager` with a password to hand over"
subtitle: "Operator, 2026-08-27: 'sysop is a group, the actual user should have named account, rather than role, otherwise people end up with shared passwords for a role account'"
brand: plain
standard-margins: true
status: partial
status-note: "PARTIAL - the three structural parts are BUILT and the vocabulary sweep is done where a person meets it; the internal prose is staged. BUILT: (1) a CLI actor is `system:<unix name>`, which fixes a real collision - account names are stripped to [a-zA-Z0-9_.-], so a lazysite account called `sysadmin` and the Unix user `sysadmin` were the SAME STRING in the actor column, and because that string IS an account, SM641's reader rendered it as a live link to that person. `:` can never appear in an account name, so the prefix makes it unresolvable BY CONSTRUCTION and SM641 plain-texts it with no further work. lazysite-site.pl had the same collision and is fixed too. (2) lazysite-admins renames to `sysops` in place on upgrade, carrying members, capability rows, grantable and nesting; a site that already has a `sysops` group is left alone rather than merged into. NO LOCKOUT RISK - manager access is decided by FLAGS, and the old name appeared in exactly one functional place. (3) `setup-sysop` replaces setup-manager with NO ALIAS, requires --user, and defaults to --link so no password is handed over; a positional password opts out. Re-running makes another sysop, so there is no first-user special case. THE SWEEP: 410 occurrences rewritten inside STRING LITERALS (what a person reads) plus the `local` identity messages corrected to sysadmin, ten operational documents repointed, and 25 test fixtures updated. STAGED, and deliberately: 322 code comments and ~2,079 documentation uses. Those need reading one at a time - `operator` genuinely means sysadmin in some (\"there is no session behind a shell\") and sysop in others - and a batch replace would encode the wrong principal in an unknown fraction of the security documentation. The internal `_operator()` function name is left with them. KNOWN EDGE: after the rename, `group-add X lazysite-admins` creates a fresh powerless group of the old name rather than failing. Redirecting it silently would mask a real mistake; refusing it would break a site that deliberately makes that group. Watch for \"I added them to the admin group and nothing happened\". Three sabotages, all fail."
---

# The three principals

| Principal | How it appears in the trail | Inside the capability model? |
|---|---|---|
| A lazysite account with full capabilities, via UI/API | its username | **yes** - gated, ceilinged, audited |
| A Unix account running the CLI | `root`, `sysadmin`, whoever | **no** - exempt by construction |
| Nobody | `system` | n/a |

The second is not a more privileged version of the first. It is a different
kind of thing: `_may_confer` and `_exceeds_authority` both return early for
`local`, so the CLI is outside the model rather than at the top of it. Calling
both "the operator" is what made that invisible.

**The vocabulary, settled:**

- **sysadmin** - has a shell, runs the CLI, exempt from the capability model.
- **sysop** - a lazysite account with full capabilities. A **group** with named
  members, never a role account.
- **manager** - the UI surface. Never a person.
- **operator**, **admin** - retired.

# Part 1: the actor column collides, and SM641 would link it

`cli_audit` writes the bare Unix name:

    my $who = getpwuid($<) // "uid:$<";
    audit_log( $who, $act, $target, '', 'ok', 'cli', $detail );

Account names are stripped to `[a-zA-Z0-9_.-]`. So a lazysite account named
`sysadmin` and the Unix user `sysadmin` are **the same string in the actor
column** - and because that string *is* an account, SM641's reader renders it
as a live link to that person's user page. CLI activity attributed to a named
app user, clickable, on the Users page.

`system:` fixes it **by construction rather than by convention**: `:` can never
appear in an account name, so `system:root` is unresolvable and SM641's reader
renders it as plain text with no further work. The two changes meet exactly.

There is precedent: `local` is already reserved, with the refusal *"'local' is
reserved - it is the operator identity, not an account."* (That message is
itself one of the sweep below, and it means **sysadmin**.)

# Part 2: first run creates a role account

`cmd_setup_manager`:

    $user = 'manager' unless defined $user && length $user;

Out of the box, first run creates an account literally named `manager`, with
the password as a positional argument. That is a shared-secret role account, as
the default path - and the two good paths already exist without being the
default: `--user` names a person, and `--link` issues a single-use self-service
claim so **there is no password to hand over at all**.

**`setup-sysop` replaces it.** A username is required. `--link` is the default.
No alias is kept: the old name would only teach the old way.

# Part 3: a deployed site with no accounts is a valid state

This is what makes requiring a username safe, and it is the operator's ruling.

Deployment and first user are **separate steps**. A site can be deployed with
no accounts and sit there, correctly, until somebody is ready to collect a
registration link. That is not a half-built site; it is a site with no
principals, which is a coherent security posture rather than a fault.

So `setup-sysop` does not have to run at deploy time, and it must not be made
to. It runs when the person is ready to register.

It is also **re-runnable**: a second run with a different name creates another
sysop. There is no first-user special case, which is what stops the first
account being architecturally different from the second.

Nothing in `lazysite check` currently reports "no users" as a fault, so this
state is already tolerated - it simply has not been stated as intended.

# Part 4: the sweep

`operator` appears about 2,861 times and means sysadmin in some places and
sysop in others. It retires, each use read and replaced with whichever
principal it meant.

Staged separately from the parts above, because it is judgement work rather
than a change of behaviour, and because the parts above should not wait for it.

The rename also reaches operational documentation - `installers/hestia/INSTALL-RUNBOOK.md`,
`README.md`, `SECURITY.md`, `docs/IMPLEMENTOR.md` and the starter briefings all
name `setup-manager`. Dated review documents and the CHANGELOG are historical
records and are left alone.

# The group rename

`lazysite-admins` becomes `sysops`, migrated automatically on upgrade, carrying
members, capability rows and grantable set.

**This carries no lockout risk**, which is not obvious and was worth checking:
manager access is decided by flags, not by group name -

    return 1 if $cfg->{ui} || $cfg->{manage_users} || $cfg->{manager};

`lazysite-admins` appears in exactly one functional place, a default when no
group is named at setup. Everything else is prose.

# Why one filing

Renaming the group without fixing the role account leaves an account called
`manager` sitting in the `sysops` group. Fixing the CLI actor without the
vocabulary leaves the trail using words the documentation does not. Requiring a
username without declaring the zero-account state valid turns a deploy into a
blocking prompt.

The parts are one change with four faces.
