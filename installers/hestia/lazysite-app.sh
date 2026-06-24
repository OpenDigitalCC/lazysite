#!/bin/bash
# lazysite-app.sh - HestiaCP rebuild hook for the lazysite-app template.
#
# Runs as root on every rebuild. Prepares the directory layout and
# permissions that the manifest-driven installer (install.pl) needs. It
# does NOT deploy code - run install.pl for that. See INSTALL-RUNBOOK.md.
#
# Hestia args: USER DOMAIN IP HOME DOCROOT
user="$1"; domain="$2"; ip="$3"; home="$4"; docroot="$5"
domdir="$(dirname "$docroot")"

# install.pl writes plugins/, tools/ and lib/ as siblings of public_html, but
# the Hestia domain root is mode 0551 (the user can't create files there).
# Create them as root, owned by the user so install.pl can populate them.
# (lib/ holds the shared Lazysite::* modules added in 0.4.0 / SM079 - it must
# be pre-created here for the same reason as plugins/ and tools/.)
mkdir -p "$domdir/plugins" "$domdir/tools" "$domdir/lib"
chown "$user":"$user" "$domdir/plugins" "$domdir/tools" "$domdir/lib"

# The processor runs as the web-server user (www-data when SuexecUserGroup
# is off, as in this template) and writes rendered .html across the docroot
# plus cache/logs/locks under lazysite/. Give the docroot tree to the
# www-data group, setgid so new files/dirs inherit it.
chown "$user":www-data "$docroot"
chmod 2775 "$docroot"
find "$docroot" -type d -exec chown "$user":www-data {} \; -exec chmod 2775 {} \;

# Secrets dirs: group-writable (so the CGI user can mint .secret and the
# rate-limit DBs - login depends on this) but off the world. On a fresh
# domain these don't exist until install.pl runs; this also re-asserts the
# perms on later rebuilds (e.g. after the users tool touched auth/).
[ -d "$docroot/lazysite/auth" ]  && chmod 2770 "$docroot/lazysite/auth"
[ -d "$docroot/lazysite/forms" ] && chmod 2770 "$docroot/lazysite/forms"

exit 0
