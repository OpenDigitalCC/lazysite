#!/bin/bash
# tools/commit.sh - rsync CC's sandbox into the working tree, commit,
# push main. Replaces the rsync+commit portion of the old
# pre-release.sh + make-release.sh flow.
#
# SM063 split: this script handles ONLY the transfer from CC's
# sandbox to origin/main. Release (tag, tarball, SBOM check) is in
# tools/release.sh and runs independently.
#
# Preconditions (verified, abort with clear message on any failure):
#   - /srv/projects/lazysite working tree is clean (no uncommitted
#     changes, no untracked non-ignored files).
#   - On branch main.
#   - main is up to date with origin/main.
#   - CC's sandbox has .commit-message.md ready.
#
# Flow:
#   1. rsync /home/claude/lazysite/ to /srv/projects/lazysite/
#      (excluding .git and .commit-message.md itself).
#   2. Abort if rsync produced no net changes.
#   3. git add -A; git commit -F <message>; git push.
#   4. Delete CC's .commit-message.md so the next session starts
#      clean.
#
# No tag, no tarball, no SBOM rebuild, no version bump - those all
# live in release.sh.
set -e

SOURCE=/home/claude/lazysite
DEST=/srv/projects/lazysite
MSG_FILE="$SOURCE/.commit-message.md"

# --- preconditions ---

if [ ! -d "$SOURCE" ]; then
    echo "commit.sh: CC sandbox not found at $SOURCE" >&2
    exit 1
fi

if [ ! -d "$DEST/.git" ]; then
    echo "commit.sh: not a git working tree at $DEST" >&2
    exit 1
fi

if [ ! -f "$MSG_FILE" ]; then
    echo "commit.sh: no commit message prepared at $MSG_FILE" >&2
    echo "commit.sh: CC is responsible for writing this file." >&2
    exit 1
fi

BRANCH=$(git -C "$DEST" rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "main" ]; then
    echo "commit.sh: $DEST is on branch '$BRANCH', not main" >&2
    exit 1
fi

DIRTY=$(git -C "$DEST" status --porcelain)
if [ -n "$DIRTY" ]; then
    echo "commit.sh: $DEST has uncommitted changes:" >&2
    echo "$DIRTY" >&2
    echo "commit.sh: aborting. Clean the tree before running." >&2
    exit 1
fi

echo "==> Fetching origin/main to verify up-to-date"
git -C "$DEST" fetch origin main

LOCAL_SHA=$(git -C "$DEST" rev-parse main)
REMOTE_SHA=$(git -C "$DEST" rev-parse origin/main)
if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
    echo "commit.sh: main ($LOCAL_SHA) is not at origin/main ($REMOTE_SHA)" >&2
    echo "commit.sh: pull or reset before running." >&2
    exit 1
fi

# --- rsync ---

# Exclusions: use the repo's .rsyncignore if present (legacy
# convention), plus explicit excludes for .git and the commit
# message file itself.
RSYNC_IGNORE=""
if [ -f "$DEST/.rsyncignore" ]; then
    RSYNC_IGNORE="--exclude-from=$DEST/.rsyncignore"
fi

echo "==> Syncing $SOURCE/ -> $DEST/"
rsync -av --delete \
    --exclude=.git \
    --exclude=.commit-message.md \
    $RSYNC_IGNORE \
    "$SOURCE/" "$DEST/"
echo ""

# --- commit ---

POST_DIRTY=$(git -C "$DEST" status --porcelain)
if [ -z "$POST_DIRTY" ]; then
    echo "commit.sh: no changes after rsync - nothing to commit."
    echo "commit.sh: leaving $MSG_FILE in place for a future run."
    exit 0
fi

echo "==> Working tree changes:"
git -C "$DEST" status --short
echo ""

echo "==> Commit message:"
sed 's/^/    /' "$MSG_FILE"
echo ""

git -C "$DEST" add -A
git -C "$DEST" commit -F "$MSG_FILE"
git -C "$DEST" push origin main

NEW_SHA=$(git -C "$DEST" rev-parse --short HEAD)
SUMMARY=$(head -n 1 "$MSG_FILE")

echo ""
echo "==> Committed $NEW_SHA: $SUMMARY"
echo "==> Pushed to origin/main"

# --- cleanup CC's sandbox ---

rm -f "$MSG_FILE"
echo "==> Removed $MSG_FILE (next session starts clean)"
