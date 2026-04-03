#!/bin/bash
# lazysite installer
# https://github.com/OpenDigitalCC/lazysite

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    cat <<EOF
Usage: install.sh --docroot PATH --cgibin PATH [options]

Required:
  --docroot PATH    Path to web document root
  --cgibin  PATH    Path to cgi-bin directory

Optional:
  --theme   URL     Template URL (default: OpenDigital default)
  --domain  NAME    Domain name for lazysite.conf site_url
  --help            Show this help

Example:
  install.sh --docroot /var/www/html --cgibin /usr/lib/cgi-bin --domain example.com
EOF
}

# No args - show help
[ $# -eq 0 ] && usage && exit 0

# --- Parse arguments ---

DOCROOT=""
CGIBIN=""
THEME=""
DOMAIN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --docroot) DOCROOT="$2"; shift 2 ;;
        --cgibin)  CGIBIN="$2";  shift 2 ;;
        --theme)   THEME="$2";   shift 2 ;;
        --domain)  DOMAIN="$2";  shift 2 ;;
        --help)    usage; exit 0 ;;
        *)         echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

if [ -z "$DOCROOT" ]; then
    echo "Error: --docroot is required" >&2
    exit 1
fi

if [ -z "$CGIBIN" ]; then
    echo "Error: --cgibin is required" >&2
    exit 1
fi

# --- Install processor ---

echo "Installing lazysite processor..."
install -m 755 "$SCRIPT_DIR/lazysite-processor.pl" "$CGIBIN/lazysite-processor.pl"

# --- Create lazysite directory structure ---

echo "Creating lazysite directory structure..."
mkdir -p "$DOCROOT/lazysite/templates/registries"
mkdir -p "$DOCROOT/lazysite/themes"

# --- Copy starter files ---

echo "Installing starter files..."

# Install starter content only if not already present
for file in index.md lazysite-demo.md 404.md; do
    if [ ! -f "$DOCROOT/$file" ]; then
        install -m 644 "$SCRIPT_DIR/starter/$file" "$DOCROOT/$file"
    fi
done

# Install registry templates
for tmpl in "$SCRIPT_DIR/starter/registries/"*.tt; do
    [ -f "$tmpl" ] || continue
    dest="$DOCROOT/lazysite/templates/registries/$(basename "$tmpl")"
    if [ ! -f "$dest" ]; then
        install -m 644 "$tmpl" "$dest"
    fi
done

# --- Fetch default template ---

TEMPLATE_URL="${THEME:-https://raw.githubusercontent.com/OpenDigitalCC/lazysite-templates/main/default/layout.tt}"

echo "Fetching template..."
if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$TEMPLATE_URL" -o "$DOCROOT/lazysite/templates/layout.tt" 2>/dev/null || {
        echo "Warning: could not fetch template from $TEMPLATE_URL"
        echo "You will need to create $DOCROOT/lazysite/templates/layout.tt manually"
    }
elif command -v wget >/dev/null 2>&1; then
    wget -q "$TEMPLATE_URL" -O "$DOCROOT/lazysite/templates/layout.tt" 2>/dev/null || {
        echo "Warning: could not fetch template from $TEMPLATE_URL"
        echo "You will need to create $DOCROOT/lazysite/templates/layout.tt manually"
    }
else
    echo "Warning: neither curl nor wget found - cannot fetch template"
    echo "You will need to create $DOCROOT/lazysite/templates/layout.tt manually"
fi

# --- Write lazysite.conf ---

CONF_FILE="$DOCROOT/lazysite/lazysite.conf"
if [ ! -f "$CONF_FILE" ]; then
    echo "Writing lazysite.conf..."
    if [ -n "$DOMAIN" ]; then
        cat > "$CONF_FILE" <<CONF
# lazysite.conf - site configuration
# See https://lazysite.io/docs for reference

site_name: $DOMAIN
site_url: \${REQUEST_SCHEME}://$DOMAIN
CONF
    else
        install -m 644 "$SCRIPT_DIR/starter/lazysite.conf" "$CONF_FILE"
    fi
fi

# --- Set permissions ---

echo "Setting permissions..."
chmod +x "$CGIBIN/lazysite-processor.pl"
chmod g+ws "$DOCROOT"

echo ""
echo "lazysite installed successfully."
echo ""
echo "Next steps:"
echo "  1. Edit $DOCROOT/lazysite/templates/layout.tt to apply your site design"
echo "  2. Edit $DOCROOT/lazysite/lazysite.conf to configure your site"
echo "  3. Replace $DOCROOT/index.md with your content"
echo ""
