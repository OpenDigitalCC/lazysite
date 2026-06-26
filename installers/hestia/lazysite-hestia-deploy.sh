#!/bin/bash
# lazysite-hestia-deploy USER DOMAIN [STAGE_DIR]
#
# One-command lazysite install/upgrade for a HestiaCP domain. RUN AS ROOT.
# It folds the whole INSTALL-RUNBOOK into a single invocation:
#   1. apply the lazysite-app web template (its rebuild hook, as root,
#      creates the plugins/ and tools/ children of the 0551-locked domain
#      root and sets the base www-data docroot perms);
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

echo "==> applying lazysite-app web template"
"$HESTIA/bin/v-change-web-domain-tpl" "$U" "$DOMAIN" lazysite-app yes

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
sudo -u "$U" bash "$STAGE/install.sh" --docroot "$DOC" --cgibin "$CGI"

echo "==> permissions (CGI runs as www-data)"
chown -R "$U":www-data "$DOC"
find "$DOC" -type d -exec chmod 2775 {} \;
find "$DOC" -type f -exec chmod 664  {} \;
[ -d "$DOC/lazysite/auth" ]  && chmod 2770 "$DOC/lazysite/auth"
[ -d "$DOC/lazysite/forms" ] && chmod 2770 "$DOC/lazysite/forms"
# Secrets must not be world-readable (the blanket 664 above would expose them);
# 660 keeps them readable by the www-data group only.
for sec in auth/.secret forms/.secret manager/.csrf-secret \
           auth/oauth.json auth/user-settings.json; do
  [ -f "$DOC/lazysite/$sec" ] && chmod 660 "$DOC/lazysite/$sec"
done

# index.html is handled by the template hook (install-hestia.sh): it clears only
# an index.html that was rendered from a PRE-EXISTING index.md - never real
# content - so lazysite can overlay an existing static site safely. We do NOT
# delete index.html here.
echo
echo "Deployed lazysite to $DOMAIN."
if [ -f "$DOC/index.html" ] && [ -f "$DOC/index.md" ]; then
  echo "Note: an index.html is present alongside index.md and will be served"
  echo "first (DirectoryIndex). If the homepage shows a placeholder, and that"
  echo "index.html is NOT your content, remove it:  rm -f $DOC/index.html"
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
