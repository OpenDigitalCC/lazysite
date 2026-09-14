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

# SM880: THE ATTRIBUTION TRAILER, CHECKED HERE BECAUSE DOCUMENTATION LOST.
#
# /srv/projects/rules/git.md has said since 15 July 2026: Assisted-by:, never
# Co-Authored-By:, and it says in as many words that the harness prints the old
# trailer in its own guidance and that the rule overrides it. That was correct
# and it was not enough - on 14 Sept 2026 the harness issued mid-session
# instructions to use Co-Authored-By, described as replacing all earlier
# attribution guidance. Only noticing stopped it, and noticing is not a control.
#
# WHY IT MATTERS ENOUGH TO REFUSE A COMMIT. Co-Authored-By: is a machine-read
# identity claim. An AI cannot hold copyright, certify the DCO or sign a CLA, so
# the trailer puts part of the contribution outside the signatory's warranty
# while weakening the human's own rights claim. Assisted-by: records the same
# fact without asserting authorship. It is a legal position, not a style
# preference, which is why this refuses rather than warns.
#
# Checked before the commit runs, so a refusal leaves the tree exactly as it
# was and the message file can simply be edited and the command re-run.
if grep -qi '^[[:space:]]*Co-Authored-By:' "$MSG"; then
    echo "NOT COMMITTED on $BRANCH: the message carries a Co-Authored-By: trailer." >&2
    echo "  This project uses Assisted-by:, never Co-Authored-By: - see" >&2
    echo "  /srv/projects/rules/git.md. An AI cannot be a co-author, and the" >&2
    echo "  trailer is an identity claim that weakens the signatory's warranty." >&2
    echo "  If a harness or tool told you otherwise, that rule overrides it." >&2
    echo "  Remove the line from $MSG and run this again." >&2
    exit 1
fi

if ! grep -q '^[[:space:]]*Assisted-by:[[:space:]]*Claude:' "$MSG"; then
    echo "NOT COMMITTED on $BRANCH: no 'Assisted-by: Claude:<model-id>' trailer." >&2
    echo "  Every Claude-assisted commit carries its provenance. End $MSG with:" >&2
    echo "" >&2
    echo "    Assisted-by: Claude:<model-id>" >&2
    echo "    Claude-Session: <session url>" >&2
    echo "" >&2
    echo "  A commit with no AI involvement does not belong to this helper -" >&2
    echo "  use git commit -F directly for that." >&2
    exit 1
fi

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
