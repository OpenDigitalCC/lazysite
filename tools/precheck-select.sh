#!/bin/bash
# tools/precheck-select.sh - the tests a change selects (SM949, SM1061, SM1454).
#
#   tools/precheck-select.sh [--keep-slow] FILE...   # one test path a line, sorted
#
# The one place the precheck's test selection lives, so tools/precheck.sh (the
# handoff) and a patch gate (tools/patch-plan.sh, SM1454) choose the same tests
# for the same change and cannot drift apart. It reads the tree it sits in, so
# `bash STAGE/tools/precheck-select.sh` selects from STAGE's tests.
#
#   - every changed test file that is not a lint (the lints always run whole);
#   - the tests that name a changed file, by its file name, or a module by its
#     package name (stems matched half the suite; full names do not);
#   - the tests that cover each AREA a change touches (tools/precheck-areas.pl).
#
# Tests measured over 20 s (2026-10-07, prove --timer at -j4) are left out - the
# handoff is for what can be known in minutes; the whole suite runs them nightly
# and for a release. --keep-slow keeps the ones the change selects: a patch gate
# has no nightly behind it. t/unit/tools/76 is ~80 s whenever
# tools/coverage-inputs.pl has changed (its PPI cache is keyed on that file).
#
# FILE names are as `git diff --name-only` prints them: relative to the root, no
# spaces. A file that no longer exists (deleted, renamed away) selects nothing
# by name, and prove dies on a test that is not there, so it is skipped.
# shellcheck disable=SC2086  # CHANGED, RELATED and AREA are lists of file names, split on purpose
set -u
cd "$(dirname "$0")/.." || exit 2
KEEP_SLOW=0
if [ "${1:-}" = "--keep-slow" ]; then
  KEEP_SLOW=1
  shift
fi
CHANGED=$(printf '%s\n' "$@" | sort -u | grep . || true)

# A changed .t that is there to run. t/vendor/ is OOM's own code (SM1081).
OWN=$(printf '%s\n' $CHANGED | grep -E '^t/.*\.t$' | grep -v -e '^t/vendor/' -e '^t/lint/' | while read -r f; do [ -f "$f" ] && echo "$f"; done || true)

RELATED=""
for f in $CHANGED; do
  [ -f "$f" ] || continue
  case "$f" in t/*) continue ;; esac
  pat=$(basename "$f")
  case "$f" in lib/*.pm) pat="$pat
$(echo "${f#lib/}" | sed 's#/#::#g; s#\.pm$##')" ;; esac
  RELATED="$RELATED $(grep -rlF --include='*.t' -e "$pat" t/unit t/integration t/tools 2>/dev/null)"
done
RELATED=$( (printf '%s\n' $RELATED; printf '%s\n' $OWN) | sort -u | grep . || true)

# SM1061: and the tests that cover each AREA the change touches, from the one
# declared map (tools/precheck-areas.pl; t/lint/255 keeps it complete). A test
# can break without naming a changed file - t/unit/processor/101 did, on a
# change to lazysite-processor/sources.pm.
# shellcheck disable=SC2086
AREA=$(perl tools/precheck-areas.pl $CHANGED) || {
  echo "precheck-select: tools/precheck-areas.pl failed" >&2
  exit 1
}
RELATED=$(printf '%s\n' $RELATED $AREA | sort -u | grep . || true)

if [ "$KEEP_SLOW" = 0 ]; then
  SLOW='t/tools/60-coverage-cannot-report-what-it-did-not-measure.t
t/smoke/01-all-starter-pages.t
t/tools/01-build-manifest.t
t/tools/03-install-pl.t
t/unit/extensions/41-a-composed-document-is-refused-not-quietly-shortened.t
t/tools/36-check-verifies-install-dirs.t
t/tools/35-install-dirs-declared.t
t/tools/31-webserver-glue.t
t/unit/tools/76-the-coverage-skip-actually-fires.t'
  RELATED=$(printf '%s\n' $RELATED | grep -vxF "$SLOW" || true)
fi
printf '%s\n' $RELATED | grep . || true
exit 0
