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

echo "Installing lazysite scripts..."
install -m 755 "$SCRIPT_DIR/lazysite-processor.pl" "$CGIBIN/lazysite-processor.pl"
for script in lazysite-form-handler.pl lazysite-form-smtp.pl lazysite-auth.pl lazysite-editor-api.pl; do
    if [ -f "$SCRIPT_DIR/$script" ]; then
        install -m 755 "$SCRIPT_DIR/$script" "$CGIBIN/$script"
    fi
done

# --- Create lazysite directory structure ---

echo "Creating lazysite directory structure..."
mkdir -p "$DOCROOT/lazysite/templates/registries"
mkdir -p "$DOCROOT/lazysite/themes"

# --- Copy starter files ---

echo "Installing starter files..."

# Install starter content only if not already present
for file in index.md lazysite-demo.md 404.md search-results.md search-index.md; do
    if [ ! -f "$DOCROOT/$file" ]; then
        install -m 644 "$SCRIPT_DIR/starter/$file" "$DOCROOT/$file"
    fi
done

# Install docs if not already present
if [ -d "$SCRIPT_DIR/starter/docs" ]; then
    mkdir -p "$DOCROOT/docs"
    for doc in "$SCRIPT_DIR/starter/docs/"*.md; do
        [ -f "$doc" ] || continue
        dest="$DOCROOT/docs/$(basename "$doc")"
        if [ ! -f "$dest" ]; then
            install -m 644 "$doc" "$dest"
        fi
    done
fi

# Install editor pages and assets
if [ -d "$SCRIPT_DIR/starter/editor" ]; then
    mkdir -p "$DOCROOT/editor/assets/cm"
    for page in "$SCRIPT_DIR/starter/editor/"*.md; do
        [ -f "$page" ] || continue
        dest="$DOCROOT/editor/$(basename "$page")"
        if [ ! -f "$dest" ]; then
            install -m 644 "$page" "$dest"
        fi
    done
    if [ -d "$SCRIPT_DIR/starter/editor/assets/cm" ]; then
        cp -r "$SCRIPT_DIR/starter/editor/assets/cm/"* \
            "$DOCROOT/editor/assets/cm/" 2>/dev/null
    fi
fi

# Install registry templates
for tmpl in "$SCRIPT_DIR/starter/registries/"*.tt; do
    [ -f "$tmpl" ] || continue
    dest="$DOCROOT/lazysite/templates/registries/$(basename "$tmpl")"
    if [ ! -f "$dest" ]; then
        install -m 644 "$tmpl" "$dest"
    fi
done

# --- Fetch default view from lazysite-views ---

echo "Fetching default view from lazysite-views..."
if command -v git &>/dev/null; then
    VIEWS_TMP=$(mktemp -d)
    git clone --depth 1 \
        https://github.com/OpenDigitalCC/lazysite-views.git \
        "$VIEWS_TMP" 2>/dev/null
    if [ -f "$VIEWS_TMP/default/view.tt" ]; then
        mkdir -p "$DOCROOT/lazysite/templates"
        cp "$VIEWS_TMP/default/view.tt" \
            "$DOCROOT/lazysite/templates/view.tt"
        echo "  view.tt installed from lazysite-views/default"
    fi
    if [ -f "$VIEWS_TMP/default/nav.conf" ]; then
        cp "$VIEWS_TMP/default/nav.conf" \
            "$DOCROOT/lazysite/nav.conf"
        echo "  nav.conf installed from lazysite-views/default"
    fi
    if [ -d "$VIEWS_TMP/default/assets" ]; then
        mkdir -p "$DOCROOT/lazysite-assets/default"
        cp -r "$VIEWS_TMP/default/assets/"* \
            "$DOCROOT/lazysite-assets/default/" 2>/dev/null
        echo "  assets installed to lazysite-assets/default/"
    fi
    rm -rf "$VIEWS_TMP"
else
    echo "  git not found - skipping view install"
    echo "  Install manually: https://github.com/OpenDigitalCC/lazysite-views"
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
        install -m 644 "$SCRIPT_DIR/starter/lazysite.conf.example" "$CONF_FILE"
    fi
fi

# --- Set permissions ---

echo "Setting permissions..."
chmod +x "$CGIBIN/"lazysite-*.pl
chmod g+ws "$DOCROOT"

# --- Check optional dependencies ---

OPT_MISSING=""
if ! perl -e 'require Template::Plugin::JSON::Escape' 2>/dev/null; then
    OPT_MISSING="libtemplate-plugin-json-escape-perl"
fi

echo ""
echo "lazysite installed successfully."

if [ -n "$OPT_MISSING" ]; then
    echo ""
    echo "Optional dependencies (required for search):"
    echo "  sudo apt-get install $OPT_MISSING"
fi

echo ""
echo "Next steps:"
echo "  1. Edit $DOCROOT/lazysite/templates/view.tt to apply your site design"
echo "  2. Edit $DOCROOT/lazysite/lazysite.conf to configure your site"
echo "  3. Replace $DOCROOT/index.md with your content"
echo ""
