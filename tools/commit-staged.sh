#!/bin/bash
# tools/commit-staged.sh MESSAGE-FILE - commit what is staged, then say what landed.
#
# SM829 item 3. Two of the nine release-path slips were `A && B` or `A | tail`
# where B's output hid A's result: a commit reported that never happened, and a
# commit made over a lint that had failed. Both read the LAST command's output
# and took it for the first one's.
#
# So this is the commit and its own report, in one command. It commits with
# `git commit -F`, then reads HEAD back rather than trusting the exit status: a
# commit is reported only when HEAD moved, and then as the SHA and subject that
# actually landed, on the branch it landed on. Anything else - nothing staged, a
# hook that refused, a HEAD that did not move - is NOT COMMITTED, with the
# reason, and a non-zero exit, so nothing chained after it runs.
set -u
cd "$(dirname "$0")/.." || exit 2

MSG=${1:-}
if [ -z "$MSG" ] || [ ! -f "$MSG" ]; then
    echo "usage: tools/commit-staged.sh MESSAGE-FILE (the message as a file, never inline)" >&2
    exit 2
fi

BRANCH=$(git branch --show-current)
[ -n "$BRANCH" ] || BRANCH="(detached)"
BEFORE=$(git rev-parse -q --verify HEAD || echo none)

if git diff --cached --quiet; then
    echo "NOT COMMITTED on $BRANCH: nothing is staged" >&2
    exit 1
fi

git commit -F "$MSG"
RC=$?
AFTER=$(git rev-parse -q --verify HEAD || echo none)

if [ "$RC" -ne 0 ] || [ "$BEFORE" = "$AFTER" ]; then
    echo "NOT COMMITTED on $BRANCH: git commit exited $RC and HEAD is still ${BEFORE:0:8} - read the lines above" >&2
    exit 1
fi

echo "COMMITTED $(git log -1 --format='%h %s') on $BRANCH"
if ! git diff --quiet; then
    echo "  unstaged changes remain - they are not in this commit"
fi
exit 0
