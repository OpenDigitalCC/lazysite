#!/bin/bash
# tools/release.sh - cut a tagged release from any commit on main.
#
# SM063 split: this script DOES NOT touch main. It clones the repo
# fresh into a staging dir, checks out the target commit, runs the
# full Perl test suite, verifies the SBOM strictness gate, packages
# a tarball, and tags the commit. The tag is pushed; no commit is
# made on main. Main is unstable; tags are the stable identifiers.
#
# Usage:
#   tools/release.sh [VERSION] [--notes NOTES_FILE] [--commit COMMIT]
#
#   VERSION         optional, e.g. 0.2.19 (semver X.Y.Z). When
#                   omitted, release.sh proposes the next patch bump
#                   from the most recent v*.*.* tag and prompts for
#                   confirmation (SM064). Pass VERSION explicitly to
#                   skip the prompt - useful for non-interactive
#                   runs.
#   --notes FILE    release-notes file. Default: use the target
#                   commit's own commit message.
#   --commit REF    SHA or ref to release. Default: origin/main HEAD.
#   --beta          mark the release 'beta' on the channel ladder
#                   (edge < beta < stable): a bedded-in candidate for
#                   sites that want tested-but-not-yet-certified builds.
#   --final         mark the release 'stable' (alias: --stable) - the
#                   certified customer-rollout channel. Default: 'edge'.
#   --no-fetch      skip the two ORIGIN tag checks (fetch --tags, and the
#                   ls-remote test that vVERSION is not already upstream).
#                   For a build host with no remote credentials: the
#                   whole GATE still runs, and the LOCAL tag check still
#                   runs - only the upstream collision test is deferred
#                   to whoever pushes. It is an explicit flag and never
#                   an automatic fallback, because a precondition that
#                   silently downgrades itself when it cannot run is the
#                   defect class this project keeps removing.
#
# Preconditions:
#   - VERSION (provided or proposed) is a semver string.
#   - Tag vVERSION does not already exist on origin.
#   - dist/config/sbom-deps.json exists in the target commit.
#
# On abort: the staging dir is retained and its path printed so the
# operator can inspect what failed. Clean up with
#   rm -rf /tmp/lazysite-release-$$  (PID is in the printed path).
set -e

ORIGIN=/srv/projects/lazysite

# SM328: where the gate runs, taken from the environment rather than hard-coded.
#
# This was /tmp/lazysite-release-$$. On a host whose /tmp is a tmpfs the gate
# EXHAUSTS ITS INODES - not its bytes. Devel::Cover writes one runs/<id>/
# directory per instrumented PROCESS at ~6 files each, and this suite drives real
# CGI subprocesses rather than mocking them, so a full gate produces hundreds of
# thousands of them. Measured at the failure: 4.8G tmpfs, 139M used (3%), and
# 1048576/1048576 inodes (100%).
#
# Bytes were never the constraint, which is why "14G free on /" was such a
# misleading reading, and why a size-only pre-flight check would have passed
# cheerfully. A larger tmpfs would not have helped either - only more inodes, or
# a filesystem that does not cap them.
#
# tools/lazysite-cli.pl already honours $TMPDIR for its own scratch; this is that
# convention, applied to the tool that needs it most.
STAGE_BASE="${LAZYSITE_STAGE_DIR:-${TMPDIR:-/tmp}}"
KEEP_STAGE=0

# --- arg parse ---

VERSION=""
NOTES_FILE=""
COMMIT_REF="origin/main"
CHANNEL="edge"          # ladder: edge (default) < beta (--beta) < stable (--final)
NO_FETCH=0              # --no-fetch: skip the ORIGIN tag checks (see below)

while [ $# -gt 0 ]; do
    case "$1" in
        --notes)
            NOTES_FILE="$2"
            shift 2
            ;;
        --commit)
            COMMIT_REF="$2"
            shift 2
            ;;
        --final|--stable)
            CHANNEL="stable"
            shift
            ;;
        --beta)
            CHANNEL="beta"
            shift
            ;;
        --no-fetch)
            NO_FETCH=1
            shift
            ;;
        --stage-dir)
            STAGE_BASE="$2"
            shift 2
            ;;
        --keep-stage)
            KEEP_STAGE=1
            shift
            ;;
        -h|--help)
            sed -n '2,27p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        -*)
            echo "release.sh: unknown flag: $1" >&2
            echo "release.sh: run with --help for usage." >&2
            exit 2
            ;;
        *)
            if [ -z "$VERSION" ]; then
                VERSION="$1"
            else
                echo "release.sh: extra argument: $1" >&2
                exit 2
            fi
            shift
            ;;
    esac
done

# SM064: when VERSION is omitted, propose the next patch bump from
# the most recent v*.*.* tag and prompt. Explicit VERSION argument
# bypasses the prompt for non-interactive use.
if [ -z "$VERSION" ]; then
    # Need the repo's tags available. Origin is our source of truth.
    if [ ! -d "$ORIGIN/.git" ]; then
        echo "release.sh: no git repo at $ORIGIN" >&2
        exit 1
    fi
    git -C "$ORIGIN" fetch --tags origin >/dev/null 2>&1 || true

    # `tag -l 'v*.*.*' | sort -V | tail -1` is deterministic across
    # mixed-tag repos in a way `git describe --tags` isn't.
    LAST_TAG=$(git -C "$ORIGIN" tag -l 'v*.*.*' | sort -V | tail -1)
    if [ -z "$LAST_TAG" ]; then
        echo "release.sh: no v*.*.* tags on origin; cannot propose a version." >&2
        echo "release.sh: pass VERSION explicitly for the first release." >&2
        exit 1
    fi

    # Strip leading 'v', split on '.', bump the patch field.
    LAST_VER="${LAST_TAG#v}"
    IFS='.' read -r _M _m _p <<< "$LAST_VER"
    if ! [[ "$_M" =~ ^[0-9]+$ && "$_m" =~ ^[0-9]+$ && "$_p" =~ ^[0-9]+$ ]]; then
        echo "release.sh: latest tag '$LAST_TAG' doesn't look like vX.Y.Z" >&2
        echo "release.sh: pass VERSION explicitly." >&2
        exit 1
    fi
    PROPOSED="$_M.$_m.$((_p + 1))"

    echo "Latest tag: $LAST_TAG"
    read -r -p "Release as $PROPOSED [Y/n/edit]? " ans
    case "$ans" in
        ''|y|Y|yes|YES)
            VERSION="$PROPOSED"
            ;;
        n|N|no|NO)
            echo "release.sh: aborted."
            exit 0
            ;;
        e|E|edit|EDIT)
            read -r -p "Enter version: " edited
            # Strip any leading 'v' to be kind.
            edited="${edited#v}"
            if ! [[ "$edited" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "release.sh: '$edited' is not a valid semver (X.Y.Z). Aborted." >&2
                exit 2
            fi
            VERSION="$edited"
            ;;
        *)
            echo "release.sh: unrecognised response '$ans'. Aborted." >&2
            exit 2
            ;;
    esac
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "release.sh: '$VERSION' is not a valid semver (X.Y.Z)" >&2
    exit 2
fi

TAG="v$VERSION"

# --- precondition: tag not already on origin ---

if [ ! -d "$ORIGIN/.git" ]; then
    echo "release.sh: no git repo at $ORIGIN" >&2
    exit 1
fi

if [ "$NO_FETCH" = 1 ]; then
    echo "==> Skipping origin tag checks (--no-fetch)"
else
    echo "==> Fetching origin tags"
    git -C "$ORIGIN" fetch --tags origin
fi

# The LOCAL check runs either way - it is the one this host can answer.
if git -C "$ORIGIN" rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
    echo "release.sh: tag $TAG already exists locally" >&2
    exit 1
fi

if [ "$NO_FETCH" = 1 ]; then
    echo "release.sh: WARNING - did NOT check whether $TAG already exists on"  >&2
    echo "release.sh:           origin. Whoever pushes must confirm that before" >&2
    echo "release.sh:           pushing the tag, or a burned version is reused." >&2
elif git -C "$ORIGIN" ls-remote --tags origin "refs/tags/$TAG" | grep -q "$TAG"; then
    echo "release.sh: tag $TAG already exists on origin" >&2
    exit 1
fi

# --- precondition: notes file readable if specified ---

if [ -n "$NOTES_FILE" ]; then
    if [ ! -f "$NOTES_FILE" ]; then
        echo "release.sh: notes file not found: $NOTES_FILE" >&2
        exit 1
    fi
fi

# --- stage: fresh clone ---

# SM328: the staging path, and a trap that removes it however this run ends.
#
# Cleanup used to be `rm -rf "$STAGE"` as the last line of the happy path, so any
# failure - a failing test, a refused gate, an interrupt, a power cut, the disk
# filling - left the whole clone behind. Four cuts in a day was enough to exhaust
# a tmpfs, and nothing reclaimed them.
#
# --keep-stage opts out, because a gate failure is exactly when someone wants to
# look inside.
STAGE="$STAGE_BASE/lazysite-release-$$"
cleanup_stage() { [ "$KEEP_STAGE" = 1 ] || rm -rf "$STAGE"; }
trap cleanup_stage EXIT

# Refuse EARLY if the staging filesystem cannot hold a gate run. Inodes as well
# as bytes: bytes were never what ran out, and checking only those would repeat
# the failure this guards against.
mkdir -p "$STAGE_BASE"
# `df -i --output=...` is REFUSED by coreutils - the options are mutually
# exclusive - and the first version of this check used it, so the variable was
# empty and the check silently did nothing. A guard that skips when it cannot
# read its input is the defect this whole file is about, so an unreadable
# reading is now reported rather than passed over.
_free_inodes=$(df --output=iavail "$STAGE_BASE" 2>/dev/null | tail -1 | tr -d ' ')
_free_kb=$(df --output=avail "$STAGE_BASE" 2>/dev/null | tail -1 | tr -d ' ')

case "${_free_inodes:-}" in
    ''|*[!0-9]*)
        echo "release: could not read free inodes for $STAGE_BASE - not checking." >&2
        _free_inodes=""
        ;;
esac

if [ -n "$_free_inodes" ] && [ "$_free_inodes" -gt 0 ] \
   && [ "$_free_inodes" -lt 1200000 ]; then
    echo "release: $STAGE_BASE has only $_free_inodes free inodes." >&2
    echo "  A gate run needs roughly 1.1M: Devel::Cover writes a directory per" >&2
    echo "  instrumented subprocess and this suite spawns them constantly." >&2
    echo "  Point somewhere with more: --stage-dir /srv/tmp, or LAZYSITE_STAGE_DIR." >&2
    exit 5
fi
case "${_free_kb:-}" in ''|*[!0-9]*) _free_kb="" ;; esac
if [ -n "$_free_kb" ] && [ "$_free_kb" -lt 2000000 ]; then
    echo "release: $STAGE_BASE has only $((_free_kb/1024))MB free; ~2GB wanted." >&2
    echo "  Point somewhere larger: --stage-dir /srv/tmp, or LAZYSITE_STAGE_DIR." >&2
    exit 5
fi

echo "==> Staging clone at $STAGE"
git clone --quiet "$ORIGIN" "$STAGE"

# Resolve the target commit inside the staging clone so refs like
# origin/main resolve correctly.
TARGET_SHA=$(git -C "$STAGE" rev-parse "$COMMIT_REF")
echo "==> Target commit: $TARGET_SHA ($COMMIT_REF)"

git -C "$STAGE" checkout --quiet --detach "$TARGET_SHA"

# --- precondition: sbom-deps.json exists at target ---

if [ ! -f "$STAGE/dist/config/sbom-deps.json" ]; then
    echo "release.sh: dist/config/sbom-deps.json missing at $TARGET_SHA" >&2
    echo "release.sh: staging dir retained: $STAGE" >&2
    exit 1
fi

# --- gate tooling must EXIST on a release host ---
# The lint gates skip cleanly on a minimal dev host, which is right for
# `prove` in general but wrong for a release: a missing tool would silently
# skip a quality gate (2026-07-10 review, D2). Refuse loudly instead.
for tool in perlcritic perltidy shellcheck; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "release.sh: gate tool '$tool' is not installed on this host; not releasing." >&2
        echo "release.sh: staging dir retained: $STAGE" >&2
        exit 1
    fi
done

# --- compliance-record currency gate (eight-dimension review 2026-08-14) ---
#
# The review sorted its findings by whether the thing assessed was defended by a
# MECHANISM or maintained by a PERSON, and they separated perfectly: every gate,
# lint and enforced floor passed; every hand-kept compliance record was a
# finding. This gate applies to those records the move this project already made
# four times to hand-maintained lists in its own tests - it replaces a person
# remembering with a build failing.
#
# It runs FIRST because it is instant and it fails on things that take minutes
# to fix, rather than after a 15-minute coverage run. Blocking findings differ by
# channel: a Declaration of Conformity behind the version is advisory on edge and
# blocking on stable, because the declaration attaches to a stable release.
echo "==> lazysite-compliance.pl --check (channel: $CHANNEL)"
if ! perl "$STAGE/tools/lazysite-compliance.pl" --check --channel "$CHANNEL"; then
    echo "release.sh: compliance records are not current for this cut; not releasing." >&2
    echo "release.sh: staging dir retained: $STAGE" >&2
    exit 1
fi

# --- run tests ---

# `cd "$STAGE" && prove -lr t/`, and BOTH halves are load-bearing.
#
# -l is not cosmetic. Without it PERL5LIB is never set, so a test's own
# `use lib "$FindBin::Bin/../lib"` covers the test process and NOT the
# subprocesses it spawns - and several tests drive tools/lazysite-check.pl or a
# dev server as children. Those children searched only the system @INC and died
# on "Can't locate Lazysite/Paths.pm". Five files failed this way, and they
# failed identically at v0.10.8, so the gate has been running the suite in a
# configuration the suite does not support rather than the one every other
# caller uses.
#
# The `cd` is what makes -l safe. -l adds ./lib RELATIVE TO CWD, so running it
# from the invoking directory would put the ORIGIN's lib on @INC while running
# the STAGED tests - a gate quietly testing the developer's working copy
# against the release candidate's tests. That is a worse failure than the one
# being fixed, because it passes.
echo "==> Running full test suite"
if ! ( cd "$STAGE" && prove -lr t/ ); then
    echo "release.sh: test suite failed; not releasing." >&2
    echo "release.sh: staging dir retained: $STAGE" >&2
    exit 1
fi

# --- performance gate (eight-dimension review D4) ---
# Committed baseline in dist/config/bench-baseline.json; fails on a gross
# regression. Costs ~5 seconds, so it runs before the slow coverage gate.

echo "==> bench.pl --check"
if ! perl "$STAGE/tools/bench.pl" --check; then
    echo "release.sh: benchmark regression; not releasing." >&2
    echo "release.sh: staging dir retained: $STAGE" >&2
    exit 1
fi

# --- coverage gate (eight-dimension review D3) ---
# Instrumented re-run of the suite against the declared floors in
# dist/config/coverage-floor. Slow (~10-15 minutes at release cadence);
# converts the recorded coverage evidence from "stale until someone
# remembers" into a per-release fact.

echo "==> coverage.sh --check (instrumented run; ~10-15 minutes)"
if ! bash "$STAGE/tools/coverage.sh" --check; then
    echo "release.sh: coverage below the declared floor; not releasing." >&2
    echo "release.sh: staging dir retained: $STAGE" >&2
    exit 1
fi

# --- build the release manifest ---
# release-manifest.json is generated, not tracked (SM065), so the fresh
# clone has none. Build it from the staged tree before the SBOM gate
# (which reads it) and the tarball (which ships it).

echo "==> build-manifest.pl (channel: $CHANNEL)"
if ! perl "$STAGE/tools/build-manifest.pl" \
        --staged  "$STAGE" \
        --out     "$STAGE/release-manifest.json" \
        --version "$VERSION" \
        --channel "$CHANNEL" ; then
    echo "release.sh: manifest build failed; not releasing." >&2
    echo "release.sh: staging dir retained: $STAGE" >&2
    exit 1
fi

# --- SBOM strictness gate ---

echo "==> manifest-to-sbom.pl --strict"
if ! perl "$STAGE/tools/manifest-to-sbom.pl" --strict \
        --manifest "$STAGE/release-manifest.json" \
        --deps     "$STAGE/dist/config/sbom-deps.json" \
        --out      "$STAGE/sbom.json" \
        --version  "$VERSION" \
        --staged   "$STAGE" ; then
    echo "release.sh: SBOM strictness check failed; not releasing." >&2
    echo "release.sh: staging dir retained: $STAGE" >&2
    exit 1
fi

# --- man pages (generated artefact; the tarball must ship them - review D7) ---

echo "==> Generating man pages"
if ! perl "$STAGE/tools/gen-manpages.pl" "$STAGE/man/man1"; then
    echo "release.sh: man-page generation failed; not releasing." >&2
    echo "release.sh: staging dir retained: $STAGE" >&2
    exit 1
fi
MAN_ADD=()
for m in "$STAGE"/man/man1/*.1; do
    [ -f "$m" ] || continue
    # --add-file stores only the BASENAME; an interleaved --prefix places
    # each page under man/man1/ (restored to the plain prefix afterwards).
    MAN_ADD+=("--prefix=lazysite-$VERSION/man/man1/" "--add-file=man/man1/$(basename "$m")")
done
MAN_ADD+=("--prefix=lazysite-$VERSION/")
if [ "${#MAN_ADD[@]}" -eq 0 ]; then
    echo "release.sh: gen-manpages.pl produced no pages; not releasing." >&2
    echo "release.sh: staging dir retained: $STAGE" >&2
    exit 1
fi

# --- build tarball ---

DIST_DIR="$STAGE/dist"
TARBALL="$DIST_DIR/lazysite-$VERSION.tar.gz"

mkdir -p "$DIST_DIR"

# Use git archive against the target SHA. This captures the COMMIT
# state exactly - staging dir edits (if any) don't leak in.
echo "==> Building tarball $TARBALL"
# release-manifest.json + sbom.json are generated (untracked, SM065), so
# git archive would omit them; --add-file injects them at the tarball
# root (after --prefix, so they land under lazysite-VERSION/). The
# installer reads release-manifest.json from there.
git -C "$STAGE" archive --format=tar.gz \
    --prefix="lazysite-$VERSION/" \
    --add-file=release-manifest.json \
    --add-file=sbom.json \
    "${MAN_ADD[@]}" \
    -o "$TARBALL" "$TARGET_SHA"

SHA256=$(sha256sum "$TARBALL" | awk '{print $1}')
printf "%s  lazysite-%s.tar.gz\n" "$SHA256" "$VERSION" > "$TARBALL.sha256"

echo "==> Tarball sha256: $SHA256"

# --- tag ---

# Annotation source: --notes file if given, otherwise the target
# commit's own message. git tag -a -F reads the annotation from a
# file, so we stage the message into a temp file either way for
# consistency.
ANNOT_FILE="$STAGE/.release-annotation"
if [ -n "$NOTES_FILE" ]; then
    cp "$NOTES_FILE" "$ANNOT_FILE"
else
    git -C "$ORIGIN" log -1 --format=%B "$TARGET_SHA" > "$ANNOT_FILE"
fi

# SM325: refuse to tag a commit that is on no branch.
#
# 0.10.10 was cut twice. The first tag named a branch tip; vcs-review then landed
# that branch onto main with new SHAs, and the tag was left pointing at a commit
# no branch contained. Nothing had been pushed so it cost only a re-cut - but a
# re-cut is a full gate run, and `git branch --contains` answers the question in
# a second.
#
# It matters beyond tidiness: a tag on no branch is a release whose provenance
# cannot be followed from any branch history, and if the tag were ever deleted
# the commit becomes unreachable. Anyone auditing later runs --contains, gets
# nothing, and has to work out whether that is a problem.
#
# A warning rather than a refusal when --no-fetch is set, because on a build host
# with no remote the local branch set may legitimately be incomplete.
if ! git -C "$ORIGIN" branch --contains "$TARGET_SHA" 2>/dev/null | grep -q .; then
    echo "==> WARNING: $TARGET_SHA is on no branch." >&2
    echo "    A tag here records a release whose history no branch contains." >&2
    echo "    This is what a rebase (vcs-review landing a branch) leaves behind:" >&2
    echo "    tag AFTER the branch lands, not before." >&2
    if [ "$NO_FETCH" != 1 ]; then
        echo "    Refusing. Re-run against a commit on a branch, or pass --no-fetch" >&2
        echo "    if this host legitimately has an incomplete branch set." >&2
        exit 4
    fi
    echo "    --no-fetch is set, so continuing - this host may not have every branch." >&2
fi

echo "==> Tagging $TAG on $TARGET_SHA in origin repo"
# Tag is created in the ORIGIN working tree so it's immediately
# pushable. The staging clone is throwaway.
git -C "$ORIGIN" tag -a "$TAG" -F "$ANNOT_FILE" "$TARGET_SHA"

# --no-fetch means this host has no remote credentials, so it cannot push
# either. Skipping it here rather than letting `set -e` kill the run at the last
# step: the previous behaviour left the tarball stranded in the staging
# directory with the artefact copy and cleanup unreached, and reported failure
# for a release that had in fact been built and tagged.
if [ "$NO_FETCH" = 1 ]; then
    echo "==> NOT pushing $TAG (--no-fetch): the tag is local and unpushed."
    echo "    Whoever pushes must first confirm $TAG is not already on origin,"
    echo "    then: git push origin $TAG"
else
    echo "==> Pushing tag $TAG"
    git -C "$ORIGIN" push origin "$TAG"
fi

# --- final artefact copy ---

# Copy the tarball + sha out of staging so the operator has it
# locally after the staging dir is cleaned up.
FINAL_DIST="$ORIGIN/dist"
mkdir -p "$FINAL_DIST"
cp "$TARBALL" "$FINAL_DIST/"
cp "$TARBALL.sha256" "$FINAL_DIST/"

# --- cleanup ---

rm -rf "$STAGE"

echo ""
echo "==> Released $TAG"
printf "    commit:  %s\n" "$TARGET_SHA"
printf "    tag:     %s\n" "$TAG"
printf "    tarball: %s\n" "$FINAL_DIST/lazysite-$VERSION.tar.gz"
printf "    sha256:  %s\n" "$SHA256"
if [ "$NO_FETCH" = 1 ]; then
    printf "    tag:     LOCAL AND UNPUSHED - see the note above\n"
fi
