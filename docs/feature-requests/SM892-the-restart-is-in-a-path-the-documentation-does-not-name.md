---
id: SM892
title: "SM892: the restart is in a path the documentation does not name, and there was almost nothing to restart"
subtitle: "V3 could not be walked, and finding out why produced two facts that undercut N142A's reasoning: the published tarball upgrade is install.sh, which names no unit and prints no restart line - and on the operator's host 28 of 29 runtime units are dead and no pool unit exists at all. Needs a ruling before anything is built."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-15
raised-by: sites agent
area: installers
status-note: "Q1-Q4 ANSWERED 2026-09-21 and the design is settled; NOTHING IS BUILT YET. Three site verbs chosen by the operator and never inferred - `provision`, `upgrade`, `reinstall` - living in the `lazysite` CLI, which is the ONE way on both distributions (verified: payload_root resolves an unpacked tarball, so the same verb works there). install.pl stops guessing and stops being operator-facing; install.sh becomes a signpost rather than a second spelling. The release manager asked whether the site verb should be `deploy`: the distinction behind the question is right, and `deploy` cannot carry it because this tree already means two other things by it, one of them the operator's build-push watcher pointing the opposite way across the wire. `provision` already draws it - install the package, provision the site. `reinstall` is NOT `repair`: reinstall re-lays the payload at the installed version and leaves content alone, repair fixes the permissions and state around files that are already right. A survey of the whole tracked tree found the same operator task named FOUR ways depending on which file a reader opens, which is what U3 is really about. OPEN, and it carries a RULING rather than a fix. THE THIRD INSTANCE OF ONE PATTERN: N141-05 put the pool restart in the Hestia deploy script, which INSTALL-RUNBOOK marks superseded; N142A moved it to `lazysite upgrade`; and the published install page for a tarball install names NEITHER - it documents `sudo bash install.sh --docroot ... --cgibin ...` and contains the string 'lazysite upgrade' zero times and 'systemctl' zero times (operator ran it 2026-09-15, output quoted below, no restart line and no reminder). So the restart has now been put in two places, neither of which the documentation sends a tarball operator to. AND THERE WAS ALMOST NOTHING TO RESTART: the operator's unit listing shows ONE active lazysited@ unit out of 29, the other 28 inactive dead, and NO lazysite@ pool unit under the lazysite* glob at all. N142A's guard - restart only what is running - therefore passed for exactly one site, and for none of the seven that had been reading old code. WHAT CAUSED THE SEVEN TO COME CURRENT AT 0.14.2 IS THEREFORE NOT ESTABLISHED; SM886 is the candidate and this filing does not claim it. The readings that would settle it are named below and are the operator's to run."
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

# Related

[[N142A]] (the restart this questions), [[SM891]] (the unit's own defects, found
the same day), [[SM886]] (the candidate explanation for the seven), [[SM890]]
(the template diagnostic that would have told the field which of these units
matters per site).
