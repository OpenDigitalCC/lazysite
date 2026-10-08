# Development

Developer-facing notes for the lazysite repo. User-facing docs live
under `starter/docs/` and ship inside every installation.

## Working with CC

The development assistant edits the working tree in place at
`/srv/projects/lazysite` and leaves it uncommitted. The operator
(with push rights) reviews and commits; releases are separate from
commits.

The previous `/home/claude/lazysite` sandbox + rsync arrangement was
retired 2026-05-22 (see CLAUDE.md). There is no separate sandbox copy
to sync from; commit.sh commits the in-place tree (SM070).

### Flow overview (SM063, in-place since SM070)

Two scripts, each doing one thing:

- **`tools/commit.sh`** - commits CC's in-place working-tree edits
  with CC's message and pushes to `origin/main`. No tagging, no
  version bump, no tarball build.
- **`tools/release.sh`** - gates main, builds a release as one
  release commit on main with a local tag, and publishes main and
  the tag together. See "Releasing" below.

Main is *unstable*: every landing is gated after it lands, and a
release adds one commit carrying its CHANGELOG section, version
pair and records. Tags are the stable identifiers. Pull a tag if
you want a stable version; pull main if you're developing.

### Commit convention (for CC)

CC writes one file per session:

- **`.commit-message.md`** at repo root. Entire file becomes
  the commit message body. Convention: short title-style first
  line (~72 chars), blank line, markdown body describing
  what changed and why. Example:

  ```
  SM063: split commit and release into two scripts

  Replaces pre-release.sh + make-release.sh. commit.sh handles
  rsync-and-push; release.sh handles test-tag-tarball. Main
  becomes unstable; tags are the stable identifiers.
  ```

Anything else CC used to produce (release-notes, prep scripts,
version-bump commits) is gone. One session, one file, one
commit.

### Running commit.sh

```
tools/commit.sh
```

Preconditions are verified up front (a git working tree, on
main, `origin/main` up to date, CC's `.commit-message.md`
present). Any failure aborts before committing.

The in-place working tree is expected to carry CC's edits;
commit.sh stages and commits them with `git add -A`.
`.commit-message.md` is gitignored, so it is never staged.

On success: commit lands on origin/main, CC's
`.commit-message.md` is deleted so the next session starts
clean.

If the working tree is clean (no edits), commit.sh exits 0
without committing and leaves `.commit-message.md` in place
for a future run.

## Releasing

    land -> (auto) gate -> "cut X" -> build -> publish

The release manager lands branches. After each landing Claude gates main's tip
in the background, unattended. When the release manager says "cut X", Claude
runs `build` - minutes, from the receipt the gate already wrote. The release
manager then runs `publish`, which pushes main and the tag together. Nobody waits
for a test, and a release is one commit on main (SM971).

| Step | Who | Command | Takes |
| --- | --- | --- | --- |
| land | release manager | vcs-review | - |
| gate | Claude, after each landing | `tools/gate-main.sh [--version X.Y.Z] [--beta\|--final]` | the suite, bench and coverage (~6 min to ~75 min; coverage is reused when its inputs are unchanged) |
| cut | release manager | says "cut X" | - |
| build | Claude | `tools/release.sh build X --notes FILE [--beta\|--final]` | minutes |
| publish | release manager | `tools/release.sh publish X` | seconds |

### The release material, written by one generator

`tools/release-material.pl VERSION --dir DIR [--channel C] [--notes FILE]
[--date D]` writes everything mechanical about a release into a clean checkout:

- `CHANGELOG.md` - `## Unreleased` becomes `## X.Y.Z - CHANNEL: subtitle
  (DATE)` under a fresh empty `## Unreleased`, and every entry whose first line
  still carries `(PENDING)` gets its landed SHA;
- `docs/releases/CHANGELOG-archive.md` - at a new minor (X.Y.0), the earlier
  minors' sections move there unchanged (lint 210);
- `docs/FEATURES.md` - the timeline entry and the subtitle's "as of vX.Y.Z";
- `VERSION` X.Y.Z and `NEXT_VERSION` X.Y.(Z+1), by `tools/bump-version.pl`;
- `starter/docs/ai-briefing-practice.md`, by `tools/import-field-practice.pl`;
- `docs/INDEX.md`, by `tools/gen-doc-index.pl --write`.

**A PENDING ref is resolved from git, never guessed.** The SHA is the one commit,
since the newest tag reachable from HEAD, whose diff added that exact line to
`CHANGELOG.md`. No such commit, more than one, or the same line twice: the
generator refuses, naming the entry, and writes nothing. Stamp that one by hand
in a landing; a main that moved only in release material needs no new gate.

`--paths` prints the **release-material allowlist** - the files above plus
`docs/releases/GATE-LOG.md` and `dist/config/coverage-last.json`, which the build
writes itself - and `--lints` the checks that read them (t/lint/214 keeps that
list complete).

### Gate

`tools/gate-main.sh` resolves main to a SHA, takes `NEXT_VERSION` (refusing when
it is not the patch after the newest tag, or is already tagged - pass `--version`
for a new minor), and runs `tools/release.sh gate VERSION --commit SHA` under
`setsid -w ... </dev/null`, its output in `tmp/release-gate/VERSION/gate-main.log`.
A receipt for that commit, version and channel that already passed is printed
instead.

Run it from a worktree of main when the main checkout is in use - bash reads a
script as it runs, so switching branches under a running gate is unsafe:
`git worktree add --detach tmp/wt-gate main`, then `tmp/wt-gate/tools/gate-main.sh`.
Receipts, the coverage store and the lock are kept in the MAIN checkout's
`tmp/release-gate/` wherever the gate runs from, so build finds them.

The gate clones the commit into a stage, **runs the generator there** with a
placeholder subtitle, commits that in the stage only, and runs the compliance
check, the full suite at -j4, the bench, coverage, and the manifest, SBOM and
man-page checks on that tree. So it tests exactly what will ship apart from the
subtitle and FEATURES prose, and any commit on main can pass. The receipt
(`tmp/release-gate/VERSION/receipt`, every log beside it) records the commit, the
counts, the coverage verdict and the generator's digest (`material_tool`).

**Coverage may be reused.** Every passing coverage run is kept in
`tmp/release-gate/coverage-passes/DIGEST.json`, stamped with the commit that
measured it. A later gate whose coverage-inputs digest matches offers coverage.sh
that record and skips the instrumented run; the receipt says `coverage=reused`
and `coverage_from=sha=... version=...`. The release material changes nothing
the digest reads. `LAZYSITE_COVER_FORCE=1` measures anyway. The digest
(`tools/coverage-inputs.pl --list` says why for each test) leaves out a test only
when its code, read with PPI, can start no process, load no file and call no sub
that does.

### Build

`tools/release.sh build X --notes FILE`. The notes file is a header block ended
by a blank line, then the tag annotation:

    Subtitle: an install says whether the site works
    Features: Provision ends by running the health check (SM933) ...
      continuation lines are indented
    Assisted-by: Claude:claude-opus-5-5[1m]
    Claude-Session: https://claude.ai/code/session_...

    lazysite 0.15.3 (edge)
    ...

Subtitle and Features are required; Assisted-by is required and, with
Claude-Session, becomes the release commit's trailers. Then build:

1. refuses unless a receipt for X passed on main's tip, for this channel, from a
   gate that ran the generator. If main has moved past the receipt it refuses
   unless every commit since touched only the allowlist - exactly the files
   build rewrites and then re-checks, so such a landing changes nothing the gate
   measured;
2. refuses if main is checked out in a worktree with uncommitted changes;
3. makes a worktree of main, runs the generator with the notes, appends the
   GATE-LOG row (naming the gated commit) and copies the gate's coverage record;
4. commits that as ONE release commit on top of main, and refuses unless its
   diff touches only the allowlist;
5. runs the checks that read the material (`release-material.pl --lints`) and
   the compliance check on it;
6. builds the manifest, SBOM, man pages, tarball, the four .debs and the
   claude.ai skill from the release commit;
7. on a stable cut, commits the new `download/` set on top (download/ only;
   lint 113 runs on it);
8. tags the release commit `vX` LOCALLY and moves main to it (fast-forward:
   the worktree on main moves with it). Until this step main and the tags are
   untouched, whatever failed.

The artefacts land in `dist/`. There is no post-release record: the GATE-LOG row
and the coverage record are in the release commit.

### Publish

`tools/release.sh publish X` - the release manager's only step, and the only one
that touches the network. It pushes main and `vX` together (`git push
--atomic`), and refuses when the tag is not on local main, when origin's main is
not an ancestor of local main (nothing is forced), or when `vX` is already on
origin (a burned version is never reused, SM064).

### Where the gate runs, and why it matters

The gate's Devel::Cover run is the constraint, and not in the way anyone
expects. **Devel::Cover writes one directory per instrumented process.** This
suite drives real CGI subprocesses rather than mocking them, so a gate run
produces hundreds of thousands of small directories. It exhausts a filesystem's
**inodes**, not its bytes.

That is why the staging location is `${LAZYSITE_STAGE_DIR:-${TMPDIR:-/tmp}}` and
overridable with `--stage-dir`, and why the pre-flight check reads `df
--output=iavail` rather than free space. On this host `/tmp` is a 4.8G tmpfs with
a fixed 1,048,576 inodes; a release fills it while reporting 3% of bytes used, so
`df -h` looks healthy right up to the failure. **Build scratch belongs on `/srv`
here** - the root filesystem is small and `/tmp` cannot hold a gate run.

```bash
export LAZYSITE_STAGE_DIR=/srv/tmp
```

On any abort the stage is kept and its path printed, and the NEXT run removes it
at start once the process that made it is gone (SM895 G3), so at most one failed
stage sits there at a time and a live run's stage is never touched.

### Handing off a stack of branches

`bash tools/handoff.sh --stack BASE` hands off every branch from BASE to the
checked-out tip at once: the one-minute precheck on each, against the branch
below it, and the full suite once, on the tip. Each branch is READY only if all
of it passed; the first precheck that fails stops the run, naming the branch.
When only part of a stack lands, rebase what is left onto the new main and run
`--stack main` again on it.

### Strict dependency check

`release.sh` runs `tools/manifest-to-sbom.pl --strict`. This:

1. Walks every file in `release-manifest.json` with `.pl` or `.pm`
   extension.
2. Parses every `use` and `require` statement.
3. Skips Perl pragmas (`strict`, `warnings`, `feature`, etc).
4. Fails the release if any module name is not listed in
   `dist/config/sbom-deps.json`.

Consequence: you cannot add a `use Some::Module` to shipped code
without also adding an entry for it to `sbom-deps.json`. This
prevents SBOM drift - the metadata stays in sync with what the
code actually imports.

### Adding a new dependency

1. Add the `use`/`require` in the code.
2. Open `dist/config/sbom-deps.json`.
3. Add an entry under `modules`:

   ```json
   "Some::Module": {
     "core": false,
     "license": "Artistic-1.0-Perl",
     "debian_pkg": "libsome-module-perl",
     "rhel_pkg": "perl-Some-Module",
     "alpine_pkg": "perl-some-module",
     "used_by": "what lazysite feature pulls this in"
   }
   ```

4. Run `tools/manifest-to-sbom.pl --strict` (or let the next
   `tools/release.sh` catch any omission) to confirm it passes.

If `license` is genuinely uncertain, use `"UNKNOWN"` and flag in
your commit message. Do not guess.

### Files involved

| File | Role |
|---|---|
| `VERSION` | Committed value, informational only under SM063. Release version lives in the tag name. |
| `NEXT_VERSION` | Vestigial under SM063. No longer consumed by the flow; still in the tree for historical reasons. |
| `release-manifest.json` | File catalogue with SHA-256 and install targets. Committed; checked by `--strict`. |
| `sbom.json` | CycloneDX SBOM covering source + direct deps. Committed; checked by `--strict`. |
| `tools/build-manifest.pl` | Manifest generator. |
| `tools/manifest-to-sbom.pl` | SBOM generator + strict dep check. |
| `tools/commit.sh` | In-place working tree → main push. SM063; in-place since SM070. |
| `tools/release.sh` | Test + tag + tarball. SM063. |
| `dist/config/classification.json` | Rules mapping repo paths to install targets and buckets. |
| `dist/config/sbom-deps.json` | Curated metadata (license, distro packages, used_by) for every module the code imports. |
| `dist/` | Release artefacts (tarball, .sha256). Root is gitignored; tarballs force-added. `dist/config/` is tracked. |

### Verifying an installed manifest

Once D021c lands, the installer writes the manifest under the
install root. Until then, you can verify a staged tarball:

```
tar xzf dist/lazysite-0.1.0.tar.gz -C /tmp
/tmp/lazysite-0.1.0/tools/build-manifest.pl \
    --staged /tmp/lazysite-0.1.0 \
    --out    /tmp/lazysite-0.1.0/release-manifest.json \
    --check
```

`--check` reads the existing manifest and verifies every listed file
exists with matching size and SHA-256. Exit 0 clean, non-zero with
a diff summary on mismatch.

### Manifest classification buckets

Each shipped file falls into one of three buckets:

- **code** - overwritten on every upgrade. Scripts, system theme,
  manager UI pages, vendored assets.
- **seed** - installed on a fresh install. On upgrade, the installer
  (D021c) overwrites only if the on-disk SHA matches the
  last-installed manifest entry, i.e. the operator has not edited
  the file. Landing pages, user docs, `.example` templates, feed
  templates.
- **runtime** - directories created by the installer at install time
  and never touched again. Per-install credentials, cache, logs,
  edit locks.

Rules and overrides are defined in
`dist/config/classification.json`. Adding a shipped file means
either matching an existing rule or adding a rule/override.

## Installer (install.pl)

`install.pl` at repo root is the real installer, and it is
not the operator's command: `tools/lazysite-cli.pl` drives it
through the `provision`, `upgrade` and `reinstall` verbs
(SM892 D3). `install.sh` is a signpost to those verbs and
installs nothing - the Hestia scripts, which need the
implementation rather than the verb, call `install.pl`
directly with an explicit `--mode`.

The Perl script reads `release-manifest.json` at the tarball
root and tracks installed state at
`{docroot}/lazysite/.install-state.json`.

### Three modes, DECLARED not inferred

The mode comes from `--mode provision|upgrade|reinstall`,
which is required. It used to be read off the disk - no state
file meant fresh, a version difference meant upgrade, the
same version meant reinstall - and `declared_mode()` now
checks the declaration against that same state and refuses a
mismatch instead of silently doing the other thing. SM892:
an operator ran the documented command on a live site and was
told "Next steps: 1. Create the first account", because the
installer had decided it was doing a reinstall and nothing
had asked what they meant.

- **provision** (`fresh` internally): expects no state file.
  Walk the manifest, install everything, write state. No
  backup (nothing to back up). REFUSED if a site is already
  installed there.
- **upgrade**: expects a state file at a different version.
  Compare manifest against state per-file: overwrite code
  always, preserve operator-edited seed, remove unedited
  orphans, leave edited orphans with a warning. Back up
  everything tracked in state before any changes. REFUSED
  with nothing installed; already current is a no-op.
- **reinstall**: expects a state file at the SAME version.
  Same logic as upgrade; re-lays this version's files over a
  site whose engine was edited or lost. REFUSED when the
  versions differ.

## The tidy gate is changed-code-only, deliberately

`t/lint/06-tidy.t` runs `tools/tidy-check.pl`, which flags only lines a change
touched since the last release tag - not the whole tree. The existing tree keeps
its hand-formatting.

Written down here because it is surprising: running `perltidy` across the
repository produces a long list of files that are **not** defects and that the
project has decided against reformatting. A reviewer who does that and files the
result has measured a standard this project does not hold. New files should be
tidied wholesale; existing ones only where you touched them.

### Backup format

Pre-upgrade tarball at
`{docroot}/lazysite/backups/lazysite-backup-{YYYYMMDD-HHMMSS}-pre-{new-version}.tar.gz`.
Contains every file listed in the pre-upgrade
`.install-state.json` plus the state file itself. `tar`
shells out; backup paths are absolute (captured via
`--absolute-names`). Extract uses relative mode (no
`--absolute-names`) into a temp dir, and `install.pl`
iterates the state file's keys to copy each file to its
real destination.

Retention: `backup_retention` in `lazysite.conf`, default 3, set on the Site config page ("Backups to keep"); one reader for every kind of backup - manual, pre-restore, theme and layout snapshots (SM753); 0 keeps all.
0 keeps all; negative is an error.

### Imperative post-steps

A few steps can't be captured declaratively in the manifest:

- `cgi-bin` symlinks for `form-handler.pl` and
  `payment-demo.pl` (Apache routes `/cgi-bin/<name>.pl` at
  the plugin files under `../plugins/`).
- Duplicating the manager CSS to a web-accessible path.
- Seeding `auth/users`, `auth/groups`, `nav.conf`, and
  `lazysite.conf` from their `.example` copies on fresh
  install.
- SGID on `{docroot}/lazysite/` so files created there
  inherit the group.

These stay as named subs inside `install.pl` rather than
growing the manifest schema. The manager CSS duplicate and
the `cgi-bin` symlinks are deliberately NOT tracked in
`.install-state.json` - they are derived from manifest-tracked
sources and rebuilt on every run, so tracking them would
cause a false "in stored but not in manifest" match on the
next upgrade.

### Restore

`install.pl --restore` takes the system back to a backed-up
state - reached by an operator as
`lazysite backups --docroot D --restore`. Without
`--backup PATH`, it picks the most recent backup. Restore:

- Extracts the backup to a temp dir.
- Reads the backup's `.install-state.json`.
- For each file listed there, copies the backup content to
  the real destination, replacing whatever is there.
- Writes the backup's state file as the current state.
- Clears `{docroot}/lazysite/cache/` (rendered HTML may
  reference state that no longer matches).
- Leaves runtime state (auth users, logs, edit locks) alone.

No cascading-backup on restore: if you're restoring, you've
already decided.

### --dry-run

Prints the plan without touching the filesystem. Useful
before an upgrade to see which files will be preserved,
overwritten, or removed.
