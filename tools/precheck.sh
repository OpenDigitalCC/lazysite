#!/bin/bash
# tools/precheck.sh - the one-minute check before the full suite (SM949).
#
# Most handoff re-runs were knowable in seconds - a tidy alignment, a lint, a
# file that does not compile - and were found after a six-minute suite. This runs
# what catches them, on what the branch changed, and stops the handoff early:
#   1. compile every changed .pl/.pm/.t
#   2. every lint, with the two perlcritic lints narrowed to changed files
#   3. the tests that name a changed file
# Usage: tools/precheck.sh [BASE]   (default main). Exit non-zero on any failure.
set -u
cd "$(dirname "$0")/.." || exit 2
BASE=${1:-main}
RC=0
CHANGED=$(git diff --name-only "$BASE"...HEAD; git diff --name-only HEAD)
CHANGED=$(printf '%s\n' $CHANGED | sort -u)
PERL=$(printf '%s\n' $CHANGED | grep -E '\.(pl|pm|t)$' || true)

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
  RELATED="$RELATED $(grep -rlF -e "$pat" t/unit t/integration t/tools 2>/dev/null)"
done
RELATED=$( (printf '%s\n' $RELATED; printf '%s\n' $PERL | grep '^t/.*\.t$' | grep -v '^t/lint/') | sort -u | grep . || true)

# Left to the full suite: tests measured over 20 s (2026-10-07, prove --timer
# at -j4). The handoff still runs every one; the pre-check is for what can be
# known in about a minute. t/unit/tools/76 is ~80 s whenever
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
