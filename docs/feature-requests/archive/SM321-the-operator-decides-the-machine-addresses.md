---
title: "SM321 - the operator should decide, not orchestrate"
subtitle: "Repairing a site needs a user and a domain the operator has to look up, and the fleet script has become the only place several operations exist. Both follow from one undeclared directory and one duplicated fleet layer."
brand: plain
status: shipped
status-note: "COMPLETE for 0.10.12. The repair sweep and the outside-in ACL probe are now `lazysite repair` and `lazysite probe`, addressing sites through the registry or the host's own list (SM333), and lazysite-hestia-update-all.sh shrank by 202 lines to sequencing them. Driving the new verbs found two defects reasoning had not: --domain was rejected because the verb parsed its own options before the addressing was consumed, and `probe` classified a site with an UNRELATED [ FAIL ] as serving protected content anonymously - SM319's defect in the other direction, where the pass was an absence and here the failure was a level rather than a statement. Both fixed; exposure now matches the probe's own verdict. PART ONE SHIPPED - the store is now declared in runtime_paths, so install provisions it and check repairs it, and no code path has to decide who owns it. That is the permanent fix for SM323, which was two creators racing. install.pl carries its own construction because it is core-Perl-only by design (it must run before the engine it installs), and t/lint/51 pins it to Lazysite::Private::private_root. REMAINING: fleet addressing (--domain/--all on check, reapply and the probe, resolved through the existing lister), moving the probe and repair sweep out of the Hestia script into CLI verbs, shrinking update-all.sh to sequencing, and the three-section deploy output. REVISED 2026-08-16 after the operator challenged the decision analysis, correctly. The first draft called moving content and changing a template assignment operator decisions; BOTH ARE REQUIRED ACTIONS, not choices. Moving content is required and may create work for the SITE BUILDER (a public page referencing an asset inside a gated section), which audit_site machinery can already detect and list. A template move is required except on a domain someone customised, which lazysite-hestia-list.sh already reads. The principle: do not ask about the general case, detect the exception and ask only about that - which takes the decision surface from five prompts to two named exceptions. FILED 2026-08-16 from operator feedback after the 0.10.10 rollout: 'this fix command is fragile and needs me to know users and domains ... plus the updater seems to be getting bloated ... automate the fixes, with operator decision at the right point, not operator orchestration.' The criticism is fair and this release made it worse - SM313 and SM317 both added per-site logic to the Hestia script because that is where the site loop already lived. The largest single fix DELETES code rather than adding it."
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

The first draft of this filing answered "moving content" and "changing a template
assignment" - two of five. **Both were wrong**, and the correction matters more
than the original point.

## Moving content is not a decision, it is required work with a consequence

`acl reapply --apply` relocates files that are already governed by a rule the
engine already honours. Nobody would choose to leave them in the served tree;
that state is the defect. So there is nothing to decide.

What it can do is **break a public page that references an asset inside a section
being gated** - a hero image, a PDF, a stylesheet living under a folder that is
about to move. The operator cannot fix that. Only whoever built the site can,
by moving the asset out or by not protecting that section.

So the output is not a prompt. It is a **work item, addressed to the site
builder, naming the pages**:

```
3 public pages reference assets inside sections about to be gated:
  /pricing            -> /clients/acme/logo.png
  /about              -> /clients/acme/brochure.pdf
  /index              -> /clients/acme/hero.jpg
These will stop loading. Move the assets, or unprotect that section.
```

**This is machine-detectable with machinery that already exists.** `audit_site`
walks internal links for broken-link reporting and already returns
`unprotected_static_files`. Resolving each link and testing whether its target
falls inside a to-be-moved prefix is the same walk with a different predicate.

## Changing a template assignment is required, except where someone customised it

`--proxy` moves a domain onto the lazysite proxy template. Without it, gated
static files are answered by nginx without asking the engine - which is SM283,
live. Nobody would choose that either. It is required.

The one case that genuinely needs a human is a domain on a **non-stock template
somebody wrote deliberately**, where moving it would discard their work.

**That is detectable too, and already is.** `lazysite-hestia-list.sh` reads each
domain's actual proxy template (`PROXY_TPL_OF`) and compares it against the
wanted one - that comparison is what produces the `ACL-BYPASSED-BY-PROXY(SM283)`
flag. It knows the current template's NAME. Distinguishing "a stock Hestia
template" from "one this operator authored" is a lookup against what Hestia
ships, not new discovery.

So: move every domain on a stock template automatically, and ask about the
handful on a custom one - naming which, and what would be lost.

## The principle this yields

**Do not ask about the general case. Detect the exception, and ask only about
that.** Where the consequence is work rather than risk, address it to whoever can
do the work, with the list.

Applied to the five actions, the decision surface almost vanishes:

```datatable
columns: Action | Automatic | A human is needed for
widths: 4.6cm | 2.2cm | X
bold: 1
tone: medium
text: 3
---
Create the private store | always | nothing
Repair a docroot mode | always | nothing
Probe the front end | always | nothing
Move content (`reapply`) | always | the SITE BUILDER, if a public page references a moving asset - with the list
Template assignment | stock templates | the OPERATOR, only for domains on a custom template
---
```

Three of five need nobody. The remaining two need a named person for a named
exception, not an operator holding an ordering rule in their head.

## What a deploy should therefore print

Three sections, never merged, because they go to different people:

Repaired
: what was fixed without being asked. Reported, not prompted.

Needs the site builder
: content work, with the specific pages and assets. The operator forwards it;
  they cannot action it.

Needs you
: only detected exceptions, each with its consequence and the exact command.
  Empty on a healthy fleet, which is the point.

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
