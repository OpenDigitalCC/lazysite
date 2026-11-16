#!/bin/bash
# tools/precheck.sh - the targeted check on each commit and handoff (SM949, SM1061).
#
# Most handoff re-runs were knowable in seconds - a tidy alignment, a lint, a
# file that does not compile - and were found after a six-minute suite. This runs
# what catches them, on what the branch changed, and stops the handoff early:
#   1. compile every changed .pl/.pm/.t
#   2. every lint, with the two perlcritic lints narrowed to changed files
#   3. the tests that name a changed file
#   4. the tests that cover each area the change touches (SM1061,
#      tools/precheck-areas.pl) - since SM1061 this is the handoff's test run;
#      the whole suite is on demand (tools/suite.sh), for a release, and nightly
# Usage: tools/precheck.sh [--jobs N] [BASE]   (default main). Exit non-zero on any failure.
# The test run is `prove -j8` unless told otherwise (SM1199): --jobs N, or
# LAZYSITE_PROVE_JOBS=N, sets it; the flag wins. On the shared host an agent
# runs it at 2; the release manager's runs and the integration keep 8.
set -u
cd "$(dirname "$0")/.." || exit 2
# The log goes to tmp/, which is ignored: a fresh worktree has none, and the
# redirect below failed there before prove ran (t/tools/150).
mkdir -p tmp
JOBS=${LAZYSITE_PROVE_JOBS:-8}
if [ "${1:-}" = "--jobs" ]; then
  JOBS=${2:-}
  shift
  [ $# -gt 0 ] && shift
fi
case "$JOBS" in
  '' | *[!0-9]* | 0)
    echo "precheck: --jobs / LAZYSITE_PROVE_JOBS wants a positive whole number, not '$JOBS'" >&2
    exit 2
    ;;
esac
BASE=${1:-main}
RC=0
CHANGED=$(git diff --name-only "$BASE"...HEAD; git diff --name-only HEAD)
CHANGED=$(printf '%s\n' $CHANGED | sort -u)
# Files the branch deleted or renamed away are in the diff too; there is nothing
# of them to compile or run, and prove dies on a test that is not there.
# SM1081: t/vendor/ is OOM's own code, held to its MANIFEST by t/lint/261; its test doubles need OOM's library
# on the path and do not compile standalone, so they are not compiled here.
PERL=$(printf '%s\n' $CHANGED | grep -E '\.(pl|pm|t)$' | grep -v '^t/vendor/' | while read -r f; do [ -f "$f" ] && echo "$f"; done || true)

# SM1369 X7: an in-tree extension's payload lib (extensions/<id>/lib) holds its own
# modules, which `use` one another; compiled with those libs on @INC, as a test has
# them (TestHelper) and as core reaches them (Lazysite::Extensions::require_payload).
INC="-Ilib -It/lib"
for d in extensions/*/lib; do
  [ -d "$d" ] && INC="$INC -I$d"
done

for f in $PERL; do
  [ -f "$f" ] || continue
  # shellcheck disable=SC2086  # INC is a list of -I words
  perl $INC -c "$f" >/dev/null 2>&1 || { echo "precheck: does not compile: $f"; RC=1; }
done

# The tests the change selects: those that name a changed file, the changed tests
# themselves, and those that cover each AREA it touches (SM1061). One selection,
# tools/precheck-select.sh, shared with a patch gate (SM1454). It leaves out the
# tests measured over 20 s (2026-10-07, prove --timer at -j4): the whole suite
# still runs every one, nightly and for a release; the pre-check is for what can
# be known in minutes.
# shellcheck disable=SC2086
RELATED=$(bash tools/precheck-select.sh $CHANGED) || { echo "precheck: tools/precheck-select.sh failed"; RC=1; }

# The three changelog lints read the whole 1 MB CHANGELOG (lint 53 alone ~57 s);
# they matter only when it changed.
LINTS=$(ls t/lint/*.t)
if ! printf '%s\n' $CHANGED | grep -qx CHANGELOG.md; then
  LINTS=$(printf '%s\n' $LINTS | grep -vE '^t/lint/(53|65|75)-')
fi

export LAZYSITE_LINT_FILES
LAZYSITE_LINT_FILES=$(printf '%s\n' $PERL | grep -v '^t/' | tr '\n' ' ')
# shellcheck disable=SC2086
if ! prove -l -j"$JOBS" $LINTS $RELATED > tmp/precheck.log 2>&1; then
  echo "precheck: FAIL - tmp/precheck.log"
  grep -E "^#   Failed test|\(Wstat|^# TIDY" tmp/precheck.log | head -15
  RC=1
else
  grep -E "^Files=" tmp/precheck.log
fi
exit "$RC"
