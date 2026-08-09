---
title: "SM246 - Installer review: one permission model, one place to verify it"
subtitle: "Permissions are decided in three places by three policies, the check tool duplicates the knowledge from a fourth, and the code already carries scar tissue from a previous regression of exactly this kind."
brand: plain
status: partial
status-note: "PARTIAL 2026-08-09: DELIVERABLE 1 (explain the incident) is done and the cause is identified with evidence - install_file creates directories with a bare make_path and no mode, so they land at the umask default (0755 under root: no group write), and the docroot directories that are NOT in runtime_paths are never corrected on fresh or upgrade. DELIVERABLE 2 STARTED 2026-08-09: classification.json is now the model - every path carries a `why` and an `applied_by`, and t/lint/30 pins it against the check tool, which had ALREADY diverged by four entries. install.pl honours applied_by, which preserves its behaviour exactly. Still open: the model does not SHIP (it is build-time config, so check cannot read it on a deployed site), DELIVERABLE 3 DONE 2026-08-09: on_upgrade is declared per path (repair|leave), install honours it, and the defensive default is now the conservative value. Still open: the model does not SHIP, the four imperative passes remain, and the directory-mode fault from deliverable 1 is still not fixed. Raised by the operator 2026-08-08 after a stable deploy left the docroot's root-level folders without group write. This is a REVIEW request: the specific regression is the motivation, not the scope. Root cause is deliberately NOT asserted here - the installer has enough overlapping paths that guessing would be worse than useless, and explaining that incident is the review's first deliverable."
---

# SM246 - installer permission model review

## Why

A stable deploy left the docroot's root-level folders without group write. That
is the fourth or fifth permission incident in this installer's life, and the
pattern matters more than any one of them: each was fixed narrowly, each fix
added a code path, and the paths now overlap in ways that make the next incident
hard to reason about.

The installer records one of these in its own comments:

> a broader "align everything" pass in 0.6.5 stripped www-data's access on a site
> whose docroot group was not www-data, 500ing the auth wrapper

So a previous permission fix caused an outage, and the current code is
deliberately narrow *because of it*. That is scar tissue, and it is exactly the
shape the operator is describing: accumulated workarounds nobody can now verify
as a whole.

## What is true today

`install.pl` is 1,629 lines with **25 chmod/chown call sites**.
`tools/lazysite-check.pl` is 1,101 lines with **60 permission-related lines**.
Between them, the question "what mode should this path have?" is answered in
four different places by three different policies.

### Policy 1 - by file extension

```perl
sub mode_for {
    my ($path) = @_;
    return 0755 if $path =~ /\.(pl|sh)$/;
    return 0640 if $path =~ m{/lazysite/auth/};
    return 0644;
}
```

Applies to every installed file. No group write anywhere in it.

### Policy 2 - declared per directory

`runtime_paths` in `dist/config/classification.json`:

| Mode | Path |
|---|---|
| 2770 | `{DOCROOT}/lazysite/auth` |
| 2775 | `lazysite/cache`, `logs`, `stats`, `manager/locks`, `layouts`, `lazysite-assets` |
| 0755 | `{DOCROOT}/../plugins` |

Setgid and group-write, i.e. the opposite of Policy 1 - correctly, because these
are written by the web-server CGI. Two policies, no statement of how they relate.

### Policy 3 - imperative repair, after the fact

A pass that ORs `0020` into five named files (`nav.conf`, `lazysite.conf`,
`auth/users`, `auth/groups`, `acls.json`, `logs/audit.log`), a separate pass
adding `02020` to `lazysite/`, and `align_ownership()` repairing root-owned files
with a deliberately narrow scope because of the 0.6.5 outage.

These exist to undo Policy 1 for files where it is wrong. The list is
hand-maintained: a new file that needs group write is only fixed if someone
remembers to add it here.

### Policy 4 - the check tool

`lazysite-check.pl` verifies and, with `--fix`, repairs. It must therefore know
the same answers, and it learns them separately. Nothing pins the two in sync -
so the tool that tells you the install is correct can disagree with the tool that
made it.

### And a fifth axis: fresh versus upgrade

```perl
chmod $mode, $path if $install_mode eq 'fresh';
```

with, one line earlier:

```perl
$install_mode ||= 'fresh';
```

On upgrade an existing directory is left alone - reasonable, since an operator
may have tightened it deliberately, but it also means **the installer cannot
repair a directory whose mode is wrong**; only `check --fix` can. Two tools, two
policies, on the same paths.

The default is worth noting separately. The one caller does pass the mode, so
this is not a live bug - but the defensive default for a parameter controlling
"do I re-chmod existing directories?" should be the conservative value, and
`fresh` is the destructive one.

## Deliverable 1, done 2026-08-09: what removed group write

**`install_file` creates directories with no mode, so they inherit the umask.**

```perl
sub install_file {
    my ( $src, $dest ) = @_;
    my $dir = dirname($dest);
    if ( !-d $dir && !eval { make_path($dir); 1 } ) { ... }
    File::Copy::copy( $src, $dest ) or die ...;
    chmod mode_for($dest), $dest;      # the FILE gets an explicit mode
}
```

`make_path` with no `mode` uses `0777 & ~umask`. Under a root umask of `022`
that is **0755 - no group write**. The file gets an explicit mode on the next
line; the directory never does.

The asymmetry is the finding. The installer is demonstrably aware of the umask
problem and solves it three times **for files** - `chmod 0664 ... # umask-proof
the create`, and a whole pass commented "the group-write bit ... has to carry
group-write whatever umask this installer ran under". The same problem for
directories was never addressed.

### Which directories, and why "root-level"

The starter ships these into the docroot:

```
manager/  manager/assets/  assets/  docs/  docs/features/
docs/integrations/  .well-known/  lazysite/  lazysite/forms/
lazysite/manager/  lazysite/templates/
```

`runtime_paths` in `classification.json` claims only `lazysite/auth`,
`lazysite/cache`, `lazysite/logs`, `lazysite/stats`, `lazysite/manager/locks`,
`lazysite/layouts` and `lazysite-assets`. `lazysite/` itself is separately
OR'd with `02020` by the setgid pass.

**Everything else in that list is created by `install_file` at the umask default
and corrected by nothing** - which is exactly the set the operator described as
"the docroot's root-level folders".

### Why an upgrade shows it and a fresh install may not

Two independent reasons, either sufficient:

- `create_runtime_paths` re-applies its declared mode only
  `if $install_mode eq 'fresh'`, so an upgrade cannot repair even the
  directories it does claim;
- a directory that already exists is never touched by `install_file` at all, so
  the fault appears when a directory is **newly shipped** (or was removed and
  recreated) - which is why it surfaces on some deploys and not others.

### Why setgid does not save it

`lazysite/` carries `02020`, so directories created beneath it inherit the
**group**. Setgid propagates group ownership, not the group-write bit. A new
`lazysite/forms/` created at 0755 therefore has the right group and still cannot
be written by the web-server CGI.

### Ruled out

- **`dh_fixperms`** normalises modes inside the built deb. The deb carries the
  engine, not a live docroot, so it cannot explain modes on an installed site's
  content directories.
- **`align_ownership()`** changes owner, not mode, and is deliberately narrow
  because of the 0.6.5 outage.
- **The five-file group-write pass** only ORs `0020` into six named FILES.

### The narrow fix, and why it is not applied here

Giving `install_file` an explicit directory mode would close this. It is not
being applied in this commit, for the reason this filing already states: *report
before repair*. A directory mode applied at install time is precisely the class
of change that took a site down in 0.6.5, and the right sequence is the
declarative model plus `check` reporting against it, proving the model matches
reality on live sites before it is given power over them.

It also should not be fixed in isolation, because "what mode should this
directory have?" is deliverable 2's question. Answering it inline for one call
site would add a fifth policy rather than replacing four.

## Deliverable 2, started 2026-08-09: one table, and a guard

`dist/config/classification.json`'s `runtime_paths` is now the model. Every entry
carries two new fields:

- **`why`** - the reason for the mode. This was the missing part, and the reason
  a hand-maintained list drifts: without it a later reader cannot tell a
  deliberate mode from an accident.
- **`applied_by`** - which consumers own the path. `["install","check"]` for the
  paths the installer creates; `["check"]` for paths that are VERIFIED but never
  created here, because something else owns them: `lazysite/git` is made by the
  content-history plugin at adoption, `lazysite/forms` and the form-events log by
  the CGI. Absent means install, so an entry predating the field behaves as
  before.

`install.pl` honours `applied_by`, which **preserves its behaviour exactly** -
the paths it creates and the modes it applies are unchanged. That matters:
report-before-repair means the model can describe more than the installer acts
on.

### The two tables had already diverged

`t/lint/30-permission-model-parity.t` compares the model against
`tools/lazysite-check.pl`'s copy. Building it found four disagreements nobody had
noticed, because nothing compared them:

| Path | check | model |
|---|---|---|
| `lazysite/forms` | 2770 | absent |
| `lazysite/git` | 2770 | absent |
| `lazysite/stats/form-events` | 2775 | absent |
| `../plugins` | never looked | 0755 |

That is the incident's own shape in miniature: a permission fact maintained by
hand in two places drifts, and the drift is invisible until a deploy exposes it.

## Deliverable 3, done 2026-08-09: the upgrade policy is declared

Every model entry now carries `on_upgrade`:

- **`repair`** - the engine owns the path absolutely and re-applies the mode on
  every run. These are the directories the CGI MUST be able to write. An operator
  who "tightens" `lazysite/cache` breaks their own site, and the failure reads as
  a rendering fault rather than a permission one.
- **`leave`** - set on creation, never touched again. `../plugins` is EXECUTED,
  not written, so 0755 is correct and hardening it further is a legitimate
  operator choice.

Absent means `leave`, so a row predating the field keeps the old upgrade
behaviour. `t/lint/30` requires every path to declare one - both answers are
legitimate, and the fault was being unable to say which applied.

**This does change install behaviour on upgrade**, and that is the point:
previously the installer could not repair a directory whose mode was wrong, and
only `check --fix` could. Two tools, two policies, on the same paths. It only
ever widens a mode toward what the model declares, and it is NOT the
align-everything ownership pass that caused the 0.6.5 outage - that was `chown`
and is untouched.

**The defensive default is now the conservative one.** `create_runtime_paths` read
`$install_mode ||= 'fresh'`, and `fresh` is the branch that re-chmods existing
directories - so a caller that forgot the argument got the destructive behaviour.
The one real caller always passes it, so this was never live; a default that only
bites when someone makes a mistake should not be the dangerous one.

`t/tools/34` exercises the function directly: fresh creates and sets, upgrade
repairs a `repair` path and leaves a `leave` path alone, a check-only path is
never created, and a policy-less entry behaves as before.

### What this does NOT do

**The model does not ship.** `classification.json` is build-time config and is not
installed, so `lazysite-check.pl` cannot read it on a deployed site and still
holds its own copy. Making the model ship is a packaging change with its own
risk. Until then the guard makes a divergence impossible to reintroduce
unnoticed, which is this filing's own interim.

Also still open: the fresh-versus-upgrade policy (deliverable 3) is still
implicit, the four imperative passes (deliverable 4) are all still present, and
the directory-mode fault deliverable 1 identified is still not fixed.

## What the review must produce

### 1. An explanation of the reported incident

Which code path removed group write from the docroot's root-level folders on a
stable deploy - or, if nothing in `install.pl` did, which packaging or wrapper
step did. Note that `dh_fixperms` normalises modes in the deb build, and that the
docroot's own top-level content directories are not in `runtime_paths` at all, so
nothing in the installer claims them. Both are worth eliminating before looking
further.

This comes first because a redesign that does not explain the last failure will
not prevent the next one.

### 2. One declarative permission model

Every managed path in one table: path, owner, group, mode, and **why** - the
reason being the part that is missing today, and the reason the hand-maintained
group-write list drifts.

One table, three consumers, mirroring the shape used elsewhere in this codebase:

- **install** applies it,
- **check** verifies against it,
- **check --fix** repairs to it.

No consumer holds its own copy, so they cannot disagree. A drift guard pins the
table against the consumers, the way `t/lint/17`-`19` already pin duplicated data
elsewhere.

### 3. A stated fresh-versus-upgrade policy

Right now it is implicit and differs per pass. Decide it once: which paths the
installer owns absolutely (and will repair on every run), and which it sets on
creation and never touches again. Both categories are legitimate; what is not
legitimate is being unable to say which a given path is in.

### 4. Retire what the model absorbs

The five-file group-write pass, the separate setgid pass, and the
extension-based `mode_for()` all become rows in the table or disappear. Removal
is the measure of success: if the model lands and the imperative passes remain,
this has added a fifth policy rather than replacing four.

### 5. A verifiable report

An operator should be able to ask "are this site's permissions correct?" and get
an answer they can act on, without reading either tool's source. `check` mostly
does this already; what it lacks is a model to check *against*, rather than
knowledge of its own.

## Risks worth stating plainly

**This work can cause an outage.** The 0.6.5 pass proved that a broad permission
change on a site whose ownership does not match the assumption takes the site
down. Any redesign must be tested against the awkward cases the current narrow
code exists to survive: a docroot whose group is not the web-server group, a
site installed by sudo without a wrapper chown, and a site whose operator has
deliberately tightened a directory.

**Report before repair.** The first shipped step should be the model plus
`check` reporting against it, with no behaviour change at install time. That
proves the model matches reality on live sites before it is given the power to
change them.

## Not in scope

- Changing what any path's correct mode actually is. This is about knowing and
  applying it consistently, not revising the security posture.
- The deb packaging layout.
- Site provisioning outside the docroot (vhosts, systemd units, DNS).
