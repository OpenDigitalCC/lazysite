#!/usr/bin/env bash
# SM1083: tools/preflight.sh HEAVY [STAGE_BASE]  |  tools/preflight.sh JOBS
#   HEAVY  refuse to START a heavy job on a host that cannot hold it. One line,
#          naming the failed condition, exit 3 = "not now": a caller treats it
#          as a SKIP, never a failure. Exit 0 = go.
#   JOBS   print the guarded LAZYSITE_COVER_JOBS: 4 when MemAvailable >= 8 GB, else 2.
# THRESHOLDS LIVE HERE, overridable by env (tests): LAZYSITE_PF_MIN_MEM_KB,
# LAZYSITE_PF_MAX_SWAP_KB, LAZYSITE_PF_MIN_DISK_KB, LAZYSITE_PF_MIN_INODES,
# LAZYSITE_PF_JOBS_MEM_KB; LAZYSITE_PF_MEMINFO names another meminfo file.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tools/heavy-lock.sh"
MIN_MEM_KB=${LAZYSITE_PF_MIN_MEM_KB:-5242880}
MAX_SWAP_KB=${LAZYSITE_PF_MAX_SWAP_KB:-1048576}
MIN_DISK_KB=${LAZYSITE_PF_MIN_DISK_KB:-3145728}
MIN_INODES=${LAZYSITE_PF_MIN_INODES:-600000}
JOBS_MEM_KB=${LAZYSITE_PF_JOBS_MEM_KB:-8388608}
MEMINFO=${LAZYSITE_PF_MEMINFO:-/proc/meminfo}
mem=$(awk '/^MemAvailable:/{print $2}' "$MEMINFO")
mem=${mem:-0}
case "${1:-}" in
    JOBS)
        if [ "$mem" -ge "$JOBS_MEM_KB" ]; then echo 4; else echo 2; fi
        exit 0
        ;;
    HEAVY) ;;
    *)
        echo "usage: preflight.sh HEAVY [STAGE_BASE] | JOBS" >&2
        exit 2
        ;;
esac
notnow() {
    echo "preflight: not now - $*"
    exit 3
}
swt=$(awk '/^SwapTotal:/{print $2}' "$MEMINFO")
swf=$(awk '/^SwapFree:/{print $2}' "$MEMINFO")
swap=$((${swt:-0} - ${swf:-0}))
[ "$mem" -ge "$MIN_MEM_KB" ] || notnow "MemAvailable $((mem / 1024)) MB is under $((MIN_MEM_KB / 1024)) MB"
[ "$swap" -le "$MAX_SWAP_KB" ] || notnow "swap in use $((swap / 1024)) MB is over $((MAX_SWAP_KB / 1024)) MB"
base=${2:-${LAZYSITE_STAGE_DIR:-/var/tmp/lazysite-stage}}
while [ ! -d "$base" ] && [ "$base" != / ]; do base=$(dirname "$base"); done
free=$(df -Pk "$base" | awk 'NR==2{print $4}')
ino=$(df -Pi "$base" | awk 'NR==2{print $4}')
[ "${free:-0}" -ge "$MIN_DISK_KB" ] || notnow "stage base $base has $((${free:-0} / 1024)) MB free, under $((MIN_DISK_KB / 1024)) MB"
[ "${ino:-0}" -ge "$MIN_INODES" ] || notnow "stage base $base has ${ino:-0} free inodes, under $MIN_INODES"
if [ "${LAZYSITE_HEAVY_HELD:-}" != 1 ]; then
    lock=$(heavy_lock_path "$ROOT")
    if [ -e "$lock" ] && ! flock -n "$lock" true; then
        notnow "another heavy job holds the heavy lock: $(cat "$lock.holder" 2>/dev/null || echo unknown)"
    fi
fi
exit 0
