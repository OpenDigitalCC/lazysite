#!/bin/bash
#
# scripts/pre-review.sh - what to run before offering a branch to vcs-review.
#
# SM737: the moment this fills. A branch is developed, then handed to review,
# and until now nothing sat between those two - so the first thing to notice a
# formatting slip, an undocumented class or a changelog ref naming a commit that
# does not exist was the release gate, hours later, or a human reading a diff.
#
# WHY THE LINTS SPECIFICALLY. Measured across this project's history: of 739 test
# files ever added, 94% arrived in the same commit as the code they test - they
# are regression insurance. The 43 written against code that ALREADY existed are
# where nearly every self-reported find came from, and 53% of those are lints.
# They are also the cheapest thing here: 40 seconds at -j4 against eleven minutes
# for the suite and over two hours for coverage.
#
# Every gate failure the author of this script personally triggered in one long
# session was a lint - tidy, perlcritic, the changelog pair, the class contracts,
# the manifest build. Not one was a unit test. That is the argument for running
# them at the moment work leaves your hands.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 2

TIER="${1:-review}"
JOBS="${LAZYSITE_PROVE_JOBS:-4}"
rc=0

say() { printf '\n== %s\n' "$1"; }

case "$TIER" in
  fast)
    # THE INNER LOOP. 102 of the 110 lint files run in under half a second
    # each - 14.6s serial, a few at -j4 - because they read the tree rather
    # than compiling it or walking git history. Cheap enough to run often.
    say "fast: the sub-second lints"
    mapfile -t FAST < <(
      for f in t/lint/*.t; do
        case "$f" in
          *02-perlcritic*|*05-perlcritic-security*|*53-changelog-commit-refs*|\
          *65-changelog-entries*|*75-unreleased-entries*|*04-compile*) ;;
          *) printf '%s\n' "$f" ;;
        esac
      done
    )
    prove -l -j"$JOBS" "${FAST[@]}" || rc=1
    ;;

  review)
    # BEFORE THE BRANCH LEAVES YOUR HANDS. Everything the release gate would
    # fail on that does not need the release itself: the full lint tier, and
    # the manifest build, which refuses an unclassified file and has caught a
    # stray backup file, a new docs directory and a new tool in one session.
    say "review: the full lint tier ($(ls t/lint/*.t | wc -l) files)"
    prove -l -j"$JOBS" -r t/lint/ || rc=1

    say "review: the manifest build (refuses an unclassified file)"
    perl tools/build-manifest.pl >/dev/null 2>&1 \
      || { perl tools/build-manifest.pl 2>&1 | tail -5; rc=1; }
    ;;

  suite)
    say "suite: everything ($(find t -name '*.t' | wc -l) files)"
    prove -l -j"$JOBS" -r t/ || rc=1
    ;;

  *)
    cat >&2 <<USAGE
usage: scripts/pre-review.sh [fast|review|suite]

  fast    the sub-second lints. The inner loop, while you work.
  review  the full lint tier + the manifest build. BEFORE offering a branch.
  suite   everything. The release gate runs this; run it when you have
          changed behaviour rather than only its description.

Not here: bench and coverage. Those belong to a cut - see
docs/architecture/test-tiers.md for why, and for what each tier is FOR.
USAGE
    exit 2
    ;;
esac

if [ "$rc" = 0 ]; then
  printf '\n== %s tier: PASS\n' "$TIER"
else
  printf '\n== %s tier: FAILED - do not offer this branch yet\n' "$TIER" >&2
fi
exit "$rc"
