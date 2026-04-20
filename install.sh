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
for script in lazysite-form-handler.pl lazysite-form-smtp.pl \
              lazysite-auth.pl lazysite-manager-api.pl \
              lazysite-payment-demo.pl; do
    if [ -f "$SCRIPT_DIR/$script" ]; then
        install -m 755 "$SCRIPT_DIR/$script" "$CGIBIN/$script"
    fi
done

# Install logging plugin at docroot parent (matches manager-api @CANDIDATES)
if [ -f "$SCRIPT_DIR/lazysite-log.pl" ]; then
    install -m 755 "$SCRIPT_DIR/lazysite-log.pl" "$DOCROOT/../lazysite-log.pl"
    echo "  Installed: lazysite-log.pl"
fi

# Install tools used by manager-api and audit plugin
mkdir -p "$DOCROOT/../tools"
if [ -f "$SCRIPT_DIR/tools/lazysite-users.pl" ]; then
    install -m 755 "$SCRIPT_DIR/tools/lazysite-users.pl" \
        "$DOCROOT/../tools/lazysite-users.pl"
    echo "  Installed: tools/lazysite-users.pl"
fi
if [ -f "$SCRIPT_DIR/tools/lazysite-audit.pl" ]; then
    install -m 755 "$SCRIPT_DIR/tools/lazysite-audit.pl" \
        "$DOCROOT/../tools/lazysite-audit.pl"
    echo "  Installed: tools/lazysite-audit.pl"
fi

# --- Create lazysite directory structure ---

echo "Creating lazysite directory structure..."
mkdir -p "$DOCROOT/lazysite/templates/registries"
mkdir -p "$DOCROOT/lazysite/themes"

# Install manager view (ships with repo)
if [ -d "$SCRIPT_DIR/starter/lazysite/themes/manager" ]; then
    mkdir -p "$DOCROOT/lazysite/themes/manager/assets"
    cp "$SCRIPT_DIR/starter/lazysite/themes/manager/view.tt" \
        "$DOCROOT/lazysite/themes/manager/"
    if [ -f "$SCRIPT_DIR/starter/lazysite/themes/manager/assets/manager.css" ]; then
        cp "$SCRIPT_DIR/starter/lazysite/themes/manager/assets/manager.css" \
            "$DOCROOT/lazysite/themes/manager/assets/"
    fi
    echo "  Installed: manager view"
fi
mkdir -p "$DOCROOT/lazysite/forms"
mkdir -p "$DOCROOT/lazysite/logs"
mkdir -p "$DOCROOT/lazysite/cache"
mkdir -p "$DOCROOT/lazysite/manager/locks"
mkdir -p "$DOCROOT/lazysite/auth"
chmod 750 "$DOCROOT/lazysite/auth"

# Seed forms config from examples
for conf in contact handlers smtp; do
    src="$SCRIPT_DIR/starter/lazysite/forms/$conf.conf.example"
    dst="$DOCROOT/lazysite/forms/$conf.conf"
    if [ -f "$src" ] && [ ! -f "$dst" ]; then
        cp "$src" "$dst"
        echo "  Created: lazysite/forms/$conf.conf"
    fi
done

# --- Copy starter files ---

echo "Installing starter files..."

# Install starter content only if not already present
for file in index.md lazysite-demo.md 402.md 403.md 404.md \
            login.md logout.md members.md \
            payment-demo.md payment-members-demo.md \
            search-results.md search-index.md; do
    if [ -f "$SCRIPT_DIR/starter/$file" ] && [ ! -f "$DOCROOT/$file" ]; then
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

# Install manager pages and assets
if [ -d "$SCRIPT_DIR/starter/manager" ]; then
    mkdir -p "$DOCROOT/manager/assets/cm"
    for page in "$SCRIPT_DIR/starter/manager/"*.md; do
        [ -f "$page" ] || continue
        dest="$DOCROOT/manager/$(basename "$page")"
        if [ ! -f "$dest" ]; then
            install -m 644 "$page" "$dest"
        fi
    done
    if [ -d "$SCRIPT_DIR/starter/manager/assets/cm" ]; then
        cp -r "$SCRIPT_DIR/starter/manager/assets/cm/"* \
            "$DOCROOT/manager/assets/cm/" 2>/dev/null
    fi
    # Copy manager CSS from theme source to web-accessible path
    if [ -f "$DOCROOT/lazysite/themes/manager/assets/manager.css" ]; then
        cp "$DOCROOT/lazysite/themes/manager/assets/manager.css" \
            "$DOCROOT/manager/assets/manager.css"
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
    # Install manager view
    if [ -f "$VIEWS_TMP/manager/view.tt" ]; then
        mkdir -p "$DOCROOT/lazysite/themes/manager"
        cp "$VIEWS_TMP/manager/view.tt" \
            "$DOCROOT/lazysite/themes/manager/"
        mkdir -p "$DOCROOT/manager/assets"
        if [ -f "$VIEWS_TMP/manager/assets/manager.css" ]; then
            cp "$VIEWS_TMP/manager/assets/manager.css" \
                "$DOCROOT/manager/assets/"
        fi
        echo "  Installed: manager view and CSS"
    fi
    rm -rf "$VIEWS_TMP"
else
    echo "  git not found - skipping view install"
    echo "  Install manually: https://github.com/OpenDigitalCC/lazysite-views"
fi

# --- Seed nav.conf if not installed by views ---

if [ ! -f "$DOCROOT/lazysite/nav.conf" ] && [ -f "$SCRIPT_DIR/starter/nav.conf.example" ]; then
    cp "$SCRIPT_DIR/starter/nav.conf.example" "$DOCROOT/lazysite/nav.conf"
    echo "  nav.conf seeded from example"
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

# --- Check optional / feature-required dependencies ---

MISSING=""
perl -MArchive::Zip -e 1 2>/dev/null || MISSING="$MISSING Archive::Zip(libarchive-zip-perl)"
perl -e 'require Template::Plugin::JSON::Escape' 2>/dev/null \
    || MISSING="$MISSING Template::Plugin::JSON::Escape(libtemplate-plugin-json-escape-perl)"

echo ""
echo "lazysite installed successfully."

if [ -n "$MISSING" ]; then
    echo ""
    echo "Missing Perl modules (install these to enable the corresponding features):"
    echo "  Archive::Zip              — theme upload (manager UI)"
    echo "  Template::Plugin::JSON::Escape — search index (search-index.md)"
    echo ""
    echo "On Debian/Ubuntu:"
    echo "  sudo apt-get install libarchive-zip-perl libtemplate-plugin-json-escape-perl"
fi

echo ""
echo "Next steps:"
echo "  1. Edit $DOCROOT/lazysite/templates/view.tt to apply your site design"
echo "  2. Edit $DOCROOT/lazysite/lazysite.conf to configure your site"
echo "  3. Replace $DOCROOT/index.md with your content"
echo ""
