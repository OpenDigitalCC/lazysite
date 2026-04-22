# Development

Developer-facing notes for the lazysite repo. User-facing docs live
under `starter/docs/` and ship inside every installation.

## Working with CC

The development assistant produces deliverables in a sandbox
working tree. The operator (Stuart) rsyncs that tree into the
project environment, reviews, and ships.

### Rsyncing CC's deliverables

From CC's sandbox working tree to your dev environment:

```
rsync -av --delete --exclude-from=.rsyncignore \
    /path/to/cc-sandbox/ \
    /srv/projects/lazysite/
```

The `.rsyncignore` file at repo root lists workflow and operator
state that should not cross the rsync boundary. The two main
categories:

- **Project version state.** `VERSION` and `NEXT_VERSION` are
  owned by the operator. CC's sandbox values are post-rebuild
  state and may not match what you want to ship next.
- **Runtime operator conf.** `lazysite.conf`, `nav.conf`, the
  forms `*.conf` files, and auth state files are per-install
  operator state. CC's sandbox values are scratch test data.

The `.rsyncignore` also excludes generated build artefacts
(`dist/lazysite-*.tar.gz`, `release-manifest.json`, `sbom.json`)
because your `make-release.sh --auto` run regenerates them
locally from the rsync'd source.

Two CC-authored files are **not** excluded because they are
the session's deliverables for the next release:

- `.release-notes.md` - release notes body, consumed by
  `make-release.sh --auto`. See [Release notes
  convention](#release-notes-convention).
- `.release-prep.sh` - commit-side actions that rsync cannot
  replay (git index operations, classification patches, and
  similar). See [Release preparation](#release-preparation).

`--delete` handles files CC removed during the session (e.g.
plugin files moved to new locations during D022). Without
`--delete`, removed files linger in your dev tree and confuse
the next release. The `--exclude-from` patterns are honoured
under `--delete` too - excluded files on your side are
preserved.

### Release prep convention (for CC)

When a session needs commit-side work that the rsync alone
cannot replay - for example, untracking a file that is
transitioning to gitignored state, or patching
`dist/config/classification.json` for a new top-level file -
CC writes `.release-prep.sh` at repo root in addition to
the usual deliverables.

The file is a short bash script with:

- `set -e` at the top.
- Each action block commented with what and why.
- Idempotent guards (e.g. `git ls-files --error-unmatch`, `jq`
  `| unique`, existence checks) so re-running is safe.
- No long-running or interactive operations.

`pre-release.sh` displays the file, asks for confirmation
(unless `--auto`), and executes it before the release proper.
`make-release.sh --auto` removes it on successful push.

## Releasing

Cutting a release produces three artefacts in one commit:

- `dist/lazysite-<version>.tar.gz` and its `.sha256` sidecar.
- `release-manifest.json` at repo root: every shipped file with its
  SHA-256, size, classification bucket, and install target. This is
  what the upgrade-safe installer (D021c) will consume.
- `sbom.json` at repo root: CycloneDX 1.6 SBOM covering source
  files and direct runtime dependencies.

The front door is `./pre-release.sh`. It rsyncs from CC's
sandbox, applies release-prep actions (if any), shows the
working-tree state and release notes, previews the release
version, and on confirmation runs `make-release.sh --auto`.

### Prepare

1. Review `NEXT_VERSION`. Edit for minor or major bumps if the next
   release isn't just a patch. The default after a release is
   `VERSION+1` on the patch field.
2. No need to commit CC's session changes first. `pre-release.sh`
   rsyncs them into the working tree and `make-release.sh --auto`
   absorbs them into the release commit via `git add -A`.

### Release command

```
./pre-release.sh
```

Prompts twice:

- **Prep actions** (only if `.release-prep.sh` is present): shows
  the script, asks to apply.
- **Release**: shows target version, pre-release commit SHA, first
  line of release notes, next version. Asks to proceed.

On confirmation, builds, commits, tags, bumps `NEXT_VERSION`, and
pushes - all in one go. `.release-notes.md` and
`.release-prep.sh` are deleted on successful push so the next
session starts clean.

For unattended release (skips both confirmations):

```
./pre-release.sh --auto
```

### Manual / debugging path

`make-release.sh --auto` can be run directly. It absorbs
uncommitted changes via `git add -A`, same as when invoked via
`pre-release.sh`.

`make-release.sh` without `--auto` stops after the build and
prints the two-commit sequence for you to run by hand; in this
mode it requires a clean tree (the manual-operator-driven
precondition). `--allow-dirty` exists as a one-off bootstrap
override when even a clean tree cannot be arranged (first
release of a new feature). `--allow-dirty` is incompatible with
`--auto` - the latter already handles dirty trees correctly.

### Release preparation

When CC's session requires commit-side actions that rsync
cannot replay (git index operations, classification patches,
gitignore edits, and similar), CC writes `.release-prep.sh`
at repo root alongside the usual rsynced changes.

`pre-release.sh` detects the file after rsync, displays its
contents, and prompts for confirmation before executing it -
after rsync and before the release proper. In `--auto` mode
the prompt is skipped (the operator has explicitly opted into
unattended release).

Prep scripts are idempotent by convention. Each action block
has a guard (existence check, `jq` unique dedup, and so on)
so re-runs are safe.

The file is consumed on successful release: deleted by
`make-release.sh --auto` alongside `.release-notes.md` after
the push succeeds. Any failure path (commit, tag, or push
failure) preserves the file so the operator can re-run the
release without re-authoring prep.

### Release notes convention

The development assistant writes release notes to
`.release-notes.md` at repo root as part of each dev session's
deliverables. The file is gitignored - it is workflow state, not
part of the project's history.

`make-release.sh --auto` detects the file automatically and
treats it as if `--notes-file .release-notes.md` had been passed.
On successful push, the file is deleted so the next release
cannot silently reuse these notes.

File format: the entire file becomes the body of the release
commit message. Convention is a one-line title-style first line
(under ~72 chars is a nice-to-have, not enforced), a blank line,
then a markdown body. Example:

```
Plugin restructure and install.sh alignment

Plugins moved from repo root / tools/ into plugins/, dropping
the lazysite- prefix. install.sh now catches up with the
release manifest.

Breaking changes: form-handler and payment-demo CGI URLs.
See UPGRADE.md.
```

### Release-notes precedence

`--auto` chooses the release notes source in this order:

1. **`--notes-file PATH`** explicitly given on the command line:
   use that file. Validated upfront (readable, non-empty).
2. **`.release-notes.md` at repo root**: used implicitly. Deleted
   on successful push.
3. **Interactive prompt**: falls through to a single-capture
   prompt (markdown, end with Ctrl-D). Empty notes are rejected;
   Ctrl-C / EOF aborts cleanly, removing the just-built tarball
   and leaving `VERSION` / `NEXT_VERSION` unchanged.

If you want to cut a release without going through CC (or to
override CC's notes), either edit `.release-notes.md` before
running `--auto`, or delete it and let `--auto` prompt
interactively.

### Commit message shape

The release commit message has the form:

```
release: 0.2.1

<full contents of .release-notes.md>
```

Subject line is always `release: X.Y.Z`. The first line of the
notes file becomes the first body line, visible in
`git log --oneline` via `--format` expansions and on GitHub's
release-page preview.

### Release topology

Each release produces two commits on main:

- `release: X.Y.Z` - tagged `vX.Y.Z`. Contains the shipped tree:
  `VERSION=X.Y.Z`, `NEXT_VERSION=X.Y.Z`, the generated manifest
  and SBOM, and the tarball / checksum under `dist/`.
- `chore: bump NEXT_VERSION to X.Y.Z+1` - immediately follows
  the release commit. Bumps `NEXT_VERSION` only.

`git checkout vX.Y.Z` reproduces the exact shipped tree. Linear
history: `git log main` shows both commits in sequence; the tag
is a direct ancestor of the branch tip.

### Evaluation-ramp smoke test

Before signing off the tarball, `make-release.sh` extracts it to a
temp directory, starts `tools/lazysite-server.pl` against
`starter/` on an unused port, and `curl`s the root URL. A non-200
response or a missing expected string in the body aborts the
release. This catches regressions that would break the
"download, extract, run" evaluation path.

If the smoke test fails, the tarball is not signed off but it is
still present at `dist/lazysite-<version>.tar.gz` so you can
reproduce the failure. Dev-server output is in the temp dir
that the script reports; a successful run cleans it up.

### Strict dependency check

`make-release.sh` runs `tools/manifest-to-sbom.pl --strict`. This:

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

4. Run `./make-release.sh` (or just
   `tools/manifest-to-sbom.pl --strict`) to confirm it passes.

If `license` is genuinely uncertain, use `"UNKNOWN"` and flag in
your commit message. Do not guess.

### Files involved

| File | Role |
|---|---|
| `VERSION` | Current release. Updated by `make-release.sh`. |
| `NEXT_VERSION` | What the next release will build. Operator-editable. |
| `release-manifest.json` | File catalogue with SHA-256 and install targets. |
| `sbom.json` | CycloneDX SBOM covering source + direct deps. |
| `tools/build-manifest.pl` | Manifest generator. |
| `tools/manifest-to-sbom.pl` | SBOM generator + strict dep check. |
| `dist/config/classification.json` | Rules mapping repo paths to install targets and buckets. |
| `dist/config/sbom-deps.json` | Curated metadata (license, distro packages, used_by) for every module the code imports. |
| `dist/` | Release artefacts (tarball, .sha256). Root is gitignored; tarballs force-added. `dist/config/` is tracked. |
| `make-release.sh` | Orchestrator. |

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
