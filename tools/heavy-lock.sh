#!/usr/bin/env bash
# SM1083: ONE heavy lock. Source this and call: heavy_lock ROOT WHO wait|nowait
# Taken by the release gate, coverage.sh run alone and tools/suite.sh, so two
# heavy jobs never overlap. The lock lives under the git COMMON dir (shared by
# the main checkout and every worktree); a holder writes who it is beside it.
# A nested heavy job (the gate's own coverage stage) sees LAZYSITE_HEAVY_HELD=1
# and does not lock again. Returns 0 held, 3 busy (nowait), 2 cannot lock.
heavy_lock_path() {
    if [ -n "${LAZYSITE_HEAVY_LOCK:-}" ]; then
        echo "$LAZYSITE_HEAVY_LOCK"
        return 0
    fi
    local c
    c=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || c="$1/.git"
    echo "$c/lazysite-heavy.lock"
}
heavy_lock() {
    [ "${LAZYSITE_HEAVY_HELD:-}" = 1 ] && return 0
    local lock note
    lock=$(heavy_lock_path "$1")
    note="$lock.holder"
    exec 7>>"$lock" || return 2
    if ! flock -n 7; then
        echo "heavy: $2 finds the heavy lock held by: $(cat "$note" 2>/dev/null || echo unknown)" >&2
        [ "${3:-wait}" = nowait ] && return 3
        echo "heavy: $2 waiting for it." >&2
        flock 7 || return 2
    fi
    printf '%s (pid %s, since %s)\n' "$2" "$$" "$(date '+%F %T')" >"$note"
    export LAZYSITE_HEAVY_HELD=1
    return 0
}
