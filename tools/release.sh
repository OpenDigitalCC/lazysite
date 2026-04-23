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
STAGE=/tmp/lazysite-release-$$

# --- arg parse ---

VERSION=""
NOTES_FILE=""
COMMIT_REF="origin/main"

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
        -h|--help)
            sed -n '2,22p' "$0" | sed 's/^# \?//'
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

echo "==> Fetching origin tags"
git -C "$ORIGIN" fetch --tags origin

if git -C "$ORIGIN" rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
    echo "release.sh: tag $TAG already exists locally" >&2
    exit 1
fi

if git -C "$ORIGIN" ls-remote --tags origin "refs/tags/$TAG" | grep -q "$TAG"; then
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

# --- run tests ---

echo "==> Running full test suite"
if ! prove -r "$STAGE/t/"; then
    echo "release.sh: test suite failed; not releasing." >&2
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

# --- build tarball ---

DIST_DIR="$STAGE/dist"
TARBALL="$DIST_DIR/lazysite-$VERSION.tar.gz"

mkdir -p "$DIST_DIR"

# Use git archive against the target SHA. This captures the COMMIT
# state exactly - staging dir edits (if any) don't leak in.
echo "==> Building tarball $TARBALL"
git -C "$STAGE" archive --format=tar.gz --prefix="lazysite-$VERSION/" \
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

echo "==> Tagging $TAG on $TARGET_SHA in origin repo"
# Tag is created in the ORIGIN working tree so it's immediately
# pushable. The staging clone is throwaway.
git -C "$ORIGIN" tag -a "$TAG" -F "$ANNOT_FILE" "$TARGET_SHA"

echo "==> Pushing tag $TAG"
git -C "$ORIGIN" push origin "$TAG"

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
