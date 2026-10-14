#!/bin/bash
# tools/overnight.sh - the 00:30 run: the queued stacks, tested together as they will land.
#
#   bash tools/overnight.sh            # what cron runs
#   bash tools/overnight.sh --queue WORKTREE TIP [--full|--release]
#                                      # add a stack to tonight's queue
#
# SM1061, SM1062. The release manager ruled on 2026-10-12 that a handoff too
# heavy for the working day runs overnight, and then: "maybe the suite runs on
# its own branch, not main, then the review process checks that in to main".
# So the night tests what is about to land, before it lands:
#
#   THE QUEUE is tmp/overnight/queue.txt in the main checkout: one line per
#   stack, `WORKTREE TIP [FLAG]`. The run takes the whole queue (lines queued
#   while it runs wait for the next night) and hands it to tools/integration.pl,
#   at nice 19 and idle I/O. That releases every queued worktree (detached at
#   main), prechecks each stack, cherry-picks the stacks in queue order onto
#   main in tmp/wt-integration (kept as review/assess/integration), runs ONE
#   whole suite there through tools/suite.sh --tree, and writes the verdict -
#   GREEN with "LAND IN THIS ORDER:" and READY FOR REVIEW lines, or RED with
#   each failing file put down to main, a stack or a clash of two - to
#   tmp/overnight/results-DATE.txt. A red night or a conflict also files a
#   report in the inbox. The whole suite is the integration tree's, so it
#   checks main as well. FLAG is accepted as before and changes nothing now:
#   every stack gets the whole suite, and the bench is the release gate's.
#
#   AN EMPTY QUEUE (or one where every stack is left out) runs the plain
#   nightly instead, `tools/suite.sh --nightly` on main, so main is still
#   checked every night.
#
# One run at a time: a second overnight run finds tmp/overnight/.runner.lock
# held and logs a skip rather than queueing. The whole run keeps to
# $LAZYSITE_NIGHTLY_LIMIT (default 5h). Files in tmp/overnight older than 14
# days are removed.
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
  sed -n '2,36p' "$0" | sed 's/^# \?//'
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

RC=3
if [ -s "$Q" ]; then
  # Tonight's lines, apart from the day's record of everything taken.
  TONIGHT="$D/queue-tonight.txt"
  cp "$Q" "$TONIGHT"
  cat "$TONIGHT" >>"$D/queue-taken-$DAY.txt"
  : >"$Q"
  stamp "integration: tools/integration.pl on $(wc -l <"$TONIGHT") queued stack(s)"
  "${quiet[@]}" perl "$ROOT/tools/integration.pl" --queue "$TONIGHT" --results "$RES" \
    --requeue "$Q" 8>&- </dev/null
  RC=$?
  stamp "integration: exit $RC (0 green, 1 red, 3 nothing integrated, 4 no verdict; log in $D/integration-$DAY.log)"
else
  stamp "no queued stacks"
fi

if [ "$RC" = 3 ]; then
  stamp "nightly suite: tools/suite.sh --nightly"
  bash "$ROOT/tools/suite.sh" --nightly 8>&- </dev/null
  stamp "nightly suite: exit $? (log in $STATE/tmp/nightly/$DAY.log)"
fi

# SM1081: the advisory compatibility tier - the Odoo tests against the installed OOM and OOM's tree. It
# never fails the night and never touches the gate; a failing target files one inbox note.
bash "$ROOT/tools/ext-compat.sh" --night 8>&- </dev/null || true

find "$D" -maxdepth 1 -type f -mtime +14 ! -name queue.txt ! -name .runner.lock -delete
stamp "overnight run finished"
exit 0
