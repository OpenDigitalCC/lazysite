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
status-note: "PARTIAL (PENDING). PR1, PR5 AND PR6 ARE BUILT, and PR1 found a defect on its first run - so the row that was argued for as the cheapest earned its place before it shipped. PR1: the installer ends by running the check it already ships with and exits 4 when the site is not serviceable (4, not 1 - the files DID install; not 3 - `--channel-check` already means that). `--serving-group` is new on provision/upgrade/reinstall because the check compares the tree against the web server's group and its www-data default is right on this platform and wrong elsewhere. `upgrade --all` gains a FOURTH bucket, NOT SERVICEABLE, rather than counting such a site as done or failed. PR5: Next steps names the vhost-rebuild hazard. PR6: a repair line records the prior mode - `chmod 2775 (was 0755)`. THE DEFECT PR1 FOUND: a fresh install wrote `lazysite/forms/smtp.conf` world-readable (0644), which the shipped check calls a failure; the installer makes that file by copying the 0640 template and the mode rule was anchored on `.example$`, so the live copy - the one that gets the password - missed it. SM907 AT5 had already named this exact risk as 'what cp smtp.conf.example smtp.conf produces' without noticing the installer does the copying. A fresh install now reaches 0 failures on its own output, measured. NOT BUILT: PR0 (the fixture measurement), PR2 and PR3 (both wait on it - the remedy depends on which of three mechanisms it names), and PR4, which is RULED and needs the install state to record the mode the installer ACTUALLY left so drift can be told from a sysop's deliberate choice; that is a separate change. ORIGINALLY SCHEDULED FOR 0.15.2 at the release manager's direction 2026-10-02: file the fixes and apply them before the next release. The install is unblocked - `--fix` repaired the site and it serves. WHAT IS MEASURED AND WHAT IS NOT, kept apart deliberately: the OUTCOME is measured on a real install (success report, 500 on every request, three repairs, five directories left without setgid). THE MECHANISM IS NOT ESTABLISHED - why the engine tree carried a group the CGI is not in has three candidate causes and naming it is the first task of the build, not an assumption to carry into it. This filing deliberately does NOT repeat the diagnosis offered during the incident: a vhost rebuild resetting the docroot (SM270) was proposed and the evidence refutes it - the docroot came back `group-writable + setgid (2775)` and was never the problem. The `chown -R` in the repair is where the fault was."
---

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
