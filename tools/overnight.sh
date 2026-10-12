#!/bin/bash
# tools/overnight.sh - the 00:30 run: the queued handoffs, then the nightly suite.
#
#   bash tools/overnight.sh            # what cron runs
#   bash tools/overnight.sh --queue WORKTREE TIP [--full|--release]
#                                      # add a handoff to tonight's queue
#
# SM1061. The release manager ruled on 2026-10-12 that a handoff too heavy for
# the working day runs overnight, and that the whole suite runs nightly on main
# as a safety net ("after midnight"). This is both, in that order:
#
#   1. THE QUEUE, tmp/overnight/queue.txt in the main checkout: one line per
#      stack, `WORKTREE TIP [--full|--release]`. The run takes the whole queue
#      (lines queued while it runs wait for the next night), checks TIP out in
#      WORKTREE and runs `tools/handoff.sh --stack main [FLAG]` there, one at a
#      time, under nice 19 and idle I/O. The READY / NOT READY lines go to
#      tmp/overnight/results-DATE.txt, each run's whole output beside it in
#      tmp/overnight/handoff-DATE-TIP.log.
#   2. THE NIGHTLY SUITE, `tools/suite.sh --nightly`: main's tip, in its own
#      worktree, through the host-wide suite lock; on a failure it files a report
#      in the project inbox.
#
# One run at a time: a second overnight run finds tmp/overnight/.runner.lock
# held and logs a skip rather than queueing. The handoffs do not hold the suite
# lock themselves - a queued `--full` handoff takes it through tools/suite.sh,
# and holding it here as well would have that handoff wait for ever on its own
# runner. Files in tmp/overnight older than 14 days are removed.
#
# Exit 0 when the run finished (whatever it found - the results file says);
# 2 on a bad argument.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
COMMON=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir) || {
  echo "overnight: $ROOT is not in a git repository" >&2
  exit 2
}
STATE=$(dirname "$COMMON")
D="$STATE/tmp/overnight"
Q="$D/queue.txt"
mkdir -p "$D"

if [ "${1:-}" = --queue ]; then
  [ $# -ge 3 ] || {
    echo "overnight: --queue needs WORKTREE TIP [--full|--release]" >&2
    exit 2
  }
  case "${4:-}" in
    '' | --full | --release) ;;
    *)
      echo "overnight: the flag is --full or --release, not '$4'" >&2
      exit 2
      ;;
  esac
  [ -d "$2" ] || {
    echo "overnight: no worktree at $2" >&2
    exit 2
  }
  echo "$2 $3${4:+ $4}" >>"$Q"
  echo "overnight: queued $3 in $2${4:+ ($4)} for tonight"
  exit 0
elif [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
  sed -n '2,31p' "$0" | sed 's/^# \?//'
  exit 0
elif [ -n "${1:-}" ]; then
  echo "overnight: unknown argument '$1' (see --help)" >&2
  exit 2
fi

DAY=$(date +%F)
RES="$D/results-$DAY.txt"
stamp() { echo "$(date '+%T') $*" >>"$RES"; }

exec 8>>"$D/.runner.lock"
if ! flock -n 8; then
  stamp "another overnight run holds $D/.runner.lock; skipped"
  exit 0
fi

quiet=()
command -v nice >/dev/null 2>&1 && quiet+=(nice -n 19)
command -v ionice >/dev/null 2>&1 && quiet+=(ionice -c3)

# --- 1. the queued handoffs ----------------------------------------------------
if [ -s "$Q" ]; then
  TAKEN="$D/queue-taken-$DAY.txt"
  cat "$Q" >>"$TAKEN"
  : >"$Q"
  while read -r wt tip flag; do
    [ -n "$wt" ] || continue
    out="$D/handoff-$DAY-$tip.log"
    stamp "== $tip in $wt${flag:+ ($flag)}"
    if ! git -C "$wt" checkout -q "$tip" >"$out" 2>&1; then
      echo "NOT RUN: $tip - could not check it out in $wt (see $out)" >>"$RES"
      continue
    fi
    # shellcheck disable=SC2086  # flag is one word or none
    "${quiet[@]}" bash "$wt/tools/handoff.sh" --stack main $flag >>"$out" 2>&1 8>&- </dev/null
    grep -E '^(READY FOR REVIEW|NOT READY|handoff: FAIL)' "$out" >>"$RES" \
      || echo "NO VERDICT: $tip (see $out)" >>"$RES"
  done <"$TAKEN"
else
  stamp "no queued handoffs"
fi

# --- 2. the nightly suite ------------------------------------------------------
stamp "nightly suite: tools/suite.sh --nightly"
bash "$ROOT/tools/suite.sh" --nightly 8>&- </dev/null
stamp "nightly suite: exit $? (log in $STATE/tmp/nightly/$DAY.log)"

find "$D" -maxdepth 1 -type f -mtime +14 ! -name queue.txt ! -name .runner.lock -delete
stamp "overnight run finished"
exit 0
