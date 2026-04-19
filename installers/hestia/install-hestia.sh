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

# Create lazysite directory structure
mkdir -p "$LAZYSITE_DIR/templates/registries"
mkdir -p "$LAZYSITE_DIR/themes/manager/assets"
mkdir -p "$LAZYSITE_DIR/forms"
mkdir -p "$LAZYSITE_DIR/logs"
mkdir -p "$LAZYSITE_DIR/cache"
mkdir -p "$LAZYSITE_DIR/manager/locks"
mkdir -p "$LAZYSITE_DIR/auth"
chmod 750 "$LAZYSITE_DIR/auth"
chown -R "$user":"$user" "$LAZYSITE_DIR"

# Install manager view and CSS
if [ -f "$TEMPLATE_DIR/starter/lazysite/themes/manager/view.tt" ]; then
    install -m 644 -o "$user" -g "$user" \
        "$TEMPLATE_DIR/starter/lazysite/themes/manager/view.tt" \
        "$LAZYSITE_DIR/themes/manager/view.tt"
fi
if [ -f "$TEMPLATE_DIR/starter/lazysite/themes/manager/assets/manager.css" ]; then
    install -m 644 -o "$user" -g "$user" \
        "$TEMPLATE_DIR/starter/lazysite/themes/manager/assets/manager.css" \
        "$LAZYSITE_DIR/themes/manager/assets/manager.css"
    mkdir -p "$docroot/manager/assets"
    chown "$user":"$user" "$docroot/manager" "$docroot/manager/assets"
    install -m 644 -o "$user" -g "$user" \
        "$TEMPLATE_DIR/starter/lazysite/themes/manager/assets/manager.css" \
        "$docroot/manager/assets/manager.css"
fi

# Install view.tt only if not already present
if [ ! -f "$LAZYSITE_DIR/templates/view.tt" ]; then
    install -m 644 -o "$user" -g "$user" \
        "$TEMPLATE_DIR/view.tt" \
        "$LAZYSITE_DIR/templates/view.tt"
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
