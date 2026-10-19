#!/usr/bin/env bash
# SM1083: the gate's stage base. Prints the directory: LAZYSITE_STAGE_DIR when
# set, else a DISK path (/var/tmp/lazysite-stage; /tmp is RAM-backed and ran out
# of inodes; /srv is nearly full). Override: LAZYSITE_STAGE_DEFAULT. The default
# is created, and retained stages older than 2 days are removed from it.
set -u
if [ -n "${LAZYSITE_STAGE_DIR:-}" ]; then
    echo "$LAZYSITE_STAGE_DIR"
    exit 0
fi
d=${LAZYSITE_STAGE_DEFAULT:-/var/tmp/lazysite-stage}
# SM1187: a root another user made (0775 their group, or 0755) cannot take this
# user's stages, and the run that tried died at mkdir. A per-user root beside it
# always works and keeps each user's kept stages removable by that user; the
# shared name stays the default wherever it is writable, so nothing moves for the
# common single-user host. Not world-writable: a sticky 1777 root would let any
# local user plant a stage-shaped directory for the gate to run.
if [ -e "$d" ] && { [ ! -d "$d" ] || [ ! -w "$d" ] || [ ! -x "$d" ]; }; then
    echo "stage-default.sh: $d is not writable by $(id -un); using $d-$(id -un)." >&2
    d="$d-$(id -un)"
fi
mkdir -p "$d" || { echo "stage-default.sh: cannot make $d - set LAZYSITE_STAGE_DIR to a directory you can write." >&2; exit 1; }
find "$d" -mindepth 1 -maxdepth 1 -mtime +2 -exec rm -rf -- {} + 2>/dev/null
echo "$d"
