---
id: SM892
title: "SM892: the restart is in a path the documentation does not name, and there was almost nothing to restart"
subtitle: "V3 could not be walked, and finding out why produced two facts that undercut N142A's reasoning: the published tarball upgrade is install.sh, which names no unit and prints no restart line - and on the operator's host 28 of 29 runtime units are dead and no pool unit exists at all. Needs a ruling before anything is built."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-15
raised-by: sites agent
area: installers
status-note: "SHIPPED, AND THE OPEN QUESTION IS ANSWERED BY THE OPERATOR'S READINGS, 2026-09-21. The ruling (U1/U2/U3, D1-D5) is built: `provision`, `upgrade`, `reinstall` in the `lazysite` CLI, one way on both distributions, install.pl takes --mode and refuses to choose, install.sh is a signpost, nineteen readers repointed and held by t/lint/149, plus `backups`, `channel`, `policy` and --dry-run so no document reaches past the CLI. THE SEVEN SITES: the persistent-worker explanation is ELIMINATED by measurement. `lazysited@<site>.service` is fired by a `.timer` (29 timers active/waiting), runs for ONE SECOND and exits cleanly - dhcf.eu: ActiveEnter 12:06:07, InactiveEnter 12:06:08, Result=success, NRestarts=0 - so 'dead' means idle between ticks, every tick loads the engine fresh, and it is not in the request path. No `lazysite@` pool unit exists on the host, so every site serves by CGI, which reads the engine per request. Nothing on that host could hold old engine code across an upgrade, which is why N142A had nothing to restart AND why restarting would have changed nothing. The only mechanism left in the tree is a cached render outliving its engine - SM886, shipped in 0.14.2 - and its prediction (all stragglers current in one monitor tick) is what was observed. Recorded as established by elimination with the prediction matched, not as a directly observed cause. SM891 is consistent: no crash loop (Result=success, NRestarts=0). ONE NOTE FOR LATER, no code change pre-cut: the restart notice in `upgrade`/`reinstall` guards on `is-active lazysited@`, which a timer-fired job is for one second per tick, so on this estate it will almost never print for that unit - correctly, since there is nothing to restart. The pool unit is the one that matters and none run. The wording 'this site keeps engine code between requests' is true of the pool only."
---

# Why V3 could not be walked

The 0.14.2 test plan asked what `lazysite upgrade --docroot ...` prints when it
cannot restart. The sites agent could not run it, and the reason is the finding:

**The published install page documents a different command.** For a tarball
install, lazysite.io/docs/install says:

```bash
sudo bash install.sh --docroot /path/to/public_html --cgibin /path/to/cgi-bin
```

Counted on the page as read on 2026-09-15: `lazysite upgrade` appears **zero**
times, `systemctl` **zero** times.

So V3 cannot be run from the documentation. It can only be run by someone who
already knows the command exists.

# What the documented path actually printed

The operator ran it on edge.explore — the one site whose runtime unit is live,
and therefore the only site where N142A's restart guard can pass at all:

```text
Installer: lazysite 0.14.2
Mode: reinstall
  ownership: repaired 2 root-owned path(s) under lazysite/
=== Install summary (reinstall) ===
  Overwrote:  261
  Preserved:  2 (operator-edited)
Next steps:
  1. Create the first account. ...
```

No unit named, no restart line, no reminder. The install summary's "Next steps"
tell a fresh operator to create an account and install a theme — on a
**reinstall** of a running site.

# This is the third time

| Release | Where the restart went | What the estate actually runs |
| --- | --- | --- |
| 0.14.1 | the Hestia deploy script | INSTALL-RUNBOOK marks it superseded by the packages |
| 0.14.2 | `lazysite upgrade` ([[N142A]]) | the documented tarball path is `install.sh` |
| — | `install.sh` | not yet |

Each fix was correct about *what* to do and wrong about *where*. Writing it a
third time without settling the question would be the same mistake with a new
number.

# And there was almost nothing to restart

The operator's listing, quoted:

```text
systemctl list-units --type=service --all --no-pager 'lazysite*'
  lazysited@edge.explore.lazysite.io.service   loaded active   running
  lazysited@<28 other domains>.service         loaded inactive dead
  29 loaded units listed.
```

- **One** `lazysited@` is active. The other 28 — including all seven sites that
  read older code from a fresh 404 on 0.14.1 — are `inactive dead`.
- **No `lazysite@` pool unit appears at all.** The glob would have matched any
  name starting `lazysite`.

N142A restarts both units, guarded on the unit being active. On this host that
guard passed for **one** site, and for **none** of the seven stragglers.

## What that does to the 0.14.2 story

The estate did come current — all twenty sites, both measures, confirmed. But
**N142A cannot be what did it for the seven**, because it had nothing to act on.

[[SM886]] is the candidate: a render is no longer served once the engine that
produced it is not the installed one, and a CGI request reads the engine fresh
every time. That is consistent with the six-to-zero stale count in one monitor
tick. **It is not established**, and this filing does not claim it.

Two readings would settle it, both read-only and both the operator's:

```bash
systemctl show -p ActiveEnterTimestamp,InactiveEnterTimestamp,Result,NRestarts \
    lazysited@dhcf.eu.service
systemctl list-units --all --no-pager 'lazysite*'
```

The first says whether those units ran recently and why they stopped. The second
says whether a socket or timer starts them on demand — in which case "dead" is
*idle*, not *never ran*, and the whole reading changes.

## The readings, taken 2026-09-21 — and it is the second case

```text
$ systemctl show -p ActiveEnterTimestamp,InactiveEnterTimestamp,Result,NRestarts \
      lazysited@dhcf.eu.service
Result=success
NRestarts=0
ActiveEnterTimestamp=Mon 2026-09-21 12:06:07 BST
InactiveEnterTimestamp=Mon 2026-09-21 12:06:08 BST

$ systemctl list-units --all --no-pager 'lazysite*'
  lazysited@<29 domains>.service   loaded inactive dead      (edge.explore: active running)
  lazysited@<29 domains>.timer     loaded active   waiting   (edge.explore: active running)
  58 loaded units listed.
```

| What the reading says | What it settles |
| --- | --- |
| Every `.service` has a `.timer`, and every timer is active | `lazysited@` is **timer-fired**. "dead" is idle between ticks. |
| dhcf.eu ran from 12:06:07 to 12:06:08, `Result=success`, `NRestarts=0` | One tick, one second, clean exit — **today**. It has been running all along. |
| Each tick is a fresh process | It **cannot hold old engine code** across an upgrade for longer than one tick, and it is not in the request path in any case. |
| No `lazysite@` pool unit exists under the glob | Every site serves by **CGI**, which reads the engine per request. |
| `Result=success`, `NRestarts=0` | No crash loop — [[SM891]]'s never-in-force rate limit was not masking one. |

**So nothing on that host could hold old engine code across an upgrade.**
That is why N142A had nothing to restart, *and* why restarting would have
changed nothing for the seven. The persistent-worker explanation is eliminated
by measurement, not by reasoning.

What is left in the tree is one mechanism: a cached render outliving the engine
that produced it — [[SM886]], shipped in 0.14.2 (`40fdfa5f`). Its prediction is
that every straggler comes current in one monitor tick, and that is what the
0.14.2 walk observed (six to zero in one tick). Recorded as **established by
elimination, with the prediction matched** — not as a cause observed directly,
because the stale renders themselves were never captured.

**One note for later, and no code changes before the cut.** The restart notice
in `upgrade` and `reinstall` guards on `is-active lazysited@<site>`, which a
timer-fired job is for one second per tick — so on this estate it will almost
never print for that unit. That is correct: there is nothing to restart. The
pool unit is the one that holds code between requests, and none runs. The
sentence *"this site keeps engine code between requests"* is true of the pool
only, and `t/tools/78` already records that the check cannot prove a restart
on a real host.

**[[SM891]] is relevant and is not an answer.** The start-rate limit in that unit
was in the wrong section and has never been in force, so a failing runtime was
retried every five seconds rather than giving up. That is a different state from
dead, and whether the two are connected is exactly what the readings above
decide.

# THE RULING, 2026-09-15

I put three options to the release manager and **all three were refused**,
because all three kept install and upgrade as one command that decides for
itself which it is doing. What was asked for instead:

> One place for install, and another for upgrade, because they should be
> purposefully chosen. Then all docs and scripts refer to the one way to do
> each.

| Ref | Requirement |
| --- | --- |
| U1 | **Install and upgrade are different commands.** Not one command with a mode, not two commands that both do both. |
| U2 | The operator **chooses** which they are doing. The command does not infer it from the state of the disk. |
| U3 | **Every doc and every script names the one way** to do each. No second spelling anywhere. |

## Why the options I offered were all wrong

Each of R1, R2 and R3 above answered "which command should carry the restart",
and took for granted that one command handles both intents. That is the thing
being objected to.

**Today `install.sh` decides for you.** It reads the install state and picks
`fresh`, `reinstall` or `upgrade`, then behaves accordingly. An operator runs
the same words whether they mean *set this site up* or *move this site
forward*, and finds out afterwards which one happened.

The V3 walk shows what that costs. The operator ran the documented command on a
**running** site and the summary told them:

> Next steps: 1. Create the first account. A fresh install has NO accounts …

That is not a wording defect. It is one command wearing two hats and choosing
the wrong one to speak from — and nothing in the output said "this was an
upgrade of a live site" because the command never had to be told that is what
the operator meant.

## What this settles, and what it opens

**Settled:** the restart does not go in a third place. It goes in *upgrade*,
wherever upgrade ends up living, because restarting what holds the old code is
an upgrade's job and is meaningless on an install.

**Open, and needing design rather than a ruling:**

| Ref | Question |
| --- | --- |
| Q1 | What the two commands are actually called, across deb and tarball, so U3 can be satisfied with one name each |
| Q2 | What each does when handed the other's job — refuse and name the right command, which is the only answer consistent with U2 |
| Q3 | Whether `lazysite upgrade` becomes THE upgrade (and `install.sh` loses its upgrade mode), or the tarball keeps its own and both are named in the docs |
| Q4 | What happens to `reinstall` - today a third mode, and under U2 it is either a deliberate verb of its own or it stops existing |

Q4 is the interesting one. `reinstall` exists only because the command was
guessing; once the operator says which they mean, "reinstall" is either
something they would deliberately ask for or it is an artefact of the guessing.

# Q1-Q4 ANSWERED BY THE RELEASE MANAGER, 2026-09-21

| Ref | Answer |
| --- | --- |
| Q1 | **`provision` and `upgrade`, the same verb words on both paths.** Asked back: *"what about deploy for the actual site, different from the install of the package on the system"* — answered below. |
| Q2 | **Refuse, name the other command, and say what it found.** |
| Q3 | **One way across both**, stronger than either option offered: *"tar/package is just how it gets to the system, then the operation is the same."* |
| Q4 | **`reinstall` becomes a deliberate verb**, with its meaning stated: *"reinstall (that doesn't affect content) makes sense - upgrade of the same version is confusing. reinstall is distinctly different, could be a verb to fix up a problem without version change."* |

## The `deploy` question, answered with what is already in the tree

The distinction behind it is right and is the reason `install` is the wrong
word for the site-level operation: **you install the PACKAGE, and the site is a
separate act.** But `deploy` cannot carry it, because this tree already uses
that word for two other things:

| Existing | What it means |
| --- | --- |
| `installers/hestia/lazysite-hestia-deploy.sh` | the per-site install/upgrade — and `INSTALL-RUNBOOK.md` marks it superseded |
| `tools/lazysite-deploy.sh` | the OPERATOR's build-push watcher, run on their own machine to push builds AT a host — deliberately excluded from the payload, because a site has no use for a copy |

Taking `deploy` as the site verb would make three meanings of one word, two of
them live, and one of them pointing the opposite way across the wire.

**`provision` already draws exactly the distinction the question is after**,
and it is the word the deb CLI, the registry vocabulary, six operator documents
and the man page already use. So: **install the package, provision the site,
upgrade the site.** Recorded as a recommendation rather than a ruling — the
question was the release manager's and the answer can be overridden.

## The design that follows

| Ref | Decision |
| --- | --- |
| D1 | Three site verbs, each chosen by the operator and never inferred: **`provision`** (make a site exist from the payload), **`upgrade`** (move an installed site to the payload's version), **`reinstall`** (re-lay the payload at the SAME version, touching no content). |
| D2 | **The verbs live in the `lazysite` CLI, and that is the one way.** Verified rather than assumed: `payload_root()` resolves `$bin/..`, so `perl tools/lazysite-cli.pl` already finds the payload in an unpacked tarball (`lazysite 0.14.2 … payload: /srv/projects/lazysite`). The packaging is delivery; the verb is the same. |
| D3 | **`install.pl` stops guessing and stops being operator-facing.** It becomes the implementation the CLI drives, taking the mode EXPLICITLY, and refusing to choose one. The classifier at `install.pl:595-603` is what U2 forbids. |
| D4 | **`install.sh` becomes a signpost, not a second spelling.** It is the historic muscle-memory entry point named in `README.md`, `starter/docs/install.md` and `UPGRADE.md`; deleting it strands those readers, so it prints the one way and exits non-zero rather than doing the work. |
| D5 | **Every reader is repointed, and a lint holds it.** The survey found the same operator task named four ways depending on which file you open. `t/lint/138` already asserts this property for the users tool's verbs; the same shape covers these. |

## `reinstall` and `repair` are not the same thing, and the docs must say so

Both answer "something is wrong and the version is not changing", which is why
this needs saying once, here:

| Verb | What it re-lays | When |
| --- | --- | --- |
| `reinstall` | the PAYLOAD — engine code, manager, templates — at the installed version, leaving content, accounts and config alone | a file was edited or lost and the site should be back to what the release ships |
| `repair` | nothing; it runs the health checks and applies their safe fixes (ownership, modes, missing dirs) | the files are right and the permissions or state around them are not |

Today's inferred `reinstall` mode already behaves this way — it takes a backup,
runs the conversions, and deliberately does NOT seed `nav.conf` or
`lazysite.conf` (`install.pl:1534`, `:1551`) and does NOT invalidate rendered
HTML (`:744`). So D1 names something that exists rather than inventing a mode;
what changes is that an operator can ask for it.

**One thing the survey settles about it:** no operator-facing document tells
anyone how to ask for a reinstall, and no command accepts the word. It has been
reachable only by accident — re-running the installer at the same version.

# WHAT WAS BUILT, 2026-09-21

| Ref | Outcome |
| --- | --- |
| D1 | `provision`, `upgrade`, `reinstall` dispatched by `tools/lazysite-cli.pl`. Each checks the declaration against the site and refuses the other two by name, with the version it found. |
| D2 | One way on both distributions. `payload_root()` resolves `$bin/..`, so `perl tools/lazysite-cli.pl provision ...` works from an unpacked tarball with no package installed. |
| D3 | `install.pl` requires `--mode` and refuses to choose one. `declared_mode()` replaced the classifier: the same state it used to read is now what the declaration is checked against. |
| D4 | `install.sh` prints the three verbs and exits 2. The two Hestia scripts that called it - the only machine callers in the tree - now drive `install.pl` directly with an explicit `--mode`. |
| D5 | Nineteen readers repointed, and `t/lint/149` holds every tracked file to it. |

## What D4 broke, and what that cost

Making the signpost refuse everything invalidated four blocks of live advice
that told an operator to run `install.sh` with paths: listing backups,
restoring one, previewing an upgrade, restoring a full-system backup. The
choice at that point was between naming `install.pl` in an operator document -
which D3 says stop doing - and giving each operation a word.

Reaching past the CLI to the implementation is how the CLI becomes the
second-best way to do something, and a second-best way is a second spelling. So
they got words:

| Added | Replaces |
| --- | --- |
| `backups --docroot D` / `--restore` / `--backup PATH` | `install.sh --list-backups`, `--restore` |
| `backups --restore-full FILE [--domain N]` | `install.pl --restore-full`, named in OPERATOR.md, FEATURES.md, the manager guide and the manager's own Backups page |
| `--dry-run` on `provision`, `upgrade`, `reinstall` | `install.sh --dry-run` |
| `channel VALUE`, `policy VALUE`, each taking `--docroot` / `--domain` / `--all` | `install.pl --channel` / `--policy`, named in four documents |

**The `--all` on the last pair is the substantive gain.** `install.pl`'s own
comment offered a shell loop over docroots, "because lazysite has no central
site registry - the host knows the sites". It has had one since [[SM139]], and
`upgrade --all`, `check --all` and `repair --all` all read it. A channel
decision is exactly the kind that arrives for a whole fleet at once.

`provision --dry-run` stops before the registry write as well as the install: a
preview that leaves a registry entry behind has told the fleet a site exists
that was never installed, which is this filing's own failure shape with a
different surface.

## Two things the gates found in this work

Recorded because both were mine and both would otherwise have shipped as
passing checks:

- **`t/lint/149`'s first draft reported the one call site in the tree that gets
  it right.** It matched lazily from `install.pl` to the first `--cgibin`, and
  in the CLI's `_install_argv` that token sits immediately before `--mode` - so
  the window ended exactly where the evidence began. It was measuring argument
  order, not the declaration.
- **`t/tools/86`'s restart-on-preview assertion measured the absence of
  systemd.** `_say_what_needs_restarting` returns at once unless the docroot is
  a registered site with a live unit, and a temp docroot is neither, so the
  line was absent with or without the guard. It is now a source check that
  states its own limit, the way `t/tools/78` does for the same call.

# Related

[[N142A]] (the restart this questions), [[SM891]] (the unit's own defects, found
the same day), [[SM886]] (the candidate explanation for the seven), [[SM890]]
(the template diagnostic that would have told the field which of these units
matters per site).
