---
title: "SM321 - the operator should decide, not orchestrate"
subtitle: "Repairing a site needs a user and a domain the operator has to look up, and the fleet script has become the only place several operations exist. Both follow from one undeclared directory and one duplicated fleet layer."
brand: plain
status: candidate
status-note: "FILED 2026-08-16 from operator feedback after the 0.10.10 rollout: 'this fix command is fragile and needs me to know users and domains ... plus the updater seems to be getting bloated ... automate the fixes, with operator decision at the right point, not operator orchestration.' The criticism is fair and this release made it worse - SM313 and SM317 both added per-site logic to the Hestia script because that is where the site loop already lived. The largest single fix DELETES code rather than adding it."
---

# What the operator actually hit

After deploying 0.10.10 the rollout reported `edge.explore.lazysite.io: NOT
CONFIRMED`, and the documented next step was:

```bash
sudo perl -I/tmp/lazysite-0.10.10/lib /tmp/lazysite-0.10.10/tools/lazysite-check.pl \
     --docroot /home/<user>/web/<domain>/public_html \
     --cgibin  /home/<user>/web/<domain>/cgi-bin --fix
```

Four things the operator must supply that the system already knows: the unpack
path, the library path, the user, and the docroot layout. The only token they
genuinely hold is the **domain**.

Meanwhile `lazysite-hestia-list.sh --plain` emits `user<TAB>domain<TAB>docroot`
for every site on the host. The information was never missing. It simply was not
reachable from the command that needed it.

# Three causes, in order of how much they cost

## 1. The private store is the only runtime directory nobody declared

`dist/config/classification.json` already carries a declarative provisioning
model. Twelve `runtime_paths` entries name a path, a mode, a purpose, a reason,
who applies it (`install`, `check`, or both) and what an upgrade does
(`repair` or `leave`). `{DOCROOT}/../plugins` is in there, which proves a
sibling-of-docroot path is expressible.

**The private store is not.** That single omission produced everything else:

- `install.pl` never creates it, so a fresh site cannot protect content until
  someone notices;
- `lazysite check` needed bespoke repair code (SM313's `$store_create_needed`)
  rather than the generic path every other directory uses;
- the operator needs a special command, with hand-assembled paths, to fix a
  precondition of a documented feature;
- `acl reapply` fails on a site that has never been repaired, which is what
  SM313 was filed for.

Declaring it deletes the special case:

```json
{ "path": "{DOCROOT}/../{DOCROOT_BASENAME}-lazysite-private",
  "mode": "2770",
  "purpose": "protected content moved out of the served tree",
  "why": "a front end that answers statics without asking the engine cannot reach it",
  "applied_by": ["install", "check"],
  "on_upgrade": "repair" }
```

It needs a `{DOCROOT_BASENAME}` substitution, which is the whole implementation
cost. **This is the one change here that removes more code than it adds**, and it
is the one that removes the operator step entirely rather than making it easier
to type.

## 2. There are two fleet layers, and new work joined the wrong one

`tools/lazysite-cli.pl` already addresses the fleet: `cmd_upgrade_all`,
`cmd_sites`, and `migrate-engine-tree --all` - a per-site operation that takes
`--all` and iterates. That is the pattern, and it works.

`installers/hestia/lazysite-hestia-update-all.sh` addresses it too, separately,
in shell.

Every operation added recently went to the shell one, because that is where the
site loop already was:

```datatable
columns: Operation | Fleet addressing | Lives in
widths: 5.6cm | 3.4cm | X
bold: 1
tone: medium
---
`upgrade` | `--all` | the CLI
`migrate-engine-tree` | `--all` | the CLI
`check` | none | per-site only
`acl reapply` | none | per-site only
the outside-in ACL probe | fleet only | the Hestia script, nowhere else
the health repair sweep | fleet only | the Hestia script, nowhere else
---
```

The last two are the sharp end: they exist **only** inside a Hestia-specific
shell script, so an operator on any other layout cannot run them at all, and an
operator on Hestia cannot run them for one site without running the whole
rollout.

## 3. Decisions and mechanics are conflated in flags

`--rebuild`, `--proxy` and `--reapply-acls` are a mix of "do this mechanical
thing" and "I accept this consequence", and their safe ordering takes sixty
lines of header comment to explain. The operator has to hold the ordering rule
themselves, which is orchestration.

# What is actually an operator decision

This is the question the whole filing turns on, and most of the current prompts
fail it.

```datatable
columns: Action | A decision? | Why
widths: 5.4cm | 2.4cm | X
bold: 1
tone: medium
text: 3
---
Move content on a live site (`reapply --apply`) | **yes** | it relocates bytes a visitor may be requesting
Change a template assignment (`--proxy`) | **yes** | it changes the front end for every domain
Create the private store | **no** | it is a precondition of a shipped feature; no site wants to be unable to protect content
Repair a docroot mode a rebuild reset | **no** | it restores an invariant the installer already declares
Probe whether the front end honours an ACL | **no** | read-only, and the answer is wanted every time
---
```

Two of five. The other three are the installer finishing its job, and they are
the three currently demanding the most operator input.

# The recommendation

In order. The first is most of the value.

Declare the store, delete the special case
: `runtime_paths` gains the entry above; SM313's bespoke creation code comes out
  of `lazysite-check.pl`; `install.pl` provisions it like every other directory.
  A site provisioned or upgraded on this release can protect content without
  anyone being told to repair it.

Give the per-site tools fleet addressing, in the CLI
: `lazysite check --domain X` and `--all`, resolving user and docroot through
  the existing lister; the same for `acl reapply` and the ACL probe. The operator
  names the one token they hold. `migrate-engine-tree --all` is the working
  precedent - this is joining it, not inventing it.

Move the probe and the repair sweep out of the Hestia script
: they are not Hestia-specific and should not be reachable only there. Once they
  are CLI verbs, the shell script calls them.

Then let `update-all.sh` shrink to sequencing
: it stops containing per-site logic and becomes: upgrade the code, then invoke
  the verbs in the right order. The sixty lines of ordering rules become one
  place that encodes the order, rather than a comment telling the operator to.

Report the decision, with the command
: where something genuinely needs deciding, the tool should name the sites, state
  the consequence, and print the exact command - already addressed, so the
  operator's job is to type yes rather than to assemble arguments.

# Why this release made it worse

Worth recording plainly. SM313 added store-creation to `lazysite check` and
SM317 added the ACL probe to the Hestia script, both in the same release, and
both went where the existing loop was rather than where the operation belonged.
Each was individually reasonable. Together they moved the product further toward
"one script does everything, and the operator assembles the rest."

The feedback arrived within a day of deploying them, which is the shortest that
loop has ever been.

# Related

SM313 (the bespoke store creation this would delete), SM317 and SM319 (the probe
that should be a verb), SM303 (the same conflation in `release.sh` - one command
doing two jobs for two parties), SM269 (consolidating a lifecycle that had grown
six copies), and `dist/config/classification.json`, which already holds the model
this needs one more row in.
