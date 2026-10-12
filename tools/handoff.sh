#!/bin/bash
# tools/handoff.sh - the gate a branch passes BEFORE it is handed for review.
#
#   bash tools/handoff.sh                 # the checked-out branch against main
#   bash tools/handoff.sh --stack BASE    # every branch from BASE to this one
#   bash tools/handoff.sh --full          # also the whole plain suite (tools/suite.sh)
#   bash tools/handoff.sh --release       # --full plus bench, for a branch bound for a cut
#
# SM1061: THE HANDOFF IS THE PRECHECK. By default it runs only what is per
# branch: a clean tree, the generators, the mangled-literal check, the
# precheck (SM949) on each stack branch, and the tracked-tree check. The whole
# plain suite runs ONCE, on main, after each landing (tools/gate-main.sh), and
# one whole-suite run goes at a time on the host (tools/suite.sh's lock).
# Ruled by the release manager on 2026-10-12: four agents running the suite in
# their handoffs at once took an 8-core host to a load of 26-30 and every suite
# from ~1,080 s to ~1,950 s, and the handoff suite caught nothing that day -
# precheck caught every handoff fault, and the one cross-stack clash was found
# by the run on main. `--full` keeps the suite here, through tools/suite.sh so it
# takes the lock; `--release` implies it.
#
# History: SM764 made the whole suite the handoff, after two faults reached a
# cut that the suite on the branch would have found. SM971 ran it once per
# stack, on the tip, instead of once per branch. SM1061 moves it to main.
#
# SM1062: THE READY A STACK IS OFFERED WITH NOW COMES FROM THE OVERNIGHT RUN.
# Queue the stack (`tools/overnight.sh --queue WORKTREE TIP`); at 00:30
# tools/integration.pl prechecks it as this script does, cherry-picks it with
# the other queued stacks onto main in queue order, runs one whole suite on
# that tree, and prints "LAND IN THIS ORDER:" and the READY FOR REVIEW lines in
# tmp/overnight/results-DATE.txt. This script keeps its daytime role: a quick
# precheck-only check for an agent that wants one before queueing.
#
# --stack BASE prechecks every branch between BASE and the checked-out tip, in
# order, each against the branch below it (SM971); every branch is READY only if
# all of that passed, and the first that fails stops the run, by name. Without
# --stack the stack is the one checked-out branch against main ($HANDOFF_BASE
# overrides), so there is one way through this script, not two.
#
# Nothing per-branch is written for review to read: vcs-review offers a branch
# that is neither author-held (refs/vcs-review/hold/*) nor checked out, so what
# a passing handoff must do is release the worktree - it returns to BASE.
#
# A stack landed in part: vcs-review rebases what it lands, so rebase what is
# left onto the new main and run `--stack main` again on it.
#
# Exit 0 = READY. Anything else = not ready, and it says what.
set -u
cd "$(dirname "$0")/.." || exit 2

BASE=${HANDOFF_BASE:-main}
STACKED=0
RELEASE=0
FULL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --release) RELEASE=1; FULL=1; shift ;;
    --full) FULL=1; shift ;;
    --stack)
      [ $# -ge 2 ] || { echo "handoff: --stack needs a BASE branch" >&2; exit 2; }
      BASE=$2; STACKED=1; shift 2 ;;
    *) echo "handoff: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

BRANCH=$(git branch --show-current)
SHA=$(git rev-parse --short HEAD)
RC=0

say() { printf '%s\n' "$*"; }
fail() { say "handoff: FAIL - $*"; RC=1; }

say "==> handoff: $BRANCH ($SHA) against $BASE"

git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || { say "handoff: no branch $BASE"; exit 2; }

# 1. A clean tree: what is reviewed is what is committed.
if [ -n "$(git status --porcelain)" ]; then
  fail "uncommitted changes in the tree"
fi

# 2. The mangled-literal check on everything this branch changed. A tool in
#    use here rewrites a quote followed by a slash into a URL; it has landed
#    in a fixture before (t/unit/daemon/05, 0.13.1).
# SM948: generated documents are regenerated, not failed on. Run after the
# clean-tree check, so the only change in the tree is the generators' own, and
# committed on its own so the work commits stay as they were written. On a
# stack, on the tip only: a branch below it that is stale fails its precheck.
# (`= 0`, not `-eq 0`: t/tools/63 finds the success path by that spelling.)
if [ "$RC" = 0 ]; then
  REGEN=$(bash tools/regen-generated.sh) || fail "a generator failed (tools/regen-generated.sh)"
  if [ -n "$REGEN" ]; then
    say "==> regenerated: $(echo $REGEN)"
    # shellcheck disable=SC2086
    git add $REGEN && git commit -q -m "Regenerate generated documents (tools/regen-generated.sh)" \
      || fail "could not commit the regenerated documents"
    SHA=$(git rev-parse --short HEAD)
  fi
fi

# 3. The stack: the local branches between BASE and this one, lowest first, each
#    with the branch below it as its parent. Without --stack, just this branch.
STACK=()
PARENTS=()
if [ "$STACKED" = 1 ] && [ "$RC" = 0 ]; then
  # Ordered by distance from BASE; of two at one commit, the checked-out one last.
  while read -r _n _tip b; do
    STACK+=("$b")
  done < <(git for-each-ref --format='%(refname:short)' refs/heads | while read -r b; do
      [ "$b" = "$BASE" ] && continue
      git merge-base --is-ancestor "$b" HEAD || continue
      git merge-base --is-ancestor "$b" "$BASE" && continue
      printf '%s %s %s\n' "$(git rev-list --count "$BASE..$b")" "$([ "$b" = "$BRANCH" ] && echo 1 || echo 0)" "$b"
    done | sort -k1,1n -k2,2n -k3,3)
  prev=$BASE
  for b in "${STACK[@]}"; do
    if ! git merge-base --is-ancestor "$prev" "$b"; then
      say "handoff: $b does not sit on $prev - not a stack; hand them off one at a time"
      exit 2
    fi
    PARENTS+=("$prev")
    prev=$b
  done
  if [ "${#STACK[@]}" -eq 0 ] || [ "${STACK[${#STACK[@]}-1]}" != "$BRANCH" ]; then
    say "handoff: the checked-out branch ($BRANCH) is not the top of a stack on $BASE"
    exit 2
  fi
  say "==> stack on $BASE: ${STACK[*]}"
else
  STACK=("$BRANCH")
  PARENTS=("$BASE")
fi

# 4. Each branch, lowest first: the mangled literal in what IT added, then the
#    one-minute precheck (SM949) against the branch below it. What it catches -
#    a lint, tidy, a file that does not compile, a test naming a changed file -
#    is known in seconds, and it is what found every handoff fault on the day
#    SM1061 was ruled. A failure stops the run here.
if [ "$RC" = 0 ]; then
  for i in "${!STACK[@]}"; do
    b=${STACK[$i]}
    parent=${PARENTS[$i]}
    if [ "$b" != "$(git branch --show-current)" ]; then
      git checkout -q "$b" || { say "NOT READY: could not check out $b"; exit 1; }
    fi
    # Added lines only: a context line of this very file carries the literal in
    # the message below, and matched itself once handoff.sh was edited near it.
    if git diff "$parent"...HEAD | grep '^+' | grep -v '^+++' | grep -q "gh\.072103"; then
      fail "$b: the diff carries the mangled literal (gh, a dot, 072103) - repair it"
    fi
    say "==> precheck $b against $parent (lints + related tests, ~10 s)"
    if [ "$RC" != 0 ] || ! bash tools/precheck.sh "$parent"; then
      fail "precheck failed on $b - fix it and run the handoff again (tmp/precheck.log)"
      [ "$b" = "$BRANCH" ] || git checkout -q "$BRANCH"
      say "NOT READY: $b $(git rev-parse --short "$b") - the stack stops there"
      exit 1
    fi
  done
  [ "$(git branch --show-current)" = "$BRANCH" ] || git checkout -q "$BRANCH"
fi

# 5. With --full (or --release) only: the whole plain suite, ONCE, on the tip,
#    through tools/suite.sh - so it waits its turn behind any other whole-suite
#    run on the host (SM1061). By default the suite is main's, once per landing.
if [ "$FULL" = 1 ] && [ "$RC" = 0 ]; then
  say "==> the whole plain suite on $BRANCH (tools/suite.sh, one run at a time on the host)"
  if ! bash tools/suite.sh; then
    fail "the suite did not pass - tmp/suite.log"
  fi
fi

# 5b. SM894: the tests put back every tracked file they edited. Three tests
#     edit VERSION, the sign-off switch, the reliability record and the
#     practice briefing for real, and a run that is killed mid-test leaves
#     them edited - which then fails a version lint on the NEXT run, on a
#     tree nobody touched. Asked here, after the precheck's related tests (and
#     the suite, with --full), where the answer can name the test.
if ! perl tools/tracked-tree-check.pl .; then
  fail "a test left a tracked file edited (named above)"
fi

# 6. For a branch bound for a cut: the bench gate too.
if [ "$RELEASE" = 1 ]; then
  say "==> bench --check"
  if ! perl tools/bench.pl --check > tmp/handoff-bench.log 2>&1; then
    fail "bench: a counter or timing failed - tmp/handoff-bench.log"
  fi
fi

# What the READY line says passed: the precheck always; the suite (and bench)
# only when they ran - on the tip, which a stack names.
WHAT="precheck passed"
if [ "$FULL" = 1 ]; then
  WHAT="$WHAT; suite passed"
  [ "$RELEASE" = 1 ] && WHAT="$WHAT, bench passed"
  [ "${#STACK[@]}" -gt 1 ] && WHAT="$WHAT on $BRANCH"
fi

if [ "$RC" -eq 0 ]; then
  # SM829: RELEASING THE BRANCH IS PART OF SAYING READY, not a step afterwards.
  #
  # This printed READY and left the branch checked out, and a human was then
  # meant to remember two more things: return the worktree to main, and offer the
  # branch. The gap between them is real enough that the review side defends
  # against it - "checked out at /srv/projects/lazysite (in use): not offered" -
  # and it was walked into by the author of the sentence describing the sequence,
  # in the session that wrote it.
  #
  # So a branch that cannot be released is NOT ready: it cannot be offered, and
  # saying READY about it would be the same class of false report the gate exists
  # to prevent. Nothing is left to remember.
  if [ "$BRANCH" != "$BASE" ] && [ -n "$BRANCH" ]; then
    # Q16a: IN A LINKED WORKTREE THE BASE IS USUALLY CHECKED OUT ELSEWHERE - in
    # the main checkout - and git refuses to check one branch out twice, so the
    # return failed and every gate-passing run said NOT READY (n308, n332). What
    # releasing needs is only that this worktree holds no branch: detaching at
    # the base frees the branch just as well. The main checkout returns to the
    # base branch as before.
    if [ "$(git rev-parse --path-format=absolute --git-dir)" != \
         "$(git rev-parse --path-format=absolute --git-common-dir)" ]; then
      git checkout --detach "$BASE" >/dev/null 2>&1
      released=$?
      where="detached at $BASE"
    else
      git checkout "$BASE" >/dev/null 2>&1
      released=$?
      where="back on $BASE"
    fi
    if [ "$released" = 0 ]; then
      FREE=()
      for b in "${STACK[@]}"; do
        # Q16a: a stack branch can be landed (and deleted) by review while the
        # suite runs; it has no SHA to report, and is no longer this run's to
        # call ready.
        if bsha=$(git rev-parse --verify --quiet --short "refs/heads/$b"); then
          say "READY FOR REVIEW: $b $bsha ($WHAT)"
          FREE+=("$b")
        else
          say "$b (landed or deleted during the run)"
        fi
      done
      say "    the worktree is $where, so ${FREE[*]} is free to review"
    else
      say "NOT READY: $BRANCH $SHA - gates passed, but the worktree could not"
      say "    return to $BASE, so the branch is still held and cannot be offered"
      RC=1
    fi
  else
    say "READY FOR REVIEW: $BRANCH $SHA ($WHAT)"
  fi
else
  say "NOT READY: $BRANCH $SHA"
fi
exit "$RC"
