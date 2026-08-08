---
title: "SM246 - Installer review: one permission model, one place to verify it"
subtitle: "Permissions are decided in three places by three policies, the check tool duplicates the knowledge from a fourth, and the code already carries scar tissue from a previous regression of exactly this kind."
brand: plain
status: candidate
status-note: "Raised by the operator 2026-08-08 after a stable deploy left the docroot's root-level folders without group write. This is a REVIEW request: the specific regression is the motivation, not the scope. Root cause is deliberately NOT asserted here - the installer has enough overlapping paths that guessing would be worse than useless, and explaining that incident is the review's first deliverable."
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
