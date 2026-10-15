#!/bin/bash
# tools/ext-compat.sh - the COMPATIBILITY TIER for the Odoo extension. ADVISORY.
#
#   tools/ext-compat.sh [--night]
#
# The gate runs the Odoo tests on the pinned snapshot of OOM in t/vendor/oom/ and on
# nothing else (SM1081; t/lint/262). This script runs the SAME tests (t/unit/odoo and
# t/integration/170-174) against the OOM that is actually on the host, to say early
# whether a newer OOM would break lazysite's extension:
#
#   1. the INSTALLED DEB (libodoo-oom-perl) - what an operator has;
#   2. OOM's WORKING TREE - what is about to be released.
#
# Each target is reported on its own line. It is ADVISORY, by the release manager's
# ruling (2026-10-14: "it isn't intended that oom changes will prevent a lazysite
# build"): it ALWAYS exits 0, never touches the gate, and a missing target is a skipped
# line, not a fault. With --night (tools/overnight.sh passes it) a failing target also
# files one short note in the inbox, once a day per target, and nothing else.
#
# The test doubles come from the snapshot unless the target brings its own (the
# tree's t/lib), via LAZYSITE_OOM_LIB / LAZYSITE_OOM_TEST_LIB, which exist for this
# script alone. Live Odoo is never run here: tmp/live/odoo-live.pl is manual (DEVELOPER.md).
#
# This and tools/vendor-oom.sh are the only files allowed to name OOM's tree or the
# deb's directories (t/lint/262).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NIGHT=0
[ "${1:-}" = "--night" ] && NIGHT=1
TREE="${OOM_TREE:-/srv/projects/odoo/oom}"
# The deb's library. The override exists for t/tools/154 alone, so that test does not depend
# on which OOM this host happens to have installed (it failed the day OOM 0.11 was installed).
DEB_LIB="${OOM_DEB_LIB:-/usr/share/perl5}"
INBOX="${LAZYSITE_INBOX:-/srv/projects/lazysite/inbox}"
DAY="$(date +%F)"
TESTS=("$ROOT/t/unit/odoo/")
for f in "$ROOT"/t/integration/17[0-4]*.t; do [ -f "$f" ] && TESTS+=("$f"); done

report() {    # report LABEL VERSION LIBDIR TESTLIBDIR-or-empty
    local label="$1" ver="$2" lib="$3" tl="$4" out rc failed note
    out="$(cd "$ROOT" && env LAZYSITE_OOM_LIB="$lib" ${tl:+LAZYSITE_OOM_TEST_LIB="$tl"} \
        timeout 900 prove -j2 -I"$ROOT/lib" "${TESTS[@]}" 2>&1)"
    rc=$?
    if [ "$rc" = 0 ]; then
        echo "ext-compat: $label ($ver): PASS - $(echo "$out" | grep -E '^Files=' | sed 's/,.*//')"
        return
    fi
    failed="$(echo "$out" | grep -E '^ *t/.*\(Wstat' | sed 's/^ *//; s/ *(Wstat.*//' | tr '\n' ' ')"
    echo "ext-compat: $label ($ver): FAIL (advisory) - ${failed:-prove exit $rc}"
    if [ "$NIGHT" = 1 ] && [ -d "$INBOX" ]; then
        note="$INBOX/$DAY-oom-changes-break-lazysites-odoo-tests-$(echo "$label" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' '-' | sed 's/-*$//').md"
        if [ ! -e "$note" ]; then
            {
                echo "OOM $ver ($label) changes break lazysite's Odoo tests: ${failed:-see tools/ext-compat.sh}"
                echo
                echo "Advisory only (SM1081): the gate runs on the pinned snapshot in t/vendor/oom and is unaffected."
                echo "Run tools/ext-compat.sh to see it; adopt the new OOM with tools/vendor-oom.sh when the release manager decides."
            } > "$note"
        fi
    fi
}

echo "ext-compat: advisory compatibility tier ($DAY) - never the gate"

if dpkg -s libodoo-oom-perl >/dev/null 2>&1 && [ -f "$DEB_LIB/Odoo/Ops.pm" ]; then
    report "installed deb" "$(dpkg-query -W -f='${Version}' libodoo-oom-perl)" "$DEB_LIB" ""
else
    echo "ext-compat: installed deb: skipped - libodoo-oom-perl is not installed"
fi

if [ -f "$TREE/lib/Odoo/Ops.pm" ]; then
    report "OOM tree" "$(sed -n "s/^our \$VERSION = '\\(.*\\)';/\\1/p" "$TREE/lib/Odoo/Ops.pm" | head -1)" "$TREE/lib" "$TREE/t/lib"
else
    echo "ext-compat: OOM tree: skipped - no tree at $TREE"
fi
exit 0
