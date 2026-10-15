#!/usr/bin/env bash
# tools/coverage-parts.sh - coverage in parts (SM1083): the driver tools/coverage.sh
# hands over to when the tree has a group map.
#
#   tools/coverage.sh --check            # what the gate runs: every group matched or measured
#   tools/coverage.sh --check --all      # measure every group, matched or not
#   tools/coverage.sh --groups           # list the groups and their state, run nothing
#   tools/coverage.sh --group G --check  # one group, as the driver would run it
#
# Each group (tools/coverage-groups.pl --list) has its own inputs digest, its
# own cover DB (cover_db-GROUP), its own floor lines and its own recorded pass:
# $STORE/GROUP/DIGEST.json, STORE being tmp/release-gate/coverage-passes under
# the main checkout ($LAZYSITE_COVER_STORE or --store DIR overrides). A group
# whose digest matches a recorded pass is REUSED and not run; the others are
# measured, each by tools/coverage.sh in group mode (LAZYSITE_COVER_GROUP),
# which knows which tests to run, which files to floor-check and what to record.
# A group with no floor-checked file has nothing to measure and is so marked.
#
# One guard and one lock for the whole run (tools/preflight.sh HEAVY, the heavy
# lock), taken here unless the gate already holds them (LAZYSITE_HEAVY_HELD=1).
# Exit 3 from the guard is "not now" - a skip, not a failure.
#
# Markers release.sh reads, as coverage.sh printed them for the whole suite:
#   "coverage: SKIPPED - every group matched a recorded pass"   -> reused
#   "COVERAGE BELOW FLOOR" / "coverage: KILLED (memory/signal)" -> as before
# A combined record (digest of every group's digest) goes to
# $LAZYSITE_COVER_RECORD or dist/config/coverage-last.json, so a receipt still
# carries one record and build still commits it.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
. "$ROOT/tools/heavy-lock.sh"

ALL=0
LIST=0
ONE=""
STORE="${LAZYSITE_COVER_STORE:-}"
CHECK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --all) ALL=1 ;;
        --groups) LIST=1 ;;
        --check) CHECK=1 ;;
        --group)
            ONE="$2"
            shift
            ;;
        --store)
            STORE="$2"
            shift
            ;;
        *)
            echo "coverage-parts: unknown argument '$1'" >&2
            exit 2
            ;;
    esac
    shift
done
if [ -z "$STORE" ]; then
    COMMON=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || COMMON="$ROOT/.git"
    STORE="$(dirname "$COMMON")/tmp/release-gate/coverage-passes"
fi
mkdir -p "$STORE"
GROUPS_PL="$ROOT/tools/coverage-groups.pl"

if [ "$LIST" = 1 ]; then
    echo "coverage groups (store $STORE):"
    perl "$GROUPS_PL" --state "$STORE" | awk -F'\t' '{ printf "  %-10s %-14s %s  %s\n", $1, $3, substr($2,1,12), $4 }'
    exit 0
fi

if [ "${LAZYSITE_HEAVY_HELD:-}" != 1 ]; then
    heavy_lock "$ROOT" "coverage.sh" wait || exit 2
    PF_RC=0
    PF_MSG=$(bash "$ROOT/tools/preflight.sh" HEAVY) || PF_RC=$?
    if [ "$PF_RC" -eq 3 ]; then
        echo "coverage: SKIPPED (not now) - $PF_MSG" >&2
        exit 3
    fi
fi

MEASURED=0
TIMES=""
REUSED=0
NOTHING=0
FAIL=""
RC=0
SCRATCH="${TMPDIR:-/tmp}/coverage-parts-$$"
mkdir -p "$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT

while IFS="$(printf '\t')" read -r name digest state note; do
    [ -n "$ONE" ] && [ "$name" != "$ONE" ] && continue
    case "$state" in
        nothing-gated)
            echo "coverage: group $name: nothing gated ($note)"
            NOTHING=$((NOTHING + 1))
            continue
            ;;
        pass)
            if [ "$ALL" != 1 ]; then
                echo "coverage: group $name: REUSED - digest ${digest:0:12} matched a recorded pass ($note)"
                REUSED=$((REUSED + 1))
                continue
            fi
            ;;
    esac
    echo "coverage: group $name: MEASURING - digest ${digest:0:12} ($note)"
    G0=$(date +%s)
    G0=$(date +%s)
    perl "$GROUPS_PL" --tests "$name" >"$SCRATCH/$name.tests"
    perl "$GROUPS_PL" --files "$name" >"$SCRATCH/$name.files"
    perl "$GROUPS_PL" --floor "$name" >"$SCRATCH/$name.floor"
    if [ ! -s "$SCRATCH/$name.tests" ]; then
        echo "coverage: group $name: NO TESTS SELECTED for its files - the area map names none; gate failure." >&2
        FAIL="$name"
        RC=1
        break
    fi
    mkdir -p "$STORE/$name"
    GRC=0
    LAZYSITE_COVER_GROUP="$name" \
        LAZYSITE_COVER_DB="$ROOT/cover_db-$name" \
        LAZYSITE_COVER_RECORD="$STORE/$name/$digest.json" \
        LAZYSITE_COVER_TESTS="$SCRATCH/$name.tests" \
        LAZYSITE_COVER_FILES="$SCRATCH/$name.files" \
        LAZYSITE_COVER_FLOOR_FILE="$SCRATCH/$name.floor" \
        LAZYSITE_COVER_SUITE_LOG="${LAZYSITE_COVER_SUITE_LOG:-$ROOT/cover_db}-$name-suite.log" \
        LAZYSITE_COVER_FORCE=1 LAZYSITE_HEAVY_HELD=1 \
        bash "$ROOT/tools/coverage.sh" --check || GRC=$?
    if [ "$GRC" -ne 0 ]; then
        echo "coverage: group $name: FAILED (coverage.sh exit $GRC); no pass recorded for ${digest:0:12}" >&2
        FAIL="$name"
        RC=$GRC
        break
    fi
    if [ ! -f "$STORE/$name/$digest.json" ]; then
        echo "coverage: group $name: passed but left no record at $STORE/$name/$digest.json" >&2
        FAIL="$name"
        RC=4
        break
    fi
    GSECS=$(( $(date +%s) - G0 ))
    echo "coverage: group $name: PASSED and recorded (${GSECS}s)"
    MEASURED=$((MEASURED + 1))
    TIMES="${TIMES:+$TIMES, }$name ${GSECS}s"
done < <(perl "$GROUPS_PL" --state "$STORE")

# NO GROUPS IS NOT A PASS. A group map that fails to run (a syntax error, a
# missing dependency) read as "every group matched" the first time it was
# tried, in a test. Absence refuses, here as everywhere in this gate.
if [ -z "$FAIL" ] && [ $((MEASURED + REUSED + NOTHING)) -eq 0 ]; then
    echo "coverage: the group map ($GROUPS_PL --state) gave NO GROUPS - not a pass:" >&2
    perl "$GROUPS_PL" --state "$STORE" 2>&1 | head -5 >&2
    exit 4
fi

if [ -n "$FAIL" ]; then
    [ -n "$TIMES" ] && TIMES=" ($TIMES)"
    echo "coverage: GROUPS: $MEASURED measured$TIMES, $REUSED reused, $NOTHING nothing gated; STOPPED at $FAIL after $(( $(date +%s) - ${G0:-$(date +%s)} ))s" >&2
    exit "$RC"
fi
[ -n "$TIMES" ] && TIMES=" ($TIMES)"
echo "coverage: GROUPS: $MEASURED measured$TIMES, $REUSED reused, $NOTHING nothing gated"
[ -n "$ONE" ] && exit 0
if [ "$MEASURED" -eq 0 ]; then
    echo "coverage: SKIPPED - every group matched a recorded pass" >&2
fi
echo "coverage: all measured production CGIs and their parts at or above their floors (every group matched or measured)"

# The combined record, for the receipt.
ALLD=$(perl "$GROUPS_PL" --digest all | awk '{print $1}')
RECORD="${LAZYSITE_COVER_RECORD:-$ROOT/dist/config/coverage-last.json}"
mkdir -p "$(dirname "$RECORD")"
{
    printf '{\n  "inputs_digest": "%s",\n  "result": "pass",\n  "groups": {' "$ALLD"
    sep=""
    while IFS="$(printf '\t')" read -r name digest state note; do
        printf '%s\n    "%s": { "digest": "%s", "state": "%s" }' "$sep" "$name" "$digest" "$state"
        sep=","
    done < <(perl "$GROUPS_PL" --state "$STORE")
    printf '\n  },\n  "measured": %s,\n  "reused": %s,\n  "host": "%s",\n  "captured": "%s"\n}\n' \
        "$MEASURED" "$REUSED" "$(hostname)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$RECORD"
exit 0
