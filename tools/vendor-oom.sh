#!/bin/bash
# tools/vendor-oom.sh - refresh the pinned snapshot of OOM that lazysite's tests run on.
#
#   tools/vendor-oom.sh [--deb FILE] COMMIT [OOM_REPO]
#
# WHY A SNAPSHOT (SM1081, release manager 2026-10-14: "it isn't intended that oom
# changes will prevent a lazysite build ... we can't be testing against odoo to run
# a lazysite, it's just an extension, not core"). Lazysite's gate used to read OOM's
# working tree and the host's perl5 directory, and failed three times on 2026-10-13
# and 14 for changes that were not lazysite's. The tests now run on a copy of OOM
# held INSIDE this repository, t/vendor/oom/, taken from one released commit. A new
# OOM release is adopted by a reviewable commit that runs this script, and updates the
# SM747 filing's copy of the spec with it (lint 207 enforces both; lint 261 holds the
# files to the MANIFEST so a change is always deliberate).
#
# WHAT IT TAKES, all from COMMIT of the OOM repository (default /srv/projects/odoo/oom):
#   lib/                 the library the deb installs
#   t/lib/               OOM's test doubles (the deb does not ship them)
#   behaviours/ profiles/  OOM's data, found beside lib/ by OOM itself
#   docs/MAPPER-SPEC.md  the specification SM747 files a copy of
#   debian/copyright     the licence notice, kept as COPYRIGHT-OOM
# With --deb FILE it also checks that the deb's library and spec are byte-identical to
# COMMIT's, so the snapshot is known to be what that release shipped; without it the
# snapshot is "commit COMMIT" and says so.
#
# It writes t/vendor/oom/MANIFEST (the source and a sha256 per file) and prints what the
# SM747 filing's copy needs. It makes no network call and touches nothing outside
# t/vendor/oom/. Only this script and tools/ext-compat.sh may name /srv/projects/odoo
# (lint 262).
set -euo pipefail

DEB=''
if [ "${1:-}" = "--deb" ]; then
    DEB="${2:?--deb needs a file}"
    shift 2
fi
COMMIT="${1:?usage: tools/vendor-oom.sh [--deb FILE] COMMIT [OOM_REPO]}"
REPO="${2:-/srv/projects/odoo/oom}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${VENDOR_OOM_DEST:-$ROOT/t/vendor/oom}"    # the override is for t/tools/155 only
TMP="/tmp/vendor-oom-$$"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP"

git -C "$REPO" rev-parse --verify --quiet "$COMMIT^{commit}" >/dev/null || { echo "vendor-oom: no commit $COMMIT in $REPO" >&2; exit 1; }
FULL="$(git -C "$REPO" rev-parse "$COMMIT^{commit}")"
git -C "$REPO" archive "$FULL" lib t/lib behaviours profiles docs/MAPPER-SPEC.md debian/copyright | tar -x -C "$TMP"

DEBVER=''
if [ -n "$DEB" ]; then
    dpkg-deb -x "$DEB" "$TMP/deb"
    DEBVER="$(dpkg-deb -f "$DEB" Version)"
    diff -rq "$TMP/lib/Odoo" "$TMP/deb/usr/share/perl5/Odoo" >/dev/null \
        || { echo "vendor-oom: the deb's library is not commit $COMMIT's - it was built from another commit" >&2; exit 1; }
    zcat "$TMP/deb/usr/share/doc/libodoo-oom-perl/MAPPER-SPEC.md.gz" | cmp -s - "$TMP/docs/MAPPER-SPEC.md" \
        || { echo "vendor-oom: the deb's spec is not commit $COMMIT's" >&2; exit 1; }
fi

rm -rf "$DEST"
mkdir -p "$DEST/docs" "$DEST/t"
cp -R "$TMP/lib" "$DEST/lib"
cp -R "$TMP/t/lib" "$DEST/t/lib"
cp -R "$TMP/behaviours" "$DEST/behaviours"
cp -R "$TMP/profiles" "$DEST/profiles"
cp "$TMP/docs/MAPPER-SPEC.md" "$DEST/docs/MAPPER-SPEC.md"
cp "$TMP/debian/copyright" "$DEST/COPYRIGHT-OOM"
find "$DEST" -type d -exec chmod 0755 {} +
find "$DEST" -type f -exec chmod 0644 {} +

{
    echo "# The pinned snapshot of OOM that lazysite's tests run on (SM1081). Refreshed only by"
    echo "# tools/vendor-oom.sh; t/lint/261 holds every file below to its hash."
    echo "source-commit: $FULL"
    echo "source-commit-date: $(git -C "$REPO" log -1 --format=%cI "$FULL")"
    echo "source-subject: $(git -C "$REPO" log -1 --format=%s "$FULL")"
    echo "source-deb: ${DEBVER:-none (taken from the commit)}"
    echo "licence: Artistic-1.0-Perl or GPL-1+ (COPYRIGHT-OOM)"
    echo "spec-sha256: $(sha256sum "$DEST/docs/MAPPER-SPEC.md" | cut -d' ' -f1)"
    echo "#"
    (cd "$DEST" && find . -type f ! -name MANIFEST | sed 's|^\./||' | LC_ALL=C sort | xargs sha256sum)
} > "$DEST/MANIFEST"

N="$(grep -c '^[0-9a-f]\{64\}  ' "$DEST/MANIFEST")"
SPEC="$(sha256sum "$DEST/docs/MAPPER-SPEC.md" | cut -d' ' -f1)"
echo "vendor-oom: $N files from $FULL${DEBVER:+ (deb $DEBVER)} -> t/vendor/oom/"
echo
echo "The SM747 filing's copy of the spec (docs/feature-requests/SM747-*.md, 'The mapper"
echo "specification, FILED') must now say, in the SAME commit:"
echo "  | Source | \`t/vendor/oom/docs/MAPPER-SPEC.md\` |"
echo "  | sha256 at filing | \`$SPEC\` |"
echo "and its sections 7 to 10 and its Open list must be re-copied from that file"
echo "(they are the snapshot's own sections 7 to 10 with dashes and arrows made ASCII)."
echo "t/lint/207 fails until the filing matches the snapshot."
