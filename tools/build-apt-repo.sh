#!/bin/bash
# tools/build-apt-repo.sh - generate a signed-able apt repository from dist/.
#
# SM272. The packages have existed since 0.6.10 and there has never been
# anywhere to install them FROM, so 17 production sites take a tarball. This
# builds the repository; it does not publish it and it does not sign it.
#
# WHY THOSE ARE SEPARATE, and stay separate:
#
#   - Publication is egress. It belongs to whoever holds the credential, and a
#     build that can publish is a build that publishes by accident.
#   - Signing needs a private key, and where that key lives, who may use it,
#     and how a compromise is recovered are the questions SM272 exists to ask.
#     They are not answerable by packaging code and this script does not
#     pretend to answer them.
#
# So the output is a local tree an operator can inspect, sign and rsync. That
# is useful under every answer to "Forgejo or a static repo", which is why it
# is built before that decision rather than after.
#
# Usage: tools/build-apt-repo.sh --channel edge|beta|stable [--out DIR]
#   --channel   which suite these packages belong in. REQUIRED - see below.
#   --out       repository root (default: <repo>/dist/apt)
#   --sign KEY  gpg key id to sign the Release file with. Without it the
#               repository is built UNSIGNED and says so; apt will refuse it
#               until it is signed, which is the correct default.
set -euo pipefail

REPO=$(dirname "$(dirname "$(readlink -f "$0")")")
OUT="$REPO/dist/apt"
CHANNEL=
SIGN_KEY=

while [ $# -gt 0 ]; do
    case $1 in
        --channel) CHANNEL=${2:-}; shift 2 ;;
        --out)     OUT=${2:-};     shift 2 ;;
        --sign)    SIGN_KEY=${2:-}; shift 2 ;;
        *) echo "build-apt-repo: unknown argument: $1" >&2; exit 2 ;;
    esac
done

# THE CHANNEL IS REQUIRED AND IS NOT GUESSED.
#
# lazysite's channel ladder is edge < beta < stable, and a site's update_channel
# is the MINIMUM it accepts (SM356). An apt repository expresses that as suites,
# and the failure mode to design against is an edge build reaching a stable
# host - which happens if a suite is chosen by default, by filename, or by
# whatever was there last. So it is named explicitly on every invocation and
# nothing infers it.
case "$CHANNEL" in
    edge|beta|stable) ;;
    "") echo "build-apt-repo: --channel is required (edge|beta|stable). It is" >&2
        echo "build-apt-repo: never inferred: an edge build in the stable suite" >&2
        echo "build-apt-repo: is exactly what the ladder exists to prevent." >&2
        exit 2 ;;
    *)  echo "build-apt-repo: unknown channel '$CHANNEL'" >&2; exit 2 ;;
esac

command -v apt-ftparchive >/dev/null || {
    echo "build-apt-repo: apt-ftparchive not installed (apt: apt-utils)" >&2
    exit 1
}

DEBS=$(find "$REPO/dist" -maxdepth 1 -name '*.deb' -print | sort)
if [ -z "$DEBS" ]; then
    echo "build-apt-repo: no .deb files in $REPO/dist - build a release first" >&2
    exit 1
fi

POOL="$OUT/pool/main"
DISTDIR="$OUT/dists/$CHANNEL/main/binary-all"
mkdir -p "$POOL" "$DISTDIR"

echo "==> Repository root: $OUT"
echo "==> Suite: $CHANNEL"

n=0
for deb in $DEBS; do
    cp -f "$deb" "$POOL/"
    n=$((n + 1))
done
echo "==> Pooled $n package(s)"

( cd "$OUT" && apt-ftparchive packages pool/main > "dists/$CHANNEL/main/binary-all/Packages" )
gzip -9fk "$DISTDIR/Packages"

# The Release file. Origin/Label/Suite are what apt pins against, and Suite is
# the channel - so a host configured for `stable` cannot be handed edge
# packages by a repository that simply forgot which one it was building.
( cd "$OUT" && apt-ftparchive \
    -o "APT::FTPArchive::Release::Origin=lazysite" \
    -o "APT::FTPArchive::Release::Label=lazysite" \
    -o "APT::FTPArchive::Release::Suite=$CHANNEL" \
    -o "APT::FTPArchive::Release::Codename=$CHANNEL" \
    -o "APT::FTPArchive::Release::Architectures=all" \
    -o "APT::FTPArchive::Release::Components=main" \
    release "dists/$CHANNEL" > "dists/$CHANNEL/Release" )

# POSITIVE CHECK: the indices must name the packages that were pooled. An
# apt-ftparchive that walked the wrong directory exits 0 and writes an empty
# Packages file, and an empty repository installs nothing while looking healthy.
pkgs_in_index=$(grep -c '^Package: ' "$DISTDIR/Packages" || true)
if [ "$pkgs_in_index" -ne "$n" ]; then
    echo "build-apt-repo: pooled $n package(s) and the index names $pkgs_in_index." >&2
    echo "build-apt-repo: an empty or short index installs nothing while the" >&2
    echo "build-apt-repo: build reports success." >&2
    exit 1
fi
echo "==> Indexed $pkgs_in_index package(s)"

if [ -n "$SIGN_KEY" ]; then
    command -v gpg >/dev/null || {
        echo "build-apt-repo: gpg not installed, cannot sign" >&2; exit 1; }
    gpg --default-key "$SIGN_KEY" --armor --detach-sign \
        --output "$OUT/dists/$CHANNEL/Release.gpg" "$OUT/dists/$CHANNEL/Release"
    gpg --default-key "$SIGN_KEY" --clearsign \
        --output "$OUT/dists/$CHANNEL/InRelease" "$OUT/dists/$CHANNEL/Release"
    echo "==> Signed with $SIGN_KEY"
else
    # Said plainly rather than left for apt to discover. An unsigned repository
    # is not a broken one - it is an unfinished one, and the missing half is a
    # decision about key custody rather than a command.
    echo "==> UNSIGNED. apt will refuse this repository until dists/$CHANNEL/Release"
    echo "    is signed. Re-run with --sign <keyid>, or sign it wherever the key"
    echo "    actually lives - which is the open question in SM272 and is not"
    echo "    something this script should answer for you."
fi

echo ""
echo "==> Built. To serve it, publish $OUT behind a web server and point a host at:"
echo "    deb [signed-by=/usr/share/keyrings/lazysite.gpg] <url> $CHANNEL main"
