#!/bin/bash
# lazysite-hestia-deploy USER DOMAIN [STAGE_DIR]
#
# One-command lazysite install/upgrade for a HestiaCP domain. RUN AS ROOT.
# It folds the whole INSTALL-RUNBOOK into a single invocation:
#   1. on FIRST-TIME setup only, apply the lazysite-app web template (its
#      rebuild hook, as root, creates the plugins/ and tools/ children of the
#      0551-locked domain root and sets the base www-data docroot perms). An
#      upgrade leaves the Hestia web template untouched - it only refreshes
#      code/content/perms - so a deliberately-changed template is preserved.
#      Force a re-apply with LAZYSITE_APPLY_TEMPLATE=1.
#   2. run install.pl as the domain user to deploy/upgrade the code;
#   3. set the directory layout + permissions a www-data CGI needs (the
#      reason a plain `install.pl` as the domain user can't do it alone -
#      it can't write the locked domain root or chgrp to www-data);
#   4. drop the Hestia placeholder index.html so index.md renders.
#
# STAGE_DIR is the unpacked release (defaults to this script's dir, so it
# works straight from inside an extracted tarball: installers/hestia/..).
set -e

U="$1"; DOMAIN="$2"
STAGE="${3:-$(cd "$(dirname "$0")/../.." && pwd)}"
[ -n "$U" ] && [ -n "$DOMAIN" ] || { echo "usage: $0 USER DOMAIN [STAGE_DIR]" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "$0: must run as root (it sets ownership/perms)" >&2; exit 1; }
[ -f "$STAGE/install.sh" ] || { echo "$0: no install.sh under STAGE '$STAGE'" >&2; exit 2; }

HESTIA=/usr/local/hestia
DOM="/home/$U/web/$DOMAIN"
DOC="$DOM/public_html"
CGI="$DOM/cgi-bin"
[ -d "$DOC" ] || { echo "$0: no docroot at $DOC" >&2; exit 1; }

# Apply the web template on FIRST-TIME setup only. An upgrade (the site already
# has a lazysite install marker) must NOT touch the Hestia web template - that
# would change Hestia state, force a vhost rebuild, and re-assert lazysite-app on
# a domain whose template was deliberately changed (e.g. reverted to keep an
# original static/SSI/PHP site working). Set LAZYSITE_APPLY_TEMPLATE=1 to force.
STATE_FILE="$DOC/lazysite/.install-state.json"
if [ -n "${LAZYSITE_APPLY_TEMPLATE:-}" ] || [ ! -f "$STATE_FILE" ]; then
  echo "==> applying lazysite-app web template (first-time setup)"
  "$HESTIA/bin/v-change-web-domain-tpl" "$U" "$DOMAIN" lazysite-app yes
else
  echo "==> existing lazysite install - leaving the Hestia web template unchanged"
  echo "    (set LAZYSITE_APPLY_TEMPLATE=1 to re-apply lazysite-app + rebuild the vhost)"
fi

# A previous install.pl run directly as root can leave the install targets owned by
# root, which the user-run install.pl below then cannot overwrite ("Permission
# denied", failed upgrade). This script runs as root, so make the domain user own
# everything install.pl writes BEFORE running it: the docroot, the cgi-bin, and the
# sibling lib/ plugins/ tools/ trees (DOCROOT/../{lib,plugins,tools}).
echo "==> normalising ownership to $U:www-data (so the user-run install can write)"
for tgt in "$DOC" "$CGI" "$DOM/lib" "$DOM/plugins" "$DOM/tools"; do
  [ -e "$tgt" ] && chown -R "$U":www-data "$tgt" 2>/dev/null || true
done

echo "==> install.pl (as $U)"
set +e
sudo -u "$U" bash "$STAGE/install.sh" --docroot "$DOC" --cgibin "$CGI"
IRC=$?
set -e
# Exit 3 = the install was skipped by the site's update-channel policy (this site
# is 'stable' and the build is 'edge'). That is a deliberate no-op, not a failure:
# report it and stop here (no files changed, so the verify below would wrongly
# flag a mismatch against the new manifest).
if [ "$IRC" = 3 ]; then
  echo "==> upgrade SKIPPED: this site is on the 'stable' update channel and this"
  echo "    release is an 'edge' build. Nothing changed (logged in the site audit)."
  exit 4          # distinct code so the batch updater can report skips separately
elif [ "$IRC" != 0 ]; then
  echo "ERROR: install failed (exit $IRC)" >&2
  exit "$IRC"
fi

# Verify the installed code actually matches the release before trusting the
# stamped version: catches a partial/stale deploy (the "version reports X but the
# running code is Y" gap) instead of letting it pass silently.
echo "==> verifying installed code matches the release manifest"
if ! sudo -u "$U" bash "$STAGE/install.sh" --verify --docroot "$DOC" --cgibin "$CGI"; then
  echo "ERROR: post-deploy verification FAILED - installed code does not match the" >&2
  echo "       release, so the reported version would not reflect the running code." >&2
  echo "       Check permissions / a stale cgi-bin copy, then re-run the deploy." >&2
  exit 1
fi

echo "==> permissions (CGI runs as www-data)"
# The compiled-template cache (lazysite/cache/tt) is regenerated on demand and
# mirrors absolute paths in deeply-nested directories; on a long-running site it
# is by far the slowest part of the sweep below. Drop it first so the permission
# pass stays fast (the next render rebuilds it with the right ownership).
rm -rf "$DOC/lazysite/cache/tt" 2>/dev/null || true
# -RP: recurse without following symlinks (the cgi-bin links live outside $DOC,
# but be explicit). Batched -exec (chmod once per many paths, not once per file)
# - a per-file sweep over a large docroot takes many minutes and looks like a hang.
chown -RP "$U":www-data "$DOC"
find "$DOC" -type d -exec chmod 2775 {} +
find "$DOC" -type f -exec chmod 664  {} +
echo "    permissions set"
[ -d "$DOC/lazysite/auth" ]  && chmod 2770 "$DOC/lazysite/auth"
[ -d "$DOC/lazysite/forms" ] && chmod 2770 "$DOC/lazysite/forms"
# Secrets must not be world-readable (the blanket 664 above would expose them);
# 660 keeps them readable by the www-data group only.
for sec in auth/.secret forms/.secret manager/.csrf-secret \
           auth/oauth.json auth/user-settings.json; do
  [ -f "$DOC/lazysite/$sec" ] && chmod 660 "$DOC/lazysite/$sec"
done

# Optional: reload nginx after an upgrade. nginx serves the static manager assets
# (manager.css, cm/*) directly and, IF open_file_cache is enabled, can briefly
# serve a stale size for a just-rewritten file until the cache entry expires
# (open_file_cache_valid, default 60s). open_file_cache is off by default in
# nginx and self-heals when on, so this is opt-in, not the norm - the ?v=<version>
# cache-buster on the asset URLs already handles the browser side. Enable with
# LAZYSITE_RELOAD_NGINX=1 only if your nginx has open_file_cache on and you don't
# want to wait out its validity window.
if [ -n "${LAZYSITE_RELOAD_NGINX:-}" ] && command -v systemctl >/dev/null 2>&1; then
  echo "==> reloading nginx (LAZYSITE_RELOAD_NGINX set)"
  systemctl reload nginx 2>/dev/null \
    || systemctl reload-or-restart nginx 2>/dev/null \
    || echo "  (could not reload nginx automatically - run: systemctl reload nginx)"
fi

# index.html is handled by the template hook (install-hestia.sh): it clears only
# an index.html that was rendered from a PRE-EXISTING index.md - never real
# content - so lazysite can overlay an existing static site safely. We do NOT
# delete index.html here.
echo
echo "Deployed lazysite to $DOMAIN."
if [ -f "$DOC/index.html" ] && [ -f "$DOC/index.md" ]; then
  echo "Note: the homepage ('/') must route through the processor so the manager"
  echo "bar shows on it. The current lazysite web template does this (index.html"
  echo "is no longer a DirectoryIndex). If '/' shows no manager bar while other"
  echo "pages do, this vhost is on an OLDER template - re-apply it:"
  echo "    v-rebuild-web-domain $U $DOMAIN"
fi
if ! grep -q '^manager_groups:' "$DOC/lazysite/lazysite.conf" 2>/dev/null; then
  # First-run: bootstrap the manager in one step (account + admin group +
  # lazysite.conf + a generated password, printed below). Runs as the domain
  # user so the auth store and conf are written with the right ownership.
  echo "==> first-run manager setup"
  sudo -u "$U" perl "$DOM/tools/lazysite-users.pl" --docroot "$DOC" setup-manager
fi

echo "==> verifying install (permissions + health, auto-repair)"
# Run as root with --fix so it can repair both modes and ownership if anything is
# still off (the user asked: when run as root, the deploy should work the ownership
# out itself).
perl "$DOM/tools/lazysite-check.pl" --docroot "$DOC" --cgibin "$CGI" --fix || \
  echo "  (some checks could not be auto-repaired - see above)"
