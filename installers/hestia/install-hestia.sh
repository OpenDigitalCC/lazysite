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

# Create lazysite directory structure
mkdir -p "$LAZYSITE_DIR/templates/registries"
mkdir -p "$LAZYSITE_DIR/themes"
chown -R "$user":"$user" "$LAZYSITE_DIR"

# Install layout.tt only if not already present
if [ ! -f "$LAZYSITE_DIR/templates/layout.tt" ]; then
    install -m 644 -o "$user" -g "$user" \
        "$TEMPLATE_DIR/layout.tt" \
        "$LAZYSITE_DIR/templates/layout.tt"
fi

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

# Install starter index.md only if not already present
if [ ! -f "$docroot/index.md" ]; then
    install -m 644 -o "$user" -g "$user" \
        "$TEMPLATE_DIR/index.md" \
        "$docroot/index.md"
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
