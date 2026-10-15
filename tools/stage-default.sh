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
mkdir -p "$d" || exit 1
find "$d" -mindepth 1 -maxdepth 1 -mtime +2 -exec rm -rf -- {} + 2>/dev/null
echo "$d"
