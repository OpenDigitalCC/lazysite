#!/bin/sh
# tools/coverage.sh - line/branch coverage for the production scripts,
# INCLUDING the CGIs that the tests exercise as subprocesses (WP-2 / D2).
#
# The tests run the CGIs as child `perl` processes (open2/open3 with $^X), so a
# plain `cover -test` only sees the parent and reports n/a. This harness exports
# PERL5OPT so EVERY perl invocation - the test scripts and the CGI children -
# loads Devel::Cover and writes to one shared cover_db, which `cover` merges.
#
# Slow (every subprocess is instrumented) - a signoff tool, not the unit suite.
#
#   tools/coverage.sh            # run the suite + print the report
#   tools/coverage.sh --check    # also enforce the declared floor (exit 1 below)
#
# The declared floor is dist/config/coverage-floor (Commercial target: 75%).
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
DB="$ROOT/cover_db"

# Where the instrumented suite's own output goes. Kept, not discarded: see the
# note at the prove line below - a coverage report is only meaningful about a
# suite that finished, and nothing could tell whether one had.
SUITE_LOG="${LAZYSITE_COVER_SUITE_LOG:-$ROOT/cover_db-suite.log}"
FLOOR_FILE="$ROOT/dist/config/coverage-floor"

# ONE RUN AT A TIME. Two concurrent runs share $DB: the second one's `rm -rf`
# deletes files the first is still writing, and both then report nonsense - all
# CGIs "NOT MEASURED", which reads as a real gate failure. That cost an hour on
# 2026-08-13, twice, and neither run said anything about the other.
LOCK="$ROOT/.coverage.lock"
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK"
    if ! flock -n 9; then
        echo "coverage: $LOCK is held - refusing to share cover_db." >&2
        echo "  Two runs corrupt each other's results and report every CGI as" >&2
        echo "  NOT MEASURED." >&2

        # NAME THE HOLDER. "Another run holds it" is a guess, and it was wrong
        # the one time it mattered: the holder was a leaked lazysite-server.pl
        # from a test fixture, four and a half hours old, with no coverage run
        # anywhere. `exec 9>` leaves the fd inheritable, so every process
        # forked during a run gets it, and one that outlives the run holds the
        # lock for ever. Being told to "wait for it, or stop it first" sends
        # you looking for a coverage run that does not exist.
        for _p in /proc/[0-9]*; do
            [ -d "$_p/fd" ] || continue
            if ls -l "$_p/fd" 2>/dev/null | grep -q "$(basename "$LOCK")"; then
                echo "  held by pid ${_p#/proc/}: $(tr '\0' ' ' < "$_p/cmdline" 2>/dev/null | cut -c1-100)" >&2
            fi
        done
        exit 2
    fi
fi

# `|| true` because `set -e` is on: without it a failed rm exits here with a
# bare "cannot remove" and no explanation at all, which is precisely how this
# presented - a wall of rm noise, no coverage output, and nothing saying why.
rm -rf "$DB" 2>/dev/null || true

# A LIVE WRITER survives the rm, and that is the failure mode worth naming: a
# `prove` orphaned from a previous run keeps executing tests and re-creating
# lock files under $DB, so `rm -rf` reports "Directory not empty" and the run
# proceeds on a poisoned database. Every CGI then reports NOT MEASURED and the
# gate fails for a reason that has nothing to do with the code.
#
# Found the hard way: killing a coverage run's shell left its `prove` child
# reparented to init, still writing, for half an hour.
if [ -e "$DB" ]; then
    echo "coverage: $DB survived removal - something is still writing to it." >&2
    echo "  Look for an orphaned test run:  ps -eo pid,ppid,cmd | awk '\$2==1'" >&2
    echo "  Kill it by PID, confirm the file count stops changing, then re-run." >&2
    exit 2
fi

# SM280: SHARDED, and the shape of the run is why it is safe.
#
# SM269 phase 0 attributed the gate with strace rather than estimation:
# coverage is 92% of its wall-clock, at a 12.4x instrumentation multiplier.
# Anything that does not reduce, defer or parallelise the coverage run does not
# move the eighty minutes.
#
# Sharding is the option that keeps the gate's MEANING intact - the other two
# (defer to a schedule, cover a rotating slice) both trade coverage of this
# commit for speed. And it needs no merging machinery: Devel::Cover already
# writes one directory per process under the shared db and `cover` merges them,
# which is the same mechanism that lets the instrumented CGI subprocesses be
# counted at all. Parallel prove workers are just more of the same writers.
#
# MEASURED, not assumed, on t/unit/mcp:
#
#   serial   467s   total 52.2% statement / 27.2% branch
#   -j4      182s   total 52.2% statement / 27.2% branch
#
# 2.6x faster and the numbers are identical to the decimal - which is the check
# that matters, because a faster run reporting DIFFERENT coverage would be a
# faster run measuring something else.
#
# The job count is capped rather than set to nproc: the run is I/O and
# inode-heavy (a directory per instrumented subprocess), and release.sh already
# refuses to stage where inodes are short. More workers past a point buys
# contention.
# SM736: SKIP WHEN THE INPUTS ARE BYTE-IDENTICAL TO A RUN THAT ALREADY PASSED.
#
# Coverage is a pure function of the measured CGIs, the library they call into,
# every test that exercises them, and the floor config. tools/coverage-inputs.pl
# digests exactly that set. If the digest matches a recorded PASSING run, the
# percentage cannot have moved and re-deriving it buys nothing - at two hours
# and twenty minutes on the 0.11.11 cut, that is 85% of a release.
#
# ABSENCE REFUSES. No record, an unreadable record, a different digest, or a
# recorded failure all mean the stage RUNS. The only path to a skip is a
# positive match against a pass.
#
# THE CORRECTNESS SUITE IS NOT SKIPPED and this argument does not extend to it:
# a gate result is a fact about a tree AT A TIME, and date-sensitive tests are a
# known class here. Coverage is structural and does not have that property.
# The record's path is overridable ONLY so that the skip can be tested.
#
# It could not be, before: the path was hard-coded, so proving the skip fires
# meant planting a matching record in the real repository - and a test killed
# between planting and restoring would leave a record that makes a REAL release
# skip its coverage gate. That is a bad thing to risk in order to test a
# shortcut whose whole purpose is to be safe.
#
# So t/unit/tools/76 points this at a temporary file and proves the decision
# without touching the repository. Nothing else sets it; release.sh does not,
# and the default is the only path any build uses.
COVER_RECORD="${LAZYSITE_COVER_RECORD:-$ROOT/dist/config/coverage-last.json}"
COVER_DIGEST=$(perl "$ROOT/tools/coverage-inputs.pl" 2>/dev/null | awk '{print $1}')
if [ "${LAZYSITE_COVER_FORCE:-}" != "1" ] && [ -n "$COVER_DIGEST" ] && [ -f "$COVER_RECORD" ]; then
    prev=$(perl -MJSON::PP -e '
        local $/; open my $f, "<", $ARGV[0] or exit 0;
        my $j = eval { JSON::PP->new->decode(<$f>) } or exit 0;
        exit 0 unless ($j->{result} // "") eq "pass";
        print $j->{inputs_digest} // "";
    ' "$COVER_RECORD" 2>/dev/null)
    if [ -n "$prev" ] && [ "$prev" = "$COVER_DIGEST" ]; then
        echo "coverage: SKIPPED - every input that decides coverage is byte-identical" >&2
        echo "coverage:   to a run that passed. digest $COVER_DIGEST" >&2
        echo "coverage:   Re-run anyway with LAZYSITE_COVER_FORCE=1." >&2
        echo "coverage: all measured production CGIs at or above the floor (from the recorded run)"
        exit 0
    fi
fi

# DECIDE-ONLY, for the test that proves the skip. Past this point the script
# starts an instrumented suite, which takes over an hour and writes cover_db/
# and a suite log into the tree.
#
# t/unit/tools/76 needs the DECISION, not the run. Without this it had to start
# a real run for each must-not-skip case and kill it on a timeout - eight
# seconds of wasted instrumentation apiece, and a cover_db-suite.log left in
# the working tree, which is exactly how a build artefact ended up in a commit.
#
# Nothing but that test sets it. It is checked here rather than earlier so the
# skip path above is genuinely exercised on the way past.
if [ "${LAZYSITE_COVER_DECIDE_ONLY:-}" = "1" ]; then
    echo "coverage: WOULD RUN - no recorded pass matches digest $COVER_DIGEST" >&2
    exit 0
fi

JOBS=${LAZYSITE_COVER_JOBS:-4}
echo "Running the suite under Devel::Cover, $JOBS-way (subprocess CGIs instrumented)..." >&2
# `+ignore,^/tmp/` KEEPS THE INSTRUMENT OUT OF EPHEMERAL COPIES.
#
# Several fixtures copy a CGI into a tempdir and run it there. Instrumenting
# those copies measures nothing useful - the floor file already excludes
# tempdir-split files from the gate - and it actively BREAKS them: Devel::Cover
# emits "Deleting old coverage for changed file /tmp/.../lazysite-processor.pl"
# when a temp path is reused with different content, the processor produces no
# CGI response, and the product code correctly reports "returned no CGI
# response" for a fault that exists only under measurement.
#
# A measuring instrument that changes the thing it measures is not measuring it.
PERL5OPT="-MDevel::Cover=-db,$DB,-silent,1,+ignore,^/usr/,+ignore,^/tmp/,+ignore,/t/,+ignore,Devel" \
    prove -l -j"$JOBS" -r t/ > "$SUITE_LOG" 2>&1 && SUITE_RC=0 || SUITE_RC=$?

# `&& ... || ...` RATHER THAN A BARE `$?`, because this file runs under
# `set -e`: a failing prove followed by `SUITE_RC=$?` on the next line would
# kill the script before it could report anything, which is a louder version of
# the same fault - the run vanishes instead of explaining itself.

# `-l` IS NOT OPTIONAL, AND ITS ABSENCE COST ELEVEN FILES (SM478).
#
# The gate runs `prove -lr`; this ran `prove -r`. Tests add
# `$FindBin::Bin/../lib` to @INC, which from t/lint resolves to t/lib - the
# TEST library, not the engine's - and rely on -l for lib/. Without it they
# died at `use Lazysite::Manager::Common` with "Can't locate ... in @INC",
# which reads as a missing module and is nothing of the kind: Perl reports any
# failed open() that way.
#
# So eleven files never ran under coverage, and their coverage was never
# counted, for as long as this line has existed. The recorded floors were
# measured without them - which means the true numbers are most likely HIGHER
# than what is written down, not lower.
#
# This is SM473's lesson from the other side: there, the harness supplied
# something production did not (`prove -l` hid a missing @INC bootstrap). Here
# the harness failed to supply what the OTHER harness does. Either way the
# harness was testing itself.

# A COVERAGE REPORT FROM A SUITE THAT DID NOT FINISH IS NOT A MEASUREMENT,
# and this line used to be `>/dev/null 2>&1 || true` - the suite's output
# thrown away and its exit code swallowed. A run that died a third of the way
# through then produced a report indistinguishable from a healthy one, just
# with lower numbers, and there was no way to tell the two apart from outside.
#
# THAT COST A REAL DECISION. A 2-job run reported 38.6% for a file whose
# recorded baseline is 82.1%, and the obvious reading - "job count changes the
# measurement" - was about to be written into the floor file as a new baseline.
# The giveaway was the clock: 465 seconds against 270 for the same suite
# UNINSTRUMENTED. Devel::Cover does not cost 1.7x; the suite had not run.
#
# So the run is now reported on, and --check refuses to give a coverage verdict
# when the thing being measured did not complete. A floor is a statement about
# a suite that passed.
suite_files=$(grep -cE '^t/.*\.t ' "$SUITE_LOG" 2>/dev/null || echo 0)
echo "suite under instrumentation: exit=$SUITE_RC, ${suite_files} file(s) reported" >&2
if [ "$SUITE_RC" -ne 0 ]; then
    echo "coverage: THE SUITE DID NOT PASS under instrumentation." >&2
    echo "coverage: the numbers below describe a run that did not finish." >&2
    grep -E '\(Wstat' "$SUITE_LOG" | head -10 >&2
    echo "coverage: full output in $SUITE_LOG" >&2
fi

# Report (drop the per-run noise).
cover -silent -report text "$DB" 2>/dev/null | grep -vE '^Run:[[:space:]]'

if [ "$1" = "--check" ]; then
    # REFUSE TO GIVE A COVERAGE VERDICT ABOUT A SUITE THAT DID NOT PASS.
    #
    # Not a coverage failure, and it must not be reported as one: SM444 is
    # already the filing about a failed coverage gate blaming coverage, and
    # this is the same mistake one layer further in. The floors describe a
    # passing suite; measuring an incomplete one and comparing it to them
    # produces a number that means nothing and a verdict that misleads.
    if [ "${SUITE_RC:-1}" -ne 0 ]; then
        echo "coverage: NOT CHECKING FLOORS - the suite did not pass under" >&2
        echo "coverage: instrumentation, so there is no measurement to check." >&2
        echo "coverage: fix the suite first; $SUITE_LOG says what failed." >&2
        exit 3
    fi
    floor=$(grep -E '^floor=' "$FLOOR_FILE" 2>/dev/null | grep -oE '[0-9]+' | head -1)
    : "${floor:=60}"
    # Branch floor (eight-dimension review D3): the framework requires line AND
    # branch thresholds, not statements alone.
    branch_floor=$(grep -E '^branch_floor=' "$FLOOR_FILE" 2>/dev/null | grep -oE '[0-9]+' | head -1)
    : "${branch_floor:=60}"
    # Check each cleanly-measured production CGI's statement AND branch %
    # against the floors. (install.pl/plugins are split across tempdir copies -
    # a known limitation, excluded from the gate; see dist/config/coverage-floor.
    # lazysite-auth.pl's tests run it from the repo path, so it is gated.)
    report=$(cover -silent -report text "$DB" 2>/dev/null)
    fail=0
    for f in lazysite-dav.pl lazysite-processor.pl lazysite-manager-api.pl \
             lazysite-auth.pl lazysite-mcp.pl lazysite-oauth.pl \
             tools/lazysite-users.pl tools/lazysite-bundle-apply.pl; do
        # Suffix match as well as exact: a test fixture may run a CGI from a
        # tempdir copy (e.g. the fake-repo fixture copies lazysite-auth.pl),
        # and cover then reports it under that ephemeral (often truncated)
        # path. Only summary rows count (numeric stmt AND bran columns - the
        # report's subroutine tables share filename-ish tokens otherwise);
        # take the best-covered entry when several match.
        set -- $(printf '%s\n' "$report" | awk -v f="$f" '
            BEGIN { p=f; gsub(/\./,"\\.",p); re="/" p "$" }
            ($1==f || $1 ~ re) && $2 ~ /^[0-9.]+$/ && $3 ~ /^([0-9.]+|n\/a)$/ {
                if ($2+0 > best) { best=$2+0; b=$3 }
            }
            END { if (best) print best, b }')
        pct=${1:-}; brn=${2:-}
        if [ -z "$pct" ]; then
            # A gated CGI with NO measurement is a gate FAILURE, not a skip -
            # a silent skip is exactly how lazysite-auth.pl went unmeasured
            # for weeks (2026-07-10 review, D3).
            printf "  %-34s NOT MEASURED - gate failure\n" "$f" >&2
            fail=1
            continue
        fi
        # Per-file branch-floor override: `branch_floor[FILE]=NN` in the floor
        # file, for a file whose subprocess measurement is documented as noisy.
        bfl=$(grep -F "branch_floor[$f]=" "$FLOOR_FILE" 2>/dev/null | grep -oE '[0-9]+$' | head -1)
        : "${bfl:=$branch_floor}"
        st=ok
        awk -v t="$pct" -v fl="$floor" 'BEGIN{ exit (t+0 >= fl+0) ? 0 : 1 }' || { st=BELOW; fail=1; }
        awk -v t="$brn" -v fl="$bfl" 'BEGIN{ exit (t+0 >= fl+0) ? 0 : 1 }' || { st=BELOW-BRANCH; fail=1; }
        printf "  %-34s stmt %5s%%  bran %5s%%  (floors %s%%/%s%%)  %s\n" \
            "$f" "$pct" "$brn" "$floor" "$bfl" "$st"
    done
    if [ "$fail" = 1 ]; then
        echo "COVERAGE BELOW FLOOR" >&2
        exit 1
    fi
    echo "coverage: all measured production CGIs at or above ${floor}% statements / ${branch_floor}% branches (target 75%)"
    # Record the pass against the digest of what produced it. Written only on a
    # PASS - a failed run must never license a skip.
    if [ -n "${COVER_DIGEST:-}" ]; then
        printf '{\n  "inputs_digest": "%s",\n  "result": "pass",\n  "floor": "%s",\n  "branch_floor": "%s",\n  "host": "%s",\n  "captured": "%s"\n}\n' \
            "$COVER_DIGEST" "$floor" "$branch_floor" "$(hostname)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            > "$COVER_RECORD"
        echo "coverage: recorded against digest $COVER_DIGEST" >&2
    fi

fi
