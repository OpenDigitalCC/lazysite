#!/bin/bash
# lazysite HestiaCP domain hook
# Installs lazysite-processor.pl and starter files when lazysite template is applied
# https://github.com/OpenDigitalCC/lazysite

user="$1"
domain="$2"
ip="$3"
home_dir="$4"
docroot="$5"

TEMPLATE_DIR="$(dirname "$0")/files"
CGIBIN="$home_dir/$user/web/$domain/cgi-bin"
LAZYSITE_DIR="$docroot/lazysite"

# Install processor
install -m 755 -o "$user" -g "$user" \
    "$TEMPLATE_DIR/lazysite-processor.pl" \
    "$CGIBIN/lazysite-processor.pl"

# Install additional scripts
for script in lazysite-form-handler.pl lazysite-form-smtp.pl \
              lazysite-auth.pl lazysite-manager-api.pl \
              lazysite-payment-demo.pl; do
    if [ -f "$TEMPLATE_DIR/$script" ]; then
        install -m 755 -o "$user" -g "$user" \
            "$TEMPLATE_DIR/$script" "$CGIBIN/$script"
    fi
done

# Install logging plugin at docroot parent (matches manager-api @CANDIDATES)
if [ -f "$TEMPLATE_DIR/lazysite-log.pl" ]; then
    install -m 755 -o "$user" -g "$user" \
        "$TEMPLATE_DIR/lazysite-log.pl" \
        "$docroot/../lazysite-log.pl"
fi

# Install tools used by manager-api and audit plugin
mkdir -p "$docroot/../tools"
chown "$user":"$user" "$docroot/../tools"
for tool in lazysite-users.pl lazysite-audit.pl; do
    if [ -f "$TEMPLATE_DIR/tools/$tool" ]; then
        install -m 755 -o "$user" -g "$user" \
            "$TEMPLATE_DIR/tools/$tool" \
            "$docroot/../tools/$tool"
    fi
done

# Create lazysite directory structure (D013)
mkdir -p "$LAZYSITE_DIR/templates/registries"
mkdir -p "$LAZYSITE_DIR/manager/assets"
mkdir -p "$LAZYSITE_DIR/layouts"
mkdir -p "$docroot/lazysite-assets"
mkdir -p "$LAZYSITE_DIR/forms"
mkdir -p "$LAZYSITE_DIR/logs"
mkdir -p "$LAZYSITE_DIR/cache"
mkdir -p "$LAZYSITE_DIR/manager/locks"
mkdir -p "$LAZYSITE_DIR/auth"
chmod 750 "$LAZYSITE_DIR/auth"
chown -R "$user":"$user" "$LAZYSITE_DIR"
chown "$user":"$user" "$docroot/lazysite-assets"

# SM084: one-time pre-install snapshot of the original docroot, so installing
# lazysite over an existing HTML/SSI site is always recoverable. Excludes the
# lazysite/ infra; skipped if a snapshot already exists or there is no content
# yet. Surfaced + downloadable in the manager (Backups).
BACKUP_DIR="$LAZYSITE_DIR/backups"
mkdir -p "$BACKUP_DIR"
if ! ls "$BACKUP_DIR"/preinstall-*.tar.gz >/dev/null 2>&1; then
    if find "$docroot" -mindepth 1 -maxdepth 1 \
            ! -name lazysite ! -name lazysite-assets -print -quit | grep -q .; then
        stamp="$(date -u +%Y%m%dT%H%M%SZ)"
        tar czf "$BACKUP_DIR/preinstall-$stamp.tar.gz" -C "$docroot" \
            --exclude=./lazysite --exclude=./lazysite-assets . 2>/dev/null || true
    fi
fi
chown -R "$user":"$user" "$BACKUP_DIR" 2>/dev/null || true

# Install manager layout and CSS (D013: manager moved out of themes/)
if [ -f "$TEMPLATE_DIR/starter/lazysite/manager/layout.tt" ]; then
    install -m 644 -o "$user" -g "$user" \
        "$TEMPLATE_DIR/starter/lazysite/manager/layout.tt" \
        "$LAZYSITE_DIR/manager/layout.tt"
fi
if [ -f "$TEMPLATE_DIR/starter/lazysite/manager/assets/manager.css" ]; then
    install -m 644 -o "$user" -g "$user" \
        "$TEMPLATE_DIR/starter/lazysite/manager/assets/manager.css" \
        "$LAZYSITE_DIR/manager/assets/manager.css"
    mkdir -p "$docroot/manager/assets"
    chown "$user":"$user" "$docroot/manager" "$docroot/manager/assets"
    install -m 644 -o "$user" -g "$user" \
        "$TEMPLATE_DIR/starter/lazysite/manager/assets/manager.css" \
        "$docroot/manager/assets/manager.css"
fi

# D013: no default layout ships with lazysite. The processor falls
# back to the embedded template when lazysite/layouts/NAME/layout.tt
# is missing, so operators install a layout from the layouts repo
# (manager UI at /manager/themes -> Install from Releases).

# Install lazysite.conf only if not already present
if [ ! -f "$LAZYSITE_DIR/lazysite.conf" ]; then
    install -m 644 -o "$user" -g "$user" \
        "$TEMPLATE_DIR/lazysite.conf" \
        "$LAZYSITE_DIR/lazysite.conf"
fi

# Install registry templates if not already present
for tmpl in "$TEMPLATE_DIR/registries/"*.tt; do
    [ -f "$tmpl" ] || continue
    dest="$LAZYSITE_DIR/templates/registries/$(basename "$tmpl")"
    if [ ! -f "$dest" ]; then
        install -m 644 -o "$user" -g "$user" "$tmpl" "$dest"
    fi
done

# Install starter 404.md only if not already present
if [ ! -f "$docroot/404.md" ]; then
    install -m 644 -o "$user" -g "$user" \
        "$TEMPLATE_DIR/404.md" \
        "$docroot/404.md"
fi

# Did a real index.md already exist before we (maybe) seed one? This decides
# whether a sibling index.html is a regenerable lazysite cache or untouchable
# content (see the index.html handling below).
index_md_preexisted=0
[ -f "$docroot/index.md" ] && index_md_preexisted=1

# Install starter index.md only if not already present
if [ ! -f "$docroot/index.md" ]; then
    install -m 644 -o "$user" -g "$user" \
        "$TEMPLATE_DIR/index.md" \
        "$docroot/index.md"
fi

# Clear a shadowing index.html ONLY when index.md already existed - i.e. the
# index.html was rendered FROM that index.md and lazysite will regenerate it.
# If index.md was just seeded now, or absent, any existing index.html is real
# content (a static site being overlaid, or the Hestia stub) and is left ALONE,
# so lazysite can be installed over an existing HTML/SSI site without losing the
# homepage. (DirectoryIndex serves index.html first, so a migrated page replaces
# its .html deliberately, never via the installer.)
if [ "$index_md_preexisted" = 1 ] && [ -f "$docroot/index.html" ]; then
    rm -f "$docroot/index.html"
fi

# Ensure www-data can write generated .html files to docroot
# setgid bit ensures new subdirectories inherit the group automatically
chown "$user":www-data "$docroot"
chmod g+ws "$docroot"

# Fix any existing subdirectories
find "$docroot" -type d \
    -exec chown "$user":www-data {} \; \
    -exec chmod g+ws {} \;

exit 0
