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
FLOOR_FILE="$ROOT/dist/config/coverage-floor"

# ONE RUN AT A TIME. Two concurrent runs share $DB: the second one's `rm -rf`
# deletes files the first is still writing, and both then report nonsense - all
# CGIs "NOT MEASURED", which reads as a real gate failure. That cost an hour on
# 2026-08-13, twice, and neither run said anything about the other.
LOCK="$ROOT/.coverage.lock"
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK"
    if ! flock -n 9; then
        echo "coverage: another run holds $LOCK - refusing to share cover_db." >&2
        echo "  Wait for it, or stop it first. Two runs corrupt each other's" >&2
        echo "  results and report every CGI as NOT MEASURED." >&2
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

echo "Running the suite under Devel::Cover (subprocess CGIs instrumented)..." >&2
PERL5OPT="-MDevel::Cover=-db,$DB,-silent,1,+ignore,^/usr/,+ignore,/t/,+ignore,Devel" \
    prove -r t/ >/dev/null 2>&1 || true

# Report (drop the per-run noise).
cover -silent -report text "$DB" 2>/dev/null | grep -vE '^Run:[[:space:]]'

if [ "$1" = "--check" ]; then
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
fi
