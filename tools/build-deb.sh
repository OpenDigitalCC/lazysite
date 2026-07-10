#!/bin/bash
# tools/build-deb.sh - build lazysite-common.deb from a clean staging copy
# (SM139 increment 1). Never modifies the working tree: the source set is
# exported into scratch, dpkg-buildpackage runs there, and the resulting
# .deb lands in /srv/projects/packages/ (house convention).
#
# The export uses `git ls-files --cached --others --exclude-standard`
# rather than `git archive HEAD`: under the uncommitted-tree release
# contract the session's work is not yet committed, and ls-files captures
# exactly the tracked + new-untracked set while still honouring
# .gitignore (no cover_db/, tmp/, dist tarballs, generated artefacts).
#
# Usage: tools/build-deb.sh
#   BUILD_AREA   scratch base (default /srv/tmp; kept on failure)
#   PACKAGES_DIR output dir (default /srv/projects/packages)
set -euo pipefail

REPO=$(dirname "$(dirname "$(readlink -f "$0")")")
BUILD_AREA=${BUILD_AREA:-/srv/tmp}
PACKAGES_DIR=${PACKAGES_DIR:-/srv/projects/packages}
STAGE="$BUILD_AREA/lazysite-deb-$$"
SRC="$STAGE/lazysite"

fail=1
cleanup() {
    if [ "$fail" -ne 0 ]; then
        echo "build-deb: FAILED; staging retained for inspection: $STAGE" >&2
    else
        rm -rf "$STAGE"
    fi
}
trap cleanup EXIT

command -v dpkg-buildpackage >/dev/null || {
    echo "build-deb: dpkg-buildpackage not installed (apt: dpkg-dev, debhelper)" >&2
    exit 1
}
[ -f "$REPO/debian/control" ] || {
    echo "build-deb: no debian/control under $REPO" >&2
    exit 1
}

echo "==> Staging clean source copy: $SRC"
mkdir -p "$SRC"
git -C "$REPO" ls-files -z --cached --others --exclude-standard \
    | tar -C "$REPO" --null --files-from=- -cf - \
    | tar -C "$SRC" -xf -

echo "==> dpkg-buildpackage -us -uc -b"
# dpkg-buildpackage only works from inside the source tree; the subshell
# keeps the cd from leaking.
( cd "$SRC" && dpkg-buildpackage -us -uc -b )

mkdir -p "$PACKAGES_DIR"
deb_count=0
for deb in "$STAGE"/*.deb; do
    [ -f "$deb" ] || continue
    cp -- "$deb" "$PACKAGES_DIR/"
    echo "==> $PACKAGES_DIR/$(basename "$deb")"
    deb_count=$((deb_count + 1))
done
if [ "$deb_count" -eq 0 ]; then
    echo "build-deb: no .deb produced" >&2
    exit 1
fi

fail=0
echo "==> OK ($deb_count package(s))"
