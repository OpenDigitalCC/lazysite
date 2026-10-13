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
# Usage: tools/precheck.sh [BASE]   (default main). Exit non-zero on any failure.
set -u
cd "$(dirname "$0")/.." || exit 2
# The log goes to tmp/, which is ignored: a fresh worktree has none, and the
# redirect below failed there before prove ran (t/tools/150).
mkdir -p tmp
BASE=${1:-main}
RC=0
CHANGED=$(git diff --name-only "$BASE"...HEAD; git diff --name-only HEAD)
CHANGED=$(printf '%s\n' $CHANGED | sort -u)
# Files the branch deleted or renamed away are in the diff too; there is nothing
# of them to compile or run, and prove dies on a test that is not there.
PERL=$(printf '%s\n' $CHANGED | grep -E '\.(pl|pm|t)$' | while read -r f; do [ -f "$f" ] && echo "$f"; done || true)

for f in $PERL; do
  [ -f "$f" ] || continue
  perl -Ilib -It/lib -c "$f" >/dev/null 2>&1 || { echo "precheck: does not compile: $f"; RC=1; }
done

# Tests that name a changed file - by its file name, or a module by its package
# name. Stems ("release") matched half the suite; full names do not.
RELATED=""
for f in $CHANGED; do
  [ -f "$f" ] || continue
  case "$f" in t/*) continue ;; esac
  pat=$(basename "$f")
  case "$f" in lib/*.pm) pat="$pat
$(echo "${f#lib/}" | sed 's#/#::#g; s#\.pm$##')" ;; esac
  RELATED="$RELATED $(grep -rlF --include='*.t' -e "$pat" t/unit t/integration t/tools 2>/dev/null)"
done
RELATED=$( (printf '%s\n' $RELATED; printf '%s\n' $PERL | grep '^t/.*\.t$' | grep -v '^t/lint/') | sort -u | grep . || true)

# SM1061: and the tests that cover each AREA the change touches, from the one
# declared map (tools/precheck-areas.pl; t/lint/255 keeps it complete). A test
# can break without naming a changed file - t/unit/processor/101 did, on a
# change to lazysite-processor/sources.pm - and the suite no longer runs in the
# handoff to catch it.
# shellcheck disable=SC2086
AREA=$(perl tools/precheck-areas.pl $CHANGED) || { echo "precheck: tools/precheck-areas.pl failed"; RC=1; }
RELATED=$(printf '%s\n' $RELATED $AREA | sort -u | grep . || true)

# Left to the full suite: tests measured over 20 s (2026-10-07, prove --timer
# at -j4). The whole suite still runs every one (nightly, and for a release);
# the pre-check is for what can be known in minutes. t/unit/tools/76 is ~80 s whenever
# tools/coverage-inputs.pl has changed (its PPI cache is keyed on that file).
SLOW='t/tools/60-coverage-cannot-report-what-it-did-not-measure.t
t/smoke/01-all-starter-pages.t
t/tools/01-build-manifest.t
t/tools/03-install-pl.t
t/unit/plugins/41-a-composed-document-is-refused-not-quietly-shortened.t
t/tools/36-check-verifies-install-dirs.t
t/tools/35-install-dirs-declared.t
t/tools/31-webserver-glue.t
t/unit/tools/76-the-coverage-skip-actually-fires.t'
RELATED=$(printf '%s\n' $RELATED | grep -vxF "$SLOW" || true)

# The three changelog lints read the whole 1 MB CHANGELOG (lint 53 alone ~57 s);
# they matter only when it changed.
LINTS=$(ls t/lint/*.t)
if ! printf '%s\n' $CHANGED | grep -qx CHANGELOG.md; then
  LINTS=$(printf '%s\n' $LINTS | grep -vE '^t/lint/(53|65|75)-')
fi

export LAZYSITE_LINT_FILES
LAZYSITE_LINT_FILES=$(printf '%s\n' $PERL | grep -v '^t/' | tr '\n' ' ')
# shellcheck disable=SC2086
if ! prove -l -j8 $LINTS $RELATED > tmp/precheck.log 2>&1; then
  echo "precheck: FAIL - tmp/precheck.log"
  grep -E "^#   Failed test|\(Wstat|^# TIDY" tmp/precheck.log | head -15
  RC=1
else
  grep -E "^Files=" tmp/precheck.log
fi
exit "$RC"
