#!/bin/bash
# lazydev domain hook
# Installs md-processor.pl and starter files when ssi-md template is applied
# https://github.com/OpenDigitalCC/lazydev

user="$1"
domain="$2"
ip="$3"
home_dir="$4"
docroot="$5"

TEMPLATE_DIR="$(dirname "$0")/files"
CGIBIN="$home_dir/$user/web/$domain/cgi-bin"
TEMPLATES_DIR="$docroot/templates"

# Install processor
install -m 755 -o "$user" -g "$user" \
    "$TEMPLATE_DIR/md-processor.pl" \
    "$CGIBIN/md-processor.pl"

# Create templates directory
mkdir -p "$TEMPLATES_DIR"
chown "$user":"$user" "$TEMPLATES_DIR"

# Install layout.tt only if not already present
if [ ! -f "$TEMPLATES_DIR/layout.tt" ]; then
    install -m 644 -o "$user" -g "$user" \
        "$TEMPLATE_DIR/layout.tt" \
        "$TEMPLATES_DIR/layout.tt"
fi

# Install layout.vars only if not already present
if [ ! -f "$TEMPLATES_DIR/layout.vars" ]; then
    install -m 644 -o "$user" -g "$user" \
        "$TEMPLATE_DIR/layout.vars" \
        "$TEMPLATES_DIR/layout.vars"
fi

# Install registries directory and starter templates if not already present
mkdir -p "$TEMPLATES_DIR/registries"
chown "$user":"$user" "$TEMPLATES_DIR/registries"
for tmpl in "$TEMPLATE_DIR/registries/"*.tt; do
    [ -f "$tmpl" ] || continue
    dest="$TEMPLATES_DIR/registries/$(basename "$tmpl")"
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
