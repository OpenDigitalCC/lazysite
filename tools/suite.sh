#!/bin/bash
# tools/suite.sh - the one way to run the whole plain suite (SM1061).
#
#   bash tools/suite.sh             # this worktree, now; waits for the lock
#   bash tools/suite.sh --nightly   # current main, in tmp/wt-nightly; skips if locked
#
# Runs `prove -lr -j<nproc> t/`, ONE RUN AT A TIME ON THE HOST. On 2026-10-12
# four agents each ran the whole suite in their handoff at once on an 8-core
# host: the load reached 26-30 and every suite took ~1,950 s instead of
# ~1,080 s. The release manager ruled: a targeted subset (the precheck) on each
# commit and handoff, the whole suite on demand (this script), the whole suite
# required for a release, and an area subset plus a nightly run as safety nets.
#
# THE LOCK lives under the repository's COMMON git dir (`git rev-parse
# --git-common-dir`), so the main checkout and every `git worktree` share it. An
# on-demand run WAITS for the holder rather than failing, and says who holds it,
# from the note the holder writes beside the lock (pid, cwd, branch, start).
# The full output goes to tmp/suite.log in this worktree; what is printed is
# prove's Files= line, or the failures. Exit: prove's status (0 = passed); 2 if
# the lock could not be taken.
#
# --nightly runs the suite on main's tip in a detached worktree it manages
# (tmp/wt-nightly in the main checkout, moved to main each run), under nice and
# ionice where they exist. A nightly run never queues: finding the lock held, it
# logs a line and exits 0, so one night's run cannot overlap the next or run
# into the working day. It stops after $LAZYSITE_NIGHTLY_LIMIT (default 5h,
# so a 00:30 start ends by 05:30). The log is tmp/nightly/DATE.log; the newest
# 14 are kept. On a failure it files DATE-nightly-suite-failed-on-SHA.md in the
# project inbox ($LAZYSITE_NIGHTLY_INBOX overrides) naming the failing files and
# their first failure lines; a pass writes nothing there.
#
#   bash tools/suite.sh --tree DIR  # the worktree DIR, as the nightly runs (SM1062)
#
# --tree runs the suite in DIR, a worktree of this repository that the caller
# has prepared (tools/integration.pl's tmp/wt-integration), with the nightly's
# discipline: nice and ionice, the $LAZYSITE_NIGHTLY_LIMIT stop, and a lock found
# held is a skip - exit 75, naming the holder - never a wait. The log is DIR's
# tmp/suite.log; what is printed is as on demand. It files nothing: its caller
# reports.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

NIGHTLY=0
TREE=0
case "${1:-}" in
  -h | --help)
    sed -n '2,39p' "$0" | sed 's/^# \?//'
    exit 0
    ;;
  --nightly) NIGHTLY=1 ;;
  --tree)
    if [ -z "${2:-}" ] || ! cd "$2" 2>/dev/null; then
      echo "suite: --tree needs a worktree directory" >&2
      exit 2
    fi
    TREE=1
    ;;
  '') ;;
  *)
    echo "suite: unknown argument '$1' (see --help)" >&2
    exit 2
    ;;
esac

COMMON=$(git rev-parse --path-format=absolute --git-common-dir) || {
  echo "suite: not in a git repository" >&2
  exit 2
}
LOCK="$COMMON/lazysite-suite.lock"
NOTE="$LOCK.holder"
JOBS=$(nproc 2>/dev/null || echo 4)

exec 9>>"$LOCK" || {
  echo "suite: cannot open $LOCK" >&2
  exit 2
}

write_note() {
  {
    echo "pid=$$"
    echo "cwd=$PWD"
    echo "branch=$(git branch --show-current 2>/dev/null)"
    echo "started=$(date '+%Y-%m-%d %H:%M:%S')"
  } >"$NOTE"
}

show_holder() {
  if [ -s "$NOTE" ]; then
    sed 's/^/suite:     /' "$NOTE"
  else
    echo "suite:     (the holder has not written its note yet)"
  fi
}

# --- the nightly run -----------------------------------------------------------
nightly() {
  local state day dir log wt sha rc limit inbox report
  state=$(dirname "$COMMON")
  day=$(date +%F)
  dir="$state/tmp/nightly"
  log="$dir/$day.log"
  wt="$state/tmp/wt-nightly"
  limit=${LAZYSITE_NIGHTLY_LIMIT:-5h}
  inbox=${LAZYSITE_NIGHTLY_INBOX:-$state/inbox}
  mkdir -p "$dir"

  if ! flock -n 9; then
    {
      echo "$(date '+%F %T') nightly: skipped - another whole-suite run holds $LOCK:"
      show_holder
    } >>"$log"
    return 0
  fi

  # The worktree is this script's own: whatever a test left in it is discarded.
  if [ -d "$wt" ]; then
    git -C "$wt" checkout -q -f --detach main >>"$log" 2>&1 || {
      echo "$(date '+%F %T') nightly: could not move $wt to main" >>"$log"
      return 2
    }
  else
    git -C "$state" worktree add -q --detach "$wt" main >>"$log" 2>&1 || {
      echo "$(date '+%F %T') nightly: could not create $wt" >>"$log"
      return 2
    }
  fi
  sha=$(git -C "$wt" rev-parse --short=12 HEAD)
  cd "$wt" || return 2
  write_note

  local -a quiet=()
  command -v nice >/dev/null 2>&1 && quiet+=(nice -n 19)
  command -v ionice >/dev/null 2>&1 && quiet+=(ionice -c3)
  echo "$(date '+%F %T') nightly: main at $sha, prove -lr -j$JOBS t/ in $wt (limit $limit)" >>"$log"
  timeout --kill-after=60 "$limit" "${quiet[@]}" prove -lr -j"$JOBS" t/ >>"$log" 2>&1 9>&-
  rc=$?
  : >"$NOTE"
  if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
    echo "$(date '+%F %T') nightly: STOPPED at the $limit limit (exit $rc)" >>"$log"
  fi
  echo "$(date '+%F %T') nightly: prove exit $rc" >>"$log"

  # The newest 14 logs are kept (DATE names sort by age).
  find "$dir" -maxdepth 1 -name '????-??-??.log' | sort -r | tail -n +15 | xargs -r rm -f --

  [ "$rc" = 0 ] && return 0
  mkdir -p "$inbox"
  report="$inbox/$day-nightly-suite-failed-on-$sha.md"
  perl -e '
      my ( $log, $sha, $rc, $day ) = @ARGV;
      open my $f, "<", $log or die "$log: $!\n";
      my ( @order, %first, %failed, $pending );
      while ( my $l = <$f> ) {
          chomp $l;
          if ( $l =~ /^#\s+Failed test/ ) { $pending = $l; next }
          if ( $l =~ /^#\s+at (\S+\.t) line \d+/ && defined $pending ) {
              $first{$1} //= "$pending\n$l";
              undef $pending;
              next;
          }
          if ( $l =~ /^(t\/\S+\.t)\s+\(Wstat: (\d+)/ ) {
              push @order, $1 unless $failed{$1}++;
          }
      }
      print "# Nightly suite failed on main at $sha ($day)\n\n";
      print "tools/suite.sh --nightly: prove exited $rc. Log: $log\n\n";
      print "No failing file was named; read the log tail.\n" unless @order;
      for my $t (@order) {
          print "- $t\n";
          print map {"    $_\n"} split /\n/, $first{$t} if $first{$t};
      }
  ' "$log" "$sha" "$rc" "$day" >"$report"
  echo "$(date '+%F %T') nightly: FAILED - filed $report" >>"$log"
  return 1
}

if [ "$NIGHTLY" = 1 ]; then
  nightly
  exit $?
fi

# --- on demand, or in a prepared tree ------------------------------------------
LOG=tmp/suite.log
mkdir -p tmp
RUN=()
if [ "$TREE" = 1 ]; then
  if ! flock -n 9; then
    echo "suite: skipped - another whole-suite run holds $LOCK:"
    show_holder
    exit 75
  fi
  RUN=(timeout --kill-after=60 "${LAZYSITE_NIGHTLY_LIMIT:-5h}")
  command -v nice >/dev/null 2>&1 && RUN+=(nice -n 19)
  command -v ionice >/dev/null 2>&1 && RUN+=(ionice -c3)
elif ! flock -n 9; then
  echo "suite: another whole-suite run holds $LOCK - waiting for it."
  show_holder
  flock 9 || {
    echo "suite: could not take $LOCK" >&2
    exit 2
  }
fi
write_note

echo "==> suite: prove -lr -j$JOBS t/ in $PWD (log: $LOG)"
# 9>&- : the lock is this script's. A process a test leaves behind must not
# hold it for ever and stop every later suite on the host.
"${RUN[@]}" prove -lr -j"$JOBS" t/ >"$LOG" 2>&1 9>&-
RC=$?
: >"$NOTE"

if [ "$RC" = 0 ]; then
  grep -E '^Files=' "$LOG"
elif [ "$TREE" = 1 ] && { [ "$RC" = 124 ] || [ "$RC" = 137 ]; }; then
  echo "suite: STOPPED at the ${LAZYSITE_NIGHTLY_LIMIT:-5h} limit (exit $RC) - $LOG"
else
  echo "suite: FAILED (prove exit $RC) - $LOG"
  grep -E '^#   Failed test|\(Wstat' "$LOG" | head -10
fi
exit "$RC"
