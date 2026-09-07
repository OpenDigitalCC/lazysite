#!/bin/bash
# tools/handoff.sh - the gate a branch passes BEFORE it is handed for review.
#
# SM764. The 0.13.4 cut was launched three times. The first coverage stage
# failed on a render ceiling met under instrumentation; the fix for that
# broke a textual pin one test file over, which the second build's plain
# suite found twelve minutes in. Each failure cost a review round-trip
# through the release manager, who was not watching - many hours for two
# faults that `make tier-review` (the whole plain suite, ~2 minutes at -j4)
# would have found on the branch before anyone was asked to look.
#
# The tier ladder in DEVELOPER.md already said "tier-review at branch
# handoff". It was not run. This script is the handoff: it runs the tier,
# the checks a review would otherwise trip over, and prints ONE line the
# handover message carries. A branch is not offered for review without
# this line.
#
#   bash tools/handoff.sh            # gates the checked-out branch against main
#   bash tools/handoff.sh --release  # also bench, for a branch bound for a cut
#
# Exit 0 = READY. Anything else = not ready, and it says what.
set -u
cd "$(dirname "$0")/.." || exit 2

BRANCH=$(git branch --show-current)
SHA=$(git rev-parse --short HEAD)
BASE=${HANDOFF_BASE:-main}
RC=0

say() { printf '%s\n' "$*"; }
fail() { say "handoff: FAIL - $*"; RC=1; }

say "==> handoff: $BRANCH ($SHA) against $BASE"

# 1. A clean tree: what is reviewed is what is committed.
if [ -n "$(git status --porcelain)" ]; then
  fail "uncommitted changes in the tree"
fi

# 2. The mangled-literal check on everything this branch changed. A tool in
#    use here rewrites a quote followed by a slash into a URL; it has landed
#    in a fixture before (t/unit/daemon/05, 0.13.1).
if git diff "$BASE"...HEAD | grep -q "gh\.072103"; then
  fail "the diff carries the mangled literal 'gh.072103' - repair it"
fi

# 3. Every changed Perl file compiles.
for f in $(git diff --name-only "$BASE"...HEAD | grep -E '\.(pm|pl|t)$'); do
  [ -f "$f" ] || continue
  if ! perl -Ilib -It/lib -c "$f" >/dev/null 2>&1; then
    fail "does not compile: $f"
  fi
done

# 4. The tier: the whole plain suite at -j4. Not the touched files, not the
#    area - the suite. A textual pin one file over is what the area misses.
say "==> tier-review (whole plain suite, -j4)"
if ! prove -lr -j4 t/ > tmp/handoff-suite.log 2>&1; then
  fail "tier-review: the suite did not pass - tmp/handoff-suite.log"
  grep -E "^#   Failed test|\(Wstat" tmp/handoff-suite.log | head -10
else
  grep -E "^Files=" tmp/handoff-suite.log
fi

# 5. For a branch bound for a cut: the bench gate too.
if [ "${1:-}" = "--release" ]; then
  say "==> bench --check"
  if ! perl tools/bench.pl --check > tmp/handoff-bench.log 2>&1; then
    fail "bench: a counter or timing failed - tmp/handoff-bench.log"
  fi
fi

if [ "$RC" -eq 0 ]; then
  say "READY FOR REVIEW: $BRANCH $SHA (tier-review passed$( [ "${1:-}" = "--release" ] && printf ', bench passed' ))"
else
  say "NOT READY: $BRANCH $SHA"
fi
exit "$RC"
