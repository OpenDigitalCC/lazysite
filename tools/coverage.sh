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
rm -rf "$DB"

echo "Running the suite under Devel::Cover (subprocess CGIs instrumented)..." >&2
PERL5OPT="-MDevel::Cover=-db,$DB,-silent,1,+ignore,^/usr/,+ignore,/t/,+ignore,Devel" \
    prove -r t/ >/dev/null 2>&1 || true

# Report (drop the per-run noise).
cover -silent -report text "$DB" 2>/dev/null | grep -vE '^Run:[[:space:]]'

if [ "$1" = "--check" ]; then
    floor=$(grep -E '^floor=' "$FLOOR_FILE" 2>/dev/null | grep -oE '[0-9]+' | head -1)
    : "${floor:=60}"
    # Check each cleanly-measured production CGI's statement % against the floor.
    # (auth.pl/install.pl/plugins are split across tempdir copies - a known
    # limitation, excluded from the gate; see dist/config/coverage-floor.)
    report=$(cover -silent -report text "$DB" 2>/dev/null)
    fail=0
    for f in lazysite-dav.pl lazysite-processor.pl lazysite-manager-api.pl \
             tools/lazysite-users.pl tools/lazysite-bundle-apply.pl; do
        pct=$(printf '%s\n' "$report" | awk -v f="$f" '$1==f {print $2; exit}')
        if [ -z "$pct" ]; then
            printf "  %-34s not measured\n" "$f" >&2
            continue
        fi
        st=ok
        awk -v t="$pct" -v fl="$floor" 'BEGIN{ exit (t+0 >= fl+0) ? 0 : 1 }' || { st=BELOW; fail=1; }
        printf "  %-34s stmt %5s%%  (floor %s%%)  %s\n" "$f" "$pct" "$floor" "$st"
    done
    if [ "$fail" = 1 ]; then
        echo "COVERAGE BELOW FLOOR" >&2
        exit 1
    fi
    echo "coverage: all measured production CGIs at or above ${floor}% statements (target 75%)"
fi
