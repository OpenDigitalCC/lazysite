#!/bin/bash
# pre-release.sh - Sync CC's sandbox and prepare for release.
#
# Replaces rsync-from-source.sh. Performs:
#   1. rsync from CC sandbox to this deployment
#   2. Show git status after sync
#   3. Show .release-notes.md contents (what --auto will commit)
#   4. Prompt for release, run make-release.sh --auto on yes
#
# Exclusions live in .rsyncignore at repo root.
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

# 2. git status
echo "==> Post-sync working tree state"
cd "$DEST"
git status --short
echo ""

# 3. .release-notes.md preview
echo "==> .release-notes.md"
if [ -f .release-notes.md ]; then
    cat .release-notes.md
else
    echo "(none - interactive prompt will be used by --auto)"
fi
echo ""

# 4. Release decision
if [ "$SYNC_ONLY" = "1" ]; then
    echo "==> Sync complete. Skipping release (--sync-only)."
    exit 0
fi

if [ "$AUTO_RELEASE" = "1" ]; then
    echo "==> Running make-release.sh --auto"
    exec ./make-release.sh --auto
fi

read -r -p "==> Proceed with release? [y/N] " ans
case "$ans" in
    y|Y|yes|YES)
        exec ./make-release.sh --auto
        ;;
    *)
        echo "==> Aborted. Run ./make-release.sh --auto manually when ready."
        exit 0
        ;;
esac
