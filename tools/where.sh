#!/bin/bash
# tools/where.sh - where am I, and is it safe to start?
#
# SM829: seven of nine release-path slips in one day were STATE errors, not
# knowledge errors - committing on main, branching from main while my own work
# sat unlanded elsewhere, announcing a branch that was still checked out, writing
# a file onto main after a failed branch creation. Each was preventable by
# looking, and none was prevented by the runbook, which was correct and open at
# the time.
#
# So this answers the question that precedes any work, in one command. It reads
# and never writes.
set -u
cd "$(dirname "$0")/.." || exit 2

BASE=${HANDOFF_BASE:-main}
BRANCH=$(git branch --show-current)
[ -n "$BRANCH" ] || BRANCH="(detached)"
SHA=$(git rev-parse --short HEAD 2>/dev/null || echo '?')
WARN=0

printf 'on          %s (%s)\n' "$BRANCH" "$SHA"

# --- the tree ---------------------------------------------------------------
DIRTY=$(git status --porcelain | wc -l)
if [ "$DIRTY" -gt 0 ]; then
    printf 'tree        %s uncommitted change(s) - handoff will refuse this\n' "$DIRTY"
    git status --porcelain | sed 's/^/              /' | head -8
    WARN=1
else
    printf 'tree        clean\n'
fi

# --- am I somewhere I should not be committing? -----------------------------
if [ "$BRANCH" = "$BASE" ]; then
    if [ "$DIRTY" -gt 0 ]; then
        printf 'CAUTION     you are on %s with uncommitted work. The pre-commit hook\n' "$BASE"
        printf '            will refuse it (SM357). Branch first: git checkout -b claude/<feature>\n'
        WARN=1
    else
        printf 'start here  branch before working: git checkout -b claude/<feature>\n'
    fi
fi

# --- this branch against the base -------------------------------------------
if [ "$BRANCH" != "$BASE" ] && [ "$BRANCH" != "(detached)" ]; then
    AHEAD=$(git rev-list --count "$BASE".."$BRANCH" 2>/dev/null || echo 0)
    BEHIND=$(git rev-list --count "$BRANCH".."$BASE" 2>/dev/null || echo 0)
    printf 'vs %-9s +%s ahead, %s behind\n' "$BASE" "$AHEAD" "$BEHIND"
    if [ "$BEHIND" -gt 0 ]; then
        printf 'CAUTION     %s has moved. Rebase before offering, or the review side\n' "$BASE"
        printf '            reports conflicts on files that have diverged.\n'
        WARN=1
    fi
fi

# --- MY OTHER WORK, which is the one that is never looked at ----------------
OTHERS=""
for b in $(git branch --format='%(refname:short)' | grep '^claude/'); do
    [ "$b" = "$BRANCH" ] && continue
    n=$(git rev-list --count "$BASE".."$b" 2>/dev/null || echo 0)
    [ "$n" -gt 0 ] && OTHERS="$OTHERS $b:$n"
done
if [ -n "$OTHERS" ]; then
    printf 'unlanded    other claude/* branches ahead of %s:\n' "$BASE"
    for e in $OTHERS; do
        printf '              %-52s +%s\n' "${e%:*}" "${e##*:}"
    done
    printf '            check none of it is work you are about to redo or strand.\n'
    WARN=1
else
    printf 'unlanded    nothing else ahead of %s\n' "$BASE"
fi

# --- held by another worktree? ----------------------------------------------
HELD=$(git worktree list --porcelain 2>/dev/null | grep -c '^branch ' || true)
if [ "${HELD:-0}" -gt 1 ]; then
    printf 'worktrees   %s branches are held by worktrees - a held branch cannot be\n' "$HELD"
    printf '            deleted, and handoff cannot release it. git worktree list\n'
fi

# --- did the last handoff judge THIS commit? --------------------------------
if [ -f tmp/handoff-suite.log ]; then
    WHEN=$(date -r tmp/handoff-suite.log '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')
    printf 'last gate   tmp/handoff-suite.log written %s\n' "$WHEN"
    printf '            it judged whatever was committed THEN, not necessarily %s\n' "$SHA"
fi

exit "$WARN"
