#!/bin/bash
# tools/suite-local.sh - run the whole suite in a staged tree, on this host.
#
#   tools/suite-local.sh STAGE_DIR JOBS OUTFILE
#
# The suite-runner contract (SM1454 R3): run `prove -lr -jJOBS t/` in STAGE_DIR,
# write prove's output to OUTFILE (and to stdout), and exit with prove's status.
# It is what the release gate has always run in the stage - `cd` first, because
# -l adds ./lib relative to the cwd (see tools/release.sh), detached so nothing
# in the suite can reach a terminal - kept in one place so the lab runner
# (tools/suite-lab.sh) falls back to exactly this and not to a copy of it.
set -euo pipefail

if [ $# -ne 3 ]; then
    echo "usage: tools/suite-local.sh STAGE_DIR JOBS OUTFILE" >&2
    exit 2
fi
STAGE=$1
JOBS=$2
OUT=$3
[ -d "$STAGE/t" ] || {
    echo "suite-local: $STAGE has no t/ directory" >&2
    exit 2
}
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || {
    echo "suite-local: JOBS must be a positive integer, not '$JOBS'" >&2
    exit 2
}

case "$OUT" in /*) ;; *) OUT=$PWD/$OUT ;; esac

# tee succeeds whatever prove did; pipefail makes the pipeline carry prove's status.
cd "$STAGE"
set -o pipefail
setsid -w prove -lr "-j$JOBS" t/ </dev/null 2>&1 | tee "$OUT"
