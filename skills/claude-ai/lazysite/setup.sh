#!/bin/sh
# setup.sh - install the bundled lazysite engine and make a local site.
#
# SM887. Runs in the claude.ai container: Ubuntu 24.04, root, no inbound
# network, filesystem reset between conversations, and THIS FOLDER IS MOUNTED
# READ-ONLY - so nothing here writes beside itself. Everything it creates goes
# under $LAZYSITE_HOME (default /root/lazysite-local).
#
# NOTHING IS FETCHED FROM ANY HOST THIS PROJECT OWNS. The .deb ships inside the
# skill, so the version matches the skill by construction and the only network
# needed is the Ubuntu archive, which the base image already depends on. An
# allowlist is per editor: a skill that reached lazysite.io would work for the
# person who wrote it and fail for everyone else, and the failure would arrive
# as a support question rather than a test result.
#
# IT DOES NOT USE `lazysite demo`, which is the obvious thing and the wrong one:
# demo refuses to run as root, and this container is root. The dev server
# serves a copy of the starter tree directly, seeding what it needs, with no
# provision step - measured, not assumed.
set -e

SKILL_DIR=$(cd "$(dirname "$0")" && pwd)
LAZYSITE_HOME=${LAZYSITE_HOME:-/root/lazysite-local}
SITE="$LAZYSITE_HOME/site"

say() { printf '%s\n' "$*"; }
fail() {
    say "FAIL: $*"
    exit 1
}

# --- 1. the engine ------------------------------------------------------------
#
# Idempotent by asking dpkg, not by leaving a marker file: a marker can outlive
# the thing it marks, and re-running must be cheap rather than merely harmless.
if dpkg-query -W -f='${Status}' lazysite-common 2>/dev/null | grep -q 'ok installed'; then
    say "lazysite: engine already installed"
else
    DEB=$(ls "$SKILL_DIR"/lazysite-common_*.deb 2>/dev/null | head -1)
    [ -n "$DEB" ] || fail "no lazysite-common .deb in $SKILL_DIR - this skill is incomplete; re-download it from the release"
    say "lazysite: installing $(basename "$DEB")"
    # apt-get, not dpkg -i: the engine needs libtemplate-perl and
    # libtext-multimarkdown-perl from the archive, and dpkg does not fetch.
    # Recommends are the production FastCGI runtime and are not wanted here.
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || fail "apt-get update failed - is archive.ubuntu.com reachable from this container?"
    apt-get install -y -qq --no-install-recommends "$DEB" \
        || fail "apt-get install failed - see the output above"
fi

VERSION=$(dpkg-query -W -f='${Version}' lazysite-common 2>/dev/null || echo unknown)
say "lazysite: engine $VERSION"

command -v lazysite >/dev/null 2>&1 || fail "the lazysite command is not on PATH after install"

# --- 2. a site to render into -------------------------------------------------
#
# A copy of the shipped starter, which is what an editor's site was made from.
# A smaller purpose-built validation site was considered and refused: it would
# be a second thing to maintain, and it would drift from the starter people
# actually have.
if [ -f "$SITE/index.md" ]; then
    say "lazysite: reusing the local site at $SITE"
else
    mkdir -p "$LAZYSITE_HOME"
    cp -a /usr/share/lazysite/starter "$SITE" || fail "could not copy the starter site"
    say "lazysite: local site at $SITE"
fi

# --- 3. prove it renders ------------------------------------------------------
#
# ONE PASS/FAIL LINE, and it is earned: the server is started, a page is
# fetched, and the answer is inspected. "Installed successfully" without a
# render is the claim this whole skill exists to stop making.
# `sh serve.sh`, never `./serve.sh`: a zip does not reliably carry the execute
# bit and the skill mount is read-only, so chmod is not available as a repair.
# The cold run failed here first with "Permission denied", which reads as a
# sandbox problem rather than a missing file mode.
if ! sh "$SKILL_DIR/serve.sh" start >"$LAZYSITE_HOME/serve-start.out" 2>&1; then
    # SHOW WHY. A setup script that swallows the reason and says "did not
    # start" is the failure mode this whole skill exists to argue against.
    sed 's/^/  /' "$LAZYSITE_HOME/serve-start.out" 2>/dev/null || true
    fail "the dev server did not start"
fi

PORT=${LAZYSITE_PORT:-8080}
# fetch.pl rather than curl - see the note in fetch.pl. The base image has none.
INSTANCE=$(perl "$SKILL_DIR/fetch.pl" "http://127.0.0.1:$PORT/.well-known/lazysite-instance.json" 2>/dev/null || true)
HOME_BYTES=$(perl "$SKILL_DIR/fetch.pl" "http://127.0.0.1:$PORT/" 2>/dev/null | wc -c)

if [ -n "$INSTANCE" ] && [ "$HOME_BYTES" -gt 200 ]; then
    say ""
    say "PASS: lazysite $VERSION is serving $SITE on http://127.0.0.1:$PORT/"
    say "  validate:  lazysite validate --docroot \"$SITE\" PAGE.md"
    say "  render:    perl $SKILL_DIR/fetch.pl http://127.0.0.1:$PORT/PAGE"
    say "  site tree: $SITE"
else
    say "  instance endpoint: ${INSTANCE:-(no answer)}"
    say "  homepage bytes:    ${HOME_BYTES:-0}"
    fail "the engine installed but the site did not serve - see $LAZYSITE_HOME/server.log"
fi
