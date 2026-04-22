#!/bin/bash
# pre-release.sh - Sync CC's sandbox and prepare for release.
#
# Replaces rsync-from-source.sh. Performs:
#   1. rsync from CC sandbox to this deployment
#   2. If .release-prep.sh exists: show it, confirm, execute it
#   3. Show git status after sync + prep
#   4. Show .release-notes.md contents (what --auto will commit)
#   5. Prompt for release, run make-release.sh --auto on yes
#
# Exclusions live in .rsyncignore at repo root. Prep actions
# (.release-prep.sh) are CC-authored per session and consumed on
# successful release.
#
# Flags:
#   --sync-only    Sync and show status, skip release prompt.
#   --auto         Run make-release.sh --auto without prompting.
#   -h, --help     Show this help.

set -e

SOURCE="/home/claude/lazysite/"
DEST="/srv/projects/lazysite/"

SYNC_ONLY=0
AUTO_RELEASE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --sync-only) SYNC_ONLY=1 ;;
        --auto)      AUTO_RELEASE=1 ;;
        -h|--help)
            sed -n '2,18p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown flag: $1" >&2
            echo "Use --help for usage." >&2
            exit 2
            ;;
    esac
    shift
done

# 1. rsync
echo "==> Syncing from $SOURCE"
rsync -av --delete --exclude-from="${DEST}.rsyncignore" \
    "$SOURCE" "$DEST"
echo ""

cd "$DEST"

# 2. SM035: release prep actions (.release-prep.sh)
#
# CC writes .release-prep.sh when the session needs commit-side
# operations that rsync cannot replay (git index edits,
# classification patches, gitignore additions, and similar).
# Show the file, confirm (unless --auto), and execute it before
# release. Idempotency is CC's responsibility: every action
# block should be safe to re-run.
if [ -f .release-prep.sh ]; then
    echo "==> Release prep actions (.release-prep.sh)"
    echo ""
    cat .release-prep.sh
    echo ""

    if [ "$AUTO_RELEASE" = "1" ]; then
        echo "==> --auto: applying prep actions without prompt"
        chmod +x .release-prep.sh
        ./.release-prep.sh
        echo "==> Prep actions applied."
    else
        read -r -p "==> Apply these prep actions? [y/N] " prep_ans
        case "$prep_ans" in
            y|Y|yes|YES)
                chmod +x .release-prep.sh
                ./.release-prep.sh
                echo "==> Prep actions applied."
                ;;
            *)
                echo "==> Aborted (prep actions declined)."
                exit 0
                ;;
        esac
    fi
    echo ""
fi

# 3. git status
echo "==> Post-sync working tree state"
git status --short
echo ""

# 4. .release-notes.md preview
echo "==> .release-notes.md"
if [ -f .release-notes.md ]; then
    cat .release-notes.md
else
    echo "(none - interactive prompt will be used by --auto)"
fi
echo ""

# 5. Release decision
if [ "$SYNC_ONLY" = "1" ]; then
    echo "==> Sync complete. Skipping release (--sync-only)."
    exit 0
fi

# SM036: one-line preview before the confirmation so the operator
# sees exactly what will be built. NEXT_VERSION is the target
# version; the bump commit after release sets NEXT_VERSION to the
# next patch.
REL_VERSION=""
REL_NEXT=""
if [ -f NEXT_VERSION ]; then
    REL_VERSION=$(tr -d ' \t\n\r' < NEXT_VERSION)
fi
if [ -n "$REL_VERSION" ] && [[ "$REL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    IFS='.' read -r _REL_MAJ _REL_MIN _REL_PAT <<< "$REL_VERSION"
    REL_NEXT="$_REL_MAJ.$_REL_MIN.$((_REL_PAT + 1))"
fi
REL_NOTES_FIRST=""
if [ -f .release-notes.md ]; then
    REL_NOTES_FIRST=$(head -n 1 .release-notes.md | tr -d '\r')
fi
PRE_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

echo "==> Ready to release ${REL_VERSION:-?}"
echo "    Commit:  $PRE_SHA  (pre-release)"
if [ -n "$REL_NOTES_FIRST" ]; then
    echo "    Notes:   $REL_NOTES_FIRST"
else
    echo "    Notes:   (none - interactive prompt will run)"
fi
if [ -n "$REL_NEXT" ]; then
    echo "    Next:    $REL_NEXT (bumped after release)"
fi
echo ""

if [ "$AUTO_RELEASE" = "1" ]; then
    echo "==> --auto: running make-release.sh --auto without prompt"
    exec ./make-release.sh --auto
fi

read -r -p "==> Proceed with release? [y/N] " ans
case "$ans" in
    y|Y|yes|YES)
        exec ./make-release.sh --auto
        ;;
    *)
        echo "==> Aborted. Re-run ./pre-release.sh when ready."
        exit 0
        ;;
esac
