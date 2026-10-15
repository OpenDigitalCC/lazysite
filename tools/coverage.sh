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
DB="${LAZYSITE_COVER_DB:-$ROOT/cover_db}"

# Where the instrumented suite's own output goes. Kept, not discarded: see the
# note at the prove line below - a coverage report is only meaningful about a
# suite that finished, and nothing could tell whether one had.
SUITE_LOG="${LAZYSITE_COVER_SUITE_LOG:-$ROOT/cover_db-suite.log}"
FLOOR_FILE="${LAZYSITE_COVER_FLOOR_FILE:-$ROOT/dist/config/coverage-floor}"

# SM1083 COVERAGE IN PARTS: a tree with a group map is measured group by group
# by tools/coverage-parts.sh, which calls back here once per group with
# LAZYSITE_COVER_GROUP set (and the tests, files, floors and record for it).
# LAZYSITE_COVER_WHOLE=1 runs the whole suite as before, in one DB.
case " $* " in *" --groups "* | *" --all "* | *" --group "* | *" --store "*) PARTS_ARGS=1 ;; *) PARTS_ARGS=0 ;; esac
if [ -z "${LAZYSITE_COVER_GROUP:-}" ] && [ "${LAZYSITE_COVER_WHOLE:-}" != 1 ] \
    && [ "${LAZYSITE_COVER_DECIDE_ONLY:-}" != 1 ] && [ "${LAZYSITE_COVER_REPORT_ONLY:-}" != 1 ] \
    && { [ -f "$ROOT/tools/coverage-groups.pl" ] || [ "$PARTS_ARGS" = 1 ]; }; then
    exec bash "$ROOT/tools/coverage-parts.sh" "$@"
fi

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

# SM1083: ONE heavy lock and a guard. Run alone, coverage waits for any other
# heavy job (naming the holder), then refuses to START on a host that cannot
# hold it: exit 3 is "not now" - a SKIP for the caller, never a failure. Inside
# the gate (LAZYSITE_HEAVY_HELD=1) the gate has already done both.
. "$ROOT/tools/heavy-lock.sh"
if [ "${LAZYSITE_HEAVY_HELD:-}" != 1 ] && [ "${LAZYSITE_COVER_DECIDE_ONLY:-}" != "1" ] \
    && [ "${LAZYSITE_COVER_REPORT_ONLY:-}" != "1" ]; then
    heavy_lock "$ROOT" "coverage.sh" wait || exit 2
    PF_RC=0
    PF_MSG=$(bash "$ROOT/tools/preflight.sh" HEAVY) || PF_RC=$?
    if [ "$PF_RC" -eq 3 ]; then
        echo "coverage: SKIPPED (not now) - $PF_MSG" >&2
        exit 3
    fi
fi

# `|| true` because `set -e` is on: without it a failed rm exits here with a
# bare "cannot remove" and no explanation at all, which is precisely how this
# presented - a wall of rm noise, no coverage output, and nothing saying why.
# SM896: NOT in REPORT_ONLY mode, which exists to report on a DB that already
# exists. The first run of that mode deleted the symlink it had been handed
# and then reported "Can't open database" - which the new report step caught,
# stderr and all, so the failure path got its verification unasked.
if [ "${LAZYSITE_COVER_REPORT_ONLY:-}" != "1" ]; then
    rm -rf "$DB" 2>/dev/null || true
fi

# A LIVE WRITER survives the rm, and that is the failure mode worth naming: a
# `prove` orphaned from a previous run keeps executing tests and re-creating
# lock files under $DB, so `rm -rf` reports "Directory not empty" and the run
# proceeds on a poisoned database. Every CGI then reports NOT MEASURED and the
# gate fails for a reason that has nothing to do with the code.
#
# Found the hard way: killing a coverage run's shell left its `prove` child
# reparented to init, still writing, for half an hour.
if [ -e "$DB" ] && [ "${LAZYSITE_COVER_REPORT_ONLY:-}" != "1" ]; then
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
# without touching the repository.
#
# SM950 (3): release.sh sets it too, and only to a pass an earlier gate kept
# under tmp/release-gate/coverage-passes/ FOR THIS DIGEST. The decision below is
# unchanged and still made here: a record that is not a pass, or whose digest is
# not the one computed below, runs the stage. A run that measures writes its
# record to this path, so what release.sh offers is a copy beside the stage.
COVER_RECORD="${LAZYSITE_COVER_RECORD:-$ROOT/dist/config/coverage-last.json}"
# A group's digest is the group's (coverage in parts); the whole suite's is coverage-inputs.pl's.
COVER_DIGEST=$( if [ -n "${LAZYSITE_COVER_GROUP:-}" ]; then perl "$ROOT/tools/coverage-groups.pl" --digest "$LAZYSITE_COVER_GROUP"; else perl "$ROOT/tools/coverage-inputs.pl"; fi 2>/dev/null | awk '{print $1}')
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

# SM971 MEASURED -j AGAINST SERIAL PER FILE, not only in total (2026-10-08,
# t/unit/lib + t/unit/forms, 93 files, two runs of each): serial 234 s / 239 s,
# -j4 78 s / 79 s, -j8 59 s. Of 148 per-file rows and the total, all agreed but
# one, the same way every time: lib/Lazysite/Util.pm statements 83.3% serial,
# 83.0% at -j4 and -j8. At -j the counts land on env_allowlist(), which nothing
# in that subset calls, and leave _json_str(), which it does - a merge
# attribution fault, not noise. The gated CGIs the subset reaches (processor,
# users tool) agreed exactly. Left at -j4 for the release manager to rule on
# (serial costs about three times as long), recorded in SM971.
JOBS=${LAZYSITE_COVER_JOBS:-$(bash "$ROOT/tools/preflight.sh" JOBS)}
# A group runs ONLY its tests (one path a line in $LAZYSITE_COVER_TESTS); the
# whole suite is `-r t/`. Unquoted on purpose: a list of paths without spaces.
if [ -n "${LAZYSITE_COVER_TESTS:-}" ]; then
    TESTS=$(tr '\n' ' ' <"$LAZYSITE_COVER_TESTS")
    echo "Running group '${LAZYSITE_COVER_GROUP:-?}' ($(wc -l <"$LAZYSITE_COVER_TESTS") test files) under Devel::Cover, $JOBS-way..." >&2
else
    TESTS="-r t/"
    echo "Running the suite under Devel::Cover, $JOBS-way (subprocess CGIs instrumented)..." >&2
fi
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
# SM896: REAP THE LOCK FILES DEVEL::COVER LEAKS, WHILE THE SUITE RUNS.
#
# Devel::Cover 1.44 writes each structure file through a per-process temp
# (structure/.<digest>.<pid>), takes structure/.<digest>.<pid>.lock on it
# (DB/IO/Base.pm _lock), renames the temp into place - and never unlinks the
# lock. Only DB::clean removes them, and nothing calls it until `cover
# -delete`. One lock per structure file per PROCESS, and this suite is 7,198
# processes x ~574 files: 4,131,376 zero-byte dotfiles on the 0.14.3 cut, on a
# filesystem with 4,751,360 inodes in total. Both attempts at that cut ran the
# suite to a clean PASS and then died at the report step with 0 inodes free -
# reported as "the instrumented run did not finish" (SM895), because cover(1)'s
# stderr was discarded. `ls` does not show dotfiles, which is how four million
# files hid in plain sight; a one-test probe showed 69 locks for 8 processes,
# 141 for 16, structure files constant at 9.
#
# A lock guards a temp file whose name carries the writer's pid; no other
# process ever contends for it, and a structure write takes milliseconds. So a
# lock older than a minute belongs to a write that has finished, and deleting
# it changes nothing that is measured. The reaper runs beside the suite and
# bounds the DB to live processes x files - thousands, not millions. The
# measured footprint is printed after the run so release.sh's preflight can be
# checked against a number rather than a memory.
_reap_locks() {
    find "$DB/structure" -name '.*.lock' -type f -mmin +1 -delete 2>/dev/null || true
}
if [ "${LAZYSITE_COVER_REPORT_ONLY:-}" = "1" ]; then
    # Re-report an existing DB - a kept release stage, say - without the
    # two-hour suite. The pass record further down is NOT written from this
    # path: a report over a DB somebody chose is not a gate run, and must not
    # licence skipping one.
    echo "coverage: REPORT ONLY - reusing $DB, no suite run" >&2
    SUITE_RC=0
else
    # SM1083: holding no pipe of the caller's - a kill leaves the sleep behind
    # for up to 30 s, and a captured run (t/tools/60) waited on it each time.
    ( while :; do sleep 30; _reap_locks; done ) >/dev/null 2>&1 </dev/null &
    REAPER_PID=$!
    PERL5OPT="-MDevel::Cover=-db,$DB,-silent,1,+ignore,^/usr/,+ignore,^/tmp/,+ignore,/t/,+ignore,Devel" \
        prove -l -j"$JOBS" $TESTS > "$SUITE_LOG" 2>&1 && SUITE_RC=0 || SUITE_RC=$?
    kill "$REAPER_PID" 2>/dev/null || true
    wait "$REAPER_PID" 2>/dev/null || true
fi

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
# SM764: ONE RE-RUN, ALONE, AND SAID SO. The 0.13.4 coverage stage failed on
# a test that passes alone and passed the plain suite four minutes earlier:
# a render ceiling met under four instrumented jobs. The fix for the ceiling
# is elsewhere (t/lint/120); this is the gate's own defence against the next
# one. A file that failed under the parallel instrumented run is run ONCE
# more, alone, under the same instrumentation. If it passes, the stage
# proceeds - and the log, this output and the release log all carry which
# files needed it, because a test that passes alone and fails in company is
# a fact about the test that somebody should read, not a fault to hide. If
# it fails alone too, the stage fails as before.
RERUN=""
if [ "$SUITE_RC" -ne 0 ]; then
    failed=$(grep -E '^t/.*\.t +\(Wstat' "$SUITE_LOG" | sed -E 's/ +\(Wstat.*//' | sort -u)
    if [ -n "$failed" ]; then
        echo "coverage: re-running alone, once, under instrumentation: $failed" >&2
        rerun_rc=0
        for tf in $failed; do
            if PERL5OPT="-MDevel::Cover=-db,$DB,-silent,1,+ignore,^/usr/,+ignore,^/tmp/,+ignore,/t/,+ignore,Devel" \
                prove -l "$tf" >> "$SUITE_LOG" 2>&1; then
                RERUN="$RERUN $tf"
            else
                rerun_rc=1
            fi
        done
        if [ "$rerun_rc" -eq 0 ]; then
            SUITE_RC=0
            echo "coverage: PASSED ALONE (failed in the -j$JOBS run):$RERUN" >&2
            echo "coverage: these files pass alone and fail in company - read them." >&2
        fi
    fi
fi

suite_files=$(grep -cE '^t/.*\.t ' "$SUITE_LOG" 2>/dev/null || echo 0)
echo "suite under instrumentation: exit=$SUITE_RC, ${suite_files} file(s) reported" >&2
if [ "$SUITE_RC" -ne 0 ]; then
    echo "coverage: THE SUITE DID NOT PASS under instrumentation." >&2
    echo "coverage: the numbers below describe a run that did not finish." >&2
    grep -E '\(Wstat' "$SUITE_LOG" | head -10 >&2
    echo "coverage: full output in $SUITE_LOG" >&2
fi

# SM896: every lock is stale now - nothing is writing - so remove them all
# before cover(1) reads the DB. This is what DB::clean does, at the moment it
# should have happened. Then say what the DB cost, in inodes, as measured, so
# release.sh's preflight can be checked against a number.
find "$DB" -name '*.lock' -type f -delete 2>/dev/null || true
# -L: REPORT_ONLY is handed a symlink, and `du -s` on a symlink counts the link.
echo "coverage: DB footprint $(du -sL --inodes "$DB" 2>/dev/null | cut -f1) inode(s), $(ls "$DB/runs" 2>/dev/null | wc -l) run(s)" >&2

# THE REPORT STEP KEEPS ITS OWN STDERR AND ITS OWN EXIT STATUS (SM895).
#
# This was `cover ... 2>/dev/null | grep -vE '^Run:'` under set -e with no
# pipefail: the pipeline's status was grep's, grep -v of an EMPTY input exits
# 1, and the script ended here - after a suite that had passed - with cover's
# reason discarded and release.sh announcing that the suite had not finished.
# Twice on one release. cover is run ONCE (it was run twice, ~12 minutes each
# on this suite) into a variable; its stderr goes beside the suite log, which
# release.sh already keeps outside the stage for exactly this reason.
COVER_ERR="${SUITE_LOG%-suite.*}-cover-stderr.txt"
report=$(cover -silent -report text "$DB" 2>"$COVER_ERR") || {
    rc=$?
    # SM1083: a killed report is the host, not the code.
    if [ "$rc" -eq 137 ] || [ "$rc" -eq 143 ]; then
        echo "coverage: KILLED (memory/signal) - cover exit $rc after a suite that passed." >&2
        echo "coverage: not a test failure and not a shortfall; the host ran out of memory or was signalled." >&2
        exit 6
    fi
    echo "coverage: THE REPORT STEP FAILED (cover exit $rc) after a suite that passed." >&2
    echo "coverage: cover's stderr, kept at $COVER_ERR:" >&2
    tail -20 "$COVER_ERR" >&2
    exit 4
}
if [ -z "$report" ]; then
    echo "coverage: THE REPORT STEP FAILED - cover exited 0 and printed NOTHING." >&2
    echo "coverage: cover's stderr, kept at $COVER_ERR:" >&2
    tail -20 "$COVER_ERR" >&2
    exit 4
fi
printf '%s\n' "$report" | grep -vE '^Run:[[:space:]]' || true

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
    # $report is the one run above - it was run a second time here, another
    # ~12 minutes on this suite, and a second chance to die silently.
    fail=0
    PRE_REBASELINE=0
    MOVED=""
    grep -qx 'status=pre-rebaseline' "$FLOOR_FILE" 2>/dev/null && PRE_REBASELINE=1
    # P19 (WORK-PLAN-0154, ruled 2026-10-12): AND EVERY FILE THE CGIS WERE SPLIT
    # INTO, each to its own floor. SM944 moved the processor into its parts
    # (lazysite-processor/*.pm) and the manager's actions into
    # lib/Lazysite/Manager/*.pm, and the gate went on naming the CGIs only - so
    # most of the code it was written to hold had no floor at all. PER FILE,
    # not one floor over a CGI's parts pooled: a pooled number lets a large
    # well-tested part carry a small untested one (oembed.pm measured 34.6%
    # beside render.pm's 97.1%), which is the hiding a floor exists to stop.
    # The list is read from the tree, so a part added later is gated the day it
    # lands. Each takes the floors above unless dist/config/coverage-floor
    # names its own (`floor[FILE]=`, `branch_floor[FILE]=`) - set for the files
    # measured below the general floors, at what they measured, to ratchet up.
    PARTS=$(ls lazysite-processor/*.pm lib/Lazysite/Manager/*.pm 2>/dev/null || true)
    for f in lazysite-dav.pl lazysite-processor.pl lazysite-manager-api.pl \
             lazysite-auth.pl lazysite-mcp.pl lazysite-oauth.pl \
             tools/lazysite-users.pl tools/lazysite-bundle-apply.pl $PARTS; do
        # SM1083 coverage in parts: a group checks only its own files.
        if [ -n "${LAZYSITE_COVER_FILES:-}" ] && ! grep -qxF "$f" "$LAZYSITE_COVER_FILES"; then continue; fi
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
            # SM1083 coverage in parts, pre-rebaseline: the group's own tests may
            # not reach a file the whole suite did (0.15.5: the tools group's 17
            # tests never ran tools/lazysite-bundle-apply.pl, whose test lives in
            # t/tools/). That is a measure too; it is recorded, and the gate goes on.
            if [ "$PRE_REBASELINE" = 1 ]; then
                printf "  %-38s NOT MEASURED by this group's tests  MOVEMENT (pre-rebaseline, was gate failure)\n" "$f"
                MOVED="$MOVED$f not measured by this group's tests; "
                continue
            fi
            printf "  %-34s NOT MEASURED - gate failure\n" "$f" >&2
            fail=1
            continue
        fi
        # Per-file branch-floor override: `branch_floor[FILE]=NN` in the floor
        # file, for a file whose subprocess measurement is documented as noisy.
        bfl=$(grep -F "branch_floor[$f]=" "$FLOOR_FILE" 2>/dev/null | grep -oE '[0-9]+$' | head -1)
        : "${bfl:=$branch_floor}"
        # P19: and its own statement floor, `floor[FILE]=NN` - matched as the
        # whole key, so branch_floor[FILE] is never read as it.
        sfl=$(awk -F= -v k="floor[$f]" '$1 == k { print $2; exit }' "$FLOOR_FILE" 2>/dev/null | grep -oE '^[0-9]+' | head -1)
        : "${sfl:=$floor}"
        st=ok
        fst=0
        awk -v t="$pct" -v fl="$sfl" 'BEGIN{ exit (t+0 >= fl+0) ? 0 : 1 }' || { st=BELOW; fst=1; }
        awk -v t="$brn" -v fl="$bfl" 'BEGIN{ exit (t+0 >= fl+0) ? 0 : 1 }' || { st=BELOW-BRANCH; fst=1; }
        # SM1083 coverage in parts, pre-rebaseline: the floors were measured
        # under the whole suite; a group's own measure may come in lower. Until
        # the group is re-baselined, a shortfall is MOVEMENT - printed, kept in
        # the record for the re-baseline commit - and does not fail the gate.
        # SM1083 n596: judged PER FILE. The first version reset fail=0 here, so a
        # later file's MOVEMENT cleared a failure an earlier file had set.
        if [ "$fst" = 1 ] && [ "$PRE_REBASELINE" = 1 ]; then
            st="MOVEMENT (pre-rebaseline, was $st)"
            MOVED="$MOVED$f stmt $pct% bran $brn% vs $sfl%/$bfl%; "
        elif [ "$fst" = 1 ]; then
            fail=1
        fi
        printf "  %-38s stmt %5s%%  bran %5s%%  (floors %s%%/%s%%)  %s\n" \
            "$f" "$pct" "$brn" "$sfl" "$bfl" "$st"
    done
    if [ "$fail" = 1 ]; then
        echo "COVERAGE BELOW FLOOR" >&2
        exit 1
    fi
    if [ -n "$MOVED" ]; then
        echo "coverage: PRE-REBASELINE - moved against the starting floors, recorded, not failed: $MOVED" >&2
    fi
    echo "coverage: all measured production CGIs and their parts at or above their floors
 (${floor}% statements / ${branch_floor}% branches unless named; target 75%)"
    # Record the pass against the digest of what produced it. Written only on a
    # PASS - a failed run must never license a skip. And never from REPORT_ONLY
    # (SM896): that path reports on a DB somebody pointed it at, which is not a
    # gate run of this tree, so it cannot be allowed to excuse one.
    if [ -n "${COVER_DIGEST:-}" ] && [ "${LAZYSITE_COVER_REPORT_ONLY:-}" != "1" ]; then
        printf '{\n  "inputs_digest": "%s",\n  "result": "pass",\n  "group": "%s",\n  "status": "%s",\n  "movement": "%s",\n  "floor": "%s",\n  "branch_floor": "%s",\n  "host": "%s",\n  "captured": "%s"\n}\n' \
            "$COVER_DIGEST" "${LAZYSITE_COVER_GROUP:-whole}" "$([ "$PRE_REBASELINE" = 1 ] && echo pre-rebaseline || echo baselined)" "$MOVED" \
            "$floor" "$branch_floor" "$(hostname)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            > "$COVER_RECORD"
        echo "coverage: recorded against digest $COVER_DIGEST" >&2
    fi

fi
