#!/bin/bash
# tools/commit.sh - commit CC's in-place working-tree edits to
# origin/main. Replaces the rsync+commit portion of the old
# pre-release.sh + make-release.sh flow.
#
# SM063 split: this script handles ONLY the transfer of CC's edits
# to origin/main. Release (tag, tarball, SBOM check) is in
# tools/release.sh and runs independently.
#
# SM070 update: the /home/claude/lazysite sandbox + rsync arrangement
# was retired 2026-05-22 (see CLAUDE.md). CC now edits the working
# tree in place at /srv/projects/lazysite, so there is no sandbox to
# rsync from. This script commits the in-place tree directly. The
# previous version rsynced --delete from a sandbox copy that is now a
# stale snapshot - running it would have reverted the tree. That step
# is removed.
#
# Preconditions (verified, abort with clear message on any failure):
#   - /srv/projects/lazysite is a git working tree.
#   - On branch main.
#   - main is up to date with origin/main.
#   - CC's .commit-message.md is present at the repo root.
#
# Flow:
#   1. git add -A; git commit -F .commit-message.md; git push.
#      (.commit-message.md is gitignored, so it is never staged.)
#   2. Delete .commit-message.md so the next session starts clean.
#
# No tag, no tarball, no SBOM rebuild, no version bump - those all
# live in release.sh.
set -e

DEST=/srv/projects/lazysite
MSG_FILE="$DEST/.commit-message.md"

# --- preconditions ---

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

echo "==> Fetching origin/main to verify up-to-date"
git -C "$DEST" fetch origin main

LOCAL_SHA=$(git -C "$DEST" rev-parse main)
REMOTE_SHA=$(git -C "$DEST" rev-parse origin/main)
if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
    echo "commit.sh: main ($LOCAL_SHA) is not at origin/main ($REMOTE_SHA)" >&2
    echo "commit.sh: pull or reset before running." >&2
    exit 1
fi

# --- commit ---

# The in-place working tree is expected to carry CC's edits. If it is
# clean there is nothing to do - leave the message file for a later
# run rather than committing an empty change.
DIRTY=$(git -C "$DEST" status --porcelain)
if [ -z "$DIRTY" ]; then
    echo "commit.sh: working tree clean - nothing to commit."
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

# --- cleanup ---

rm -f "$MSG_FILE"
echo "==> Removed $MSG_FILE (next session starts clean)"
