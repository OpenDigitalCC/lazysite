---
id: SM933
title: "SM933: provision reports success on a site that returns 500"
subtitle: "A fresh provision on a Hestia domain printed `Installed: 265`, `Overwrote: 0` and four Next steps, then every request answered 500 Internal Server Error. The engine compiled cleanly; the fault was filesystem ownership and modes that provision itself had just written. `lazysite-check --fix` repaired it in three changes - and that tool is the only thing that could see it, run separately, from memory, after the install said it was done."
brand: plain
standard-margins: true
status: partial
raised: 2026-10-02
raised-by: the release manager, installing 0.14.4 on a new Hestia domain
area: installer
status-note: "PARTIAL. PR1, PR5 AND PR6 LANDED IN 31321799, AND PR1, and PR1 found a defect on its first run - so the row that was argued for as the cheapest earned its place before it shipped. PR1: the installer ends by running the check it already ships with and exits 4 when the site is not serviceable (4, not 1 - the files DID install; not 3 - `--channel-check` already means that). `--serving-group` is new on provision/upgrade/reinstall because the check compares the tree against the web server's group and its www-data default is right on this platform and wrong elsewhere. `upgrade --all` gains a FOURTH bucket, NOT SERVICEABLE, rather than counting such a site as done or failed. PR5: Next steps names the vhost-rebuild hazard. PR6: a repair line records the prior mode - `chmod 2775 (was 0755)`. THE DEFECT PR1 FOUND: a fresh install wrote `lazysite/forms/smtp.conf` world-readable (0644), which the shipped check calls a failure; the installer makes that file by copying the 0640 template and the mode rule was anchored on `.example$`, so the live copy - the one that gets the password - missed it. SM907 AT5 had already named this exact risk as 'what cp smtp.conf.example smtp.conf produces' without noticing the installer does the copying. A fresh install now reaches 0 failures on its own output, measured. NOT BUILT: PR0 (the fixture measurement), PR2 and PR3 (both wait on it - the remedy depends on which of three mechanisms it names), and PR4, which is RULED and needs the install state to record the mode the installer ACTUALLY left so drift can be told from a sysop's deliberate choice; that is a separate change. ORIGINALLY SCHEDULED FOR 0.15.2 at the release manager's direction 2026-10-02: file the fixes and apply them before the next release. The install is unblocked - `--fix` repaired the site and it serves. WHAT IS MEASURED AND WHAT IS NOT, kept apart deliberately: the OUTCOME is measured on a real install (success report, 500 on every request, three repairs, five directories left without setgid). THE MECHANISM IS NOT ESTABLISHED - why the engine tree carried a group the CGI is not in has three candidate causes and naming it is the first task of the build, not an assumption to carry into it. This filing deliberately does NOT repeat the diagnosis offered during the incident: a vhost rebuild resetting the docroot (SM270) was proposed and the evidence refutes it - the docroot came back `group-writable + setgid (2775)` and was never the problem. The `chown -R` in the repair is where the fault was."
---

# BUILT 2026-10-03 (PENDING): A2 / PR2, to R13

`_adopt_site_group` in install.pl, called where a path is CREATED - a
successful mkdir in `make_declared_path`, a file that did not exist before
`install_file`'s copy, and the runtime-paths branch that makes the private store
- and nowhere else, so an existing path's group is never changed. Before the
chmod, so setgid survives the chown.

Re-measured with the PR0 rig: run A (0755 docroot) 202/202 paths in the docroot's
group (was 0/202) and 16 check failures down to 1, the docroot mode the fixture
chose; run B (2775, the field shape) **passes its own health check**, where it
failed on the private store. `t/tools/94` pins it on the discriminating fixture -
a non-setgid docroot, where the kernel alone would give the wrong answer - with
five sabotages (no regroup; private store branch; files; declared directories;
existing files regrouped), each failing a named subtest.

A path the installer could not regroup is counted and said in the summary.

# RULED 2026-10-03

- **R13 (A2/PR2): inherit from the docroot.** Every path provision creates takes the docroot's group - including the private store, which sits beside the docroot and so is not reached by its setgid bit.
- **R14 (A3/PR3): withdrawn.** The measurement above contradicts its premise; the reset case is covered by PR5's warning and PR1's health check.

# Measured, on one real install

0.14.4, a new Hestia domain, `provision` run as the site user through `sudo -u`.
It completed and said so:

    === Install summary (fresh) ===
      Version:    0.14.4
      Installed:  265
      Overwrote:  0
      Preserved:  0
      Removed:    0

    Next steps:
      1. Create the first account. [...]

`setup-sysop` then worked, minting a claim link. **Every request to the site
answered `500 Internal Server Error`.**

The engine was not at fault and that was established before anything was changed:

    sudo -u <user> perl <cgibin>/lazysite-processor.pl -c    ->    syntax OK

So the modules were present and the code compiled. `lazysite-check --fix` then
repaired the site in three changes:

    fixed: chmod 2775  <docroot>/lazysite-assets
    fixed: chmod 0660  <docroot>/lazysite/forms/smtp.conf
    fixed: chown -R <user>:www-data  <docroot>/lazysite

After which the site served, and the report read **33 ok, 7 warnings, 0 failures**.

**Grade: measured on a live install, before and after, with the engine's own tool
as the instrument.** One site, one host, one version.

# The fault that is certain

**The CGI could not reach the tree that had just been installed for it.** This
engine runs the CGI as `www-data` with no suexec - `tools/lazysite-check.pl:4`
states that as the arrangement it verifies, and `:212` says the tree "must keep
group access" because of it. The repair that mattered is the third line: the whole
`lazysite/` tree needed its group changing to `www-data`.

So a fresh install produced a tree the engine cannot use, and **reported complete
success.**

# What it costs, and it is not the ten minutes

An installer that cannot see whether the thing it installed works is an installer
whose summary is not evidence. Three specific costs:

- **The summary is confident and wrong.** `Installed: 265, Overwrote: 0` is true
  and irrelevant: it counts files written, not a site that answers. A reader has
  no reason to doubt it.
- **The only tool that can see the fault must be remembered.** `lazysite-check`
  found it in one run. Nothing in the install output says to run it - the four
  Next steps are about accounts, layouts, config and content.
- **This has happened before, in the same shape.** `tools/lazysite-check.pl:424`
  records an earlier incident in its own comment: a docroot mode reset, "the sysop
  followed the release notes' instruction to re-render vhosts, and **this tool
  reported the site healthy while the manager could not save a file**". The class
  is known. What is missing is any step that closes it without a person
  remembering.

And the release manager's own words on the day, which are the reason this is filed
rather than noted: **"install is becoming increasingly more complex. this is fiddly
enough already."**

# Five directories a fresh install leaves wrong, by policy

The post-fix report still carried five warnings of one kind:

    [ warn ] .well-known is 0775, the model declares 2775
    [ warn ] assets      is 0775, the model declares 2775
    [ warn ] docs        is 0775, the model declares 2775
    [ warn ] lazysite    is 0775, the model declares 2775
    [ warn ] manager     is 0775, the model declares 2775
             -> reported only; --fix restores group write, never other bits

These are **missing setgid on directories provision created**, against a model
provision itself declares. `--fix` declines them deliberately (the ruling behind
SM274: restore group write, never other bits, because a tightened mode may be
somebody's choice) - which is right for a site somebody has been administering and
wrong for a tree the installer made thirty seconds earlier.

The consequence is the slow-burning half of the same fault: files created in those
directories later inherit the wrong group, which is the SM215 class. **A fresh
install cannot produce a clean report from the engine's own checker**, and a
warning that is always present on every new site is a warning nobody reads.

# One small thing the repair destroys

    fixed: chmod 2775 <path>

The line says what the mode became and not what it was. The evidence of what was
wrong is gone the moment it is fixed, which is why this filing can measure the
outcome and not the cause. A repair line should carry the prior value.

# MEASURED 2026-10-02 (PR0 / plan A1): THE MECHANISM IS CANDIDATE 2

Two provisions into a fixture whose docroot carries a group that is **not** the
invoking user's primary group - which is the shape the field case had -
recording owner, group and mode of all 202 paths each run creates.

**To reproduce** (no root needed; any group the invoking user is a member of will
do, and the point is only that it differs from their primary group):

    mkdir -p /tmp/a1/site/public_html /tmp/a1/site/cgi-bin
    chgrp users /tmp/a1/site/public_html     # a SECONDARY group of yours
    chmod 0755  /tmp/a1/site/public_html     # run A; use 2775 for run B
    perl install.pl --mode provision \
      --docroot /tmp/a1/site/public_html \
      --cgibin  /tmp/a1/site/cgi-bin \
      --serving-group users
    find /tmp/a1/site/public_html -printf '%g %m\n' | sort | uniq -c

The last line is the whole measurement: it buckets every path by group and mode,
so one run answers which group the install actually produced. Run A here gives

          2 claude 2770
         25 claude 2775
          3 claude 640
        169 claude 644
          3 claude 664
          1 users 755

- 202 paths in the primary group, and the single `users` entry is the docroot
itself, which the fixture set and provision did not touch.

| | docroot | group of every created path |
| --- | --- | --- |
| run A | 0755, group `users` | `claude` - the **process's primary group**, all 202 |
| run B | 2775, group `users` | `users` - the **docroot's** group, all 202 |

**Candidate 1 is refuted.** If the code inherited the parent's group, run A would
have produced `users`. It produced `claude` on all 202 paths, starting with
`.well-known`, whose parent *is* the docroot.

**Candidate 3 is refuted.** Ordering would show a transition. Run A is uniformly
the primary group from the first created directory to the 202nd, with no boundary
anywhere in creation order.

**Candidate 2 is confirmed, and it is wider than this filing supposed.** It is not
"a directory made by `make_path` without a following `secure_write_perms`". It is
that `install.pl` **never sets a group on anything it writes**. `install_file`
copies and then `chmod mode_for($dest)`; `make_declared_path` creates with a
declared mode. Neither calls `secure_write_perms`, which is the helper that exists
for exactly this and which SM215 wrote the group-inheritance rule into. So the
group of everything provision produces is whatever the kernel hands it: the
parent's group under a setgid directory, the process's primary group otherwise.

**The helper works - it is simply not called.** Measured separately, because
"called and failing silently" and "not called" are different faults and the
helper's own comment calls the non-root chown "best-effort": pointed at a file
and a directory under a parent whose group is not ours,
`Lazysite::Util::secure_write_perms` chgrps both to the parent's group as
non-root. One line to confirm on any host:

    perl -Ilib -MLazysite::Util -e 'Lazysite::Util::secure_write_perms($ARGV[0], 0664)' <path>

The capability is present and unused.

## The path this leaves broken is the private store, and setgid cannot save it

Run B is the field shape - the real docroot was 2775 - and it still fails one
check:

    [ FAIL ] the private store exists but the engine cannot write to it
             (<docroot>-lazysite-private, owner claude:claude, mode 2770)

In **both** runs the private store is `claude:claude` while the docroot is
`claude:users`. It is created **beside** the docroot, so the docroot's setgid bit
never reaches it and it takes the group of the **site root** instead. On a Hestia
domain the site root is `<user>:<user>` and the serving group is `www-data`, so
this path is wrong on every such host, and nothing in the install said so until
PR1 wired the health check in.

This is the sharpest available statement of what PR2 has to fix, and it is not
what the incident's own diagnosis pointed at.

## A3/PR3's premise needs re-measuring before it is built

**Every directory provision creates already carries setgid** - 0 without it, in
both runs, 27 directories each. So the field report's "five directories left
without setgid" cannot be describing directories provision had just created in
that state. Either they pre-dated the install, or something reset them afterwards
(the vhost-rebuild hazard PR5 now names). A3 should not be built against a
premise this measurement contradicts; what it needs first is the five paths from
the field report by name.

## What this hands the release manager to rule

`secure_write_perms` inherits the group **from the parent directory**, and for the
private store the parent is the site root - which is the wrong source. So "call
the helper that already exists" fixes the paths inside the docroot and gets the
private store wrong for the same reason it is wrong now. The choice is therefore:

- **(a) inherit from the DOCROOT**, not from the immediate parent, for anything
  provision creates outside it; or
- **(b) chgrp to `--serving-group`**, the value the health check is already
  comparing against, and treat the docroot's own group as advisory.

(b) is narrower and says out loud which group the site is for; (a) keeps one rule
("the site tree's group") and needs no new argument on the command line to be
correct. Not decided here.

# What is NOT established, and must be measured first

**Why the engine tree carried a group the CGI is not in.** Three candidates, and
the build starts by discriminating between them rather than assuming:

1. **Inherited faithfully from a wrong parent.** `Lazysite::Util::secure_write_perms`
   takes the group from the containing directory - deliberately, "we INHERIT
   owner+group from it rather than hard-code www-data" (SM215). On a Hestia domain
   whose `public_html` is owned `<user>:<user>`, that inherits the wrong group
   correctly. **Note against this:** the post-fix report shows the docroot itself
   passing its owner/group expectation, so the parent may not have been wrong.
2. **Created outside that helper.** A directory made by `make_path` without a
   following `secure_write_perms` gets the process umask and primary group.
3. **The primary group of the invoking user**, under `sudo -u`, where no setgid
   parent existed yet at the moment the first directory was created - an ordering
   effect rather than a wrong value.

These are distinguishable by provisioning into a fixture and recording owner, group
and mode of every created path, which is the first thing to build.

# What should change

| Ref | Change | Why |
| --- | --- | --- |
| PR1 | **Provision ends by running the check it ships with**, and prints the result. A fresh install either says healthy or names its own fault | Removes "the summary is not evidence". The instrument already exists; only the wiring is missing |
| PR2 | **Provision leaves the tree reachable by the CGI, or refuses and says which path it could not place** | A tree the engine cannot read is not an installed site. Needs PR0's measurement first - the remedy depends on which mechanism it is |
| PR3 | **Setgid on the directories provision creates**, so the model it declares is the model it produces | Closes the five standing warnings and the SM215 class behind them |
| PR4 | **`--fix` may set the bits it created itself.** SM274's "never other bits" protects an administered site; it should not protect the installer from its own output | A fresh install should be able to reach a clean report |
| PR5 | **Next steps names the rebuild hazard**: any vhost rebuild can reset modes, so re-run the check after one | The knowledge exists in a code comment and the runbook, nowhere a person installing will look |
| PR6 | **A repair line records the prior value** - `chmod 2775 (was 0755)` | The evidence of the fault should survive the fix |

PR1 is the one that matters most and is the cheapest: it converts every future
instance of this class - including ones nobody has met yet - from a silent 500 into
a named line at install time.

# Related

[[SM270]] (the docroot-mode reset, which is a different fault in the same class and
is what was wrongly proposed during this incident), [[SM274]] (the ruling `--fix`
is obeying when it declines the five directories), [[SM215]] (owner/group
inheritance, the mechanism candidate), [[SM619]] (never write a site tree as root),
[[SM932]] (whether a diagnostic reaches anybody - the same question one layer down),
[[feedback_reproduce_before_blaming_the_host]].
