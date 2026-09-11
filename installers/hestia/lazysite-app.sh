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

# SM850: where the site's engine tree is - <docroot>-lazysite once it has been
# moved out of the document root (SM293), <docroot>/lazysite before. The rule
# Lazysite::Paths::lazysite_dir states; t/lint/37 runs this copy against it.
# This hook is copied into Hestia's template directory on its own, so it
# carries the rule rather than sourcing it.
lazysite_dir() {
    local d="$1"
    while [ "${d%/}" != "$d" ]; do d="${d%/}"; done
    if [ -d "$d-lazysite" ]; then printf '%s\n' "$d-lazysite"; else printf '%s\n' "$d/lazysite"; fi
}

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
lz="$(lazysite_dir "$docroot")"
[ -d "$lz/auth" ]  && chmod 2770 "$lz/auth"
[ -d "$lz/forms" ] && chmod 2770 "$lz/forms"

exit 0
