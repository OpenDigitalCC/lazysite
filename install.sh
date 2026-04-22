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

# --- Install core CGI scripts ---

echo "Installing lazysite scripts..."
install -m 755 "$SCRIPT_DIR/lazysite-processor.pl" "$CGIBIN/lazysite-processor.pl"
for script in lazysite-auth.pl lazysite-manager-api.pl; do
    if [ -f "$SCRIPT_DIR/$script" ]; then
        install -m 755 "$SCRIPT_DIR/$script" "$CGIBIN/$script"
    fi
done

# --- Install plugins (D022) ---
#
# Plugins live under {docroot}/../plugins/ with the lazysite- prefix
# dropped. manager-api @CANDIDATES enumerates them from this path.
mkdir -p "$DOCROOT/../plugins"
if [ -d "$SCRIPT_DIR/plugins" ]; then
    for script in "$SCRIPT_DIR/plugins/"*.pl; do
        [ -f "$script" ] || continue
        install -m 755 "$script" \
            "$DOCROOT/../plugins/$(basename "$script")"
    done
    echo "  Installed plugins from $SCRIPT_DIR/plugins/"
fi

# Web endpoints for plugin-exposed URLs. form-handler receives form
# POSTs; payment-demo is the x402 simulator. Both need cgi-bin
# presence so Apache routes /cgi-bin/<name>.pl at them. Symlink
# where supported, fall back to install for shared-host setups that
# disable FollowSymLinks.
for plugin in form-handler payment-demo; do
    src="$DOCROOT/../plugins/$plugin.pl"
    dst="$CGIBIN/$plugin.pl"
    if [ -f "$src" ] && [ ! -e "$dst" ]; then
        if ln -s "$src" "$dst" 2>/dev/null; then
            echo "  Linked:    $dst -> $src"
        else
            install -m 755 "$src" "$dst"
            echo "  Installed: $dst (symlink unsupported)"
        fi
    fi
done

# --- Install user-facing tools ---

mkdir -p "$DOCROOT/../tools"
for tool in lazysite-users.pl lazysite-server.pl build-static.sh; do
    src="$SCRIPT_DIR/tools/$tool"
    if [ -f "$src" ]; then
        install -m 755 "$src" "$DOCROOT/../tools/$tool"
        echo "  Installed: tools/$tool"
    fi
done

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

# D022: install .example reference files so operators can see the
# shipped defaults alongside their edited copies.
for ref in "$SCRIPT_DIR/starter/lazysite.conf.example" \
           "$SCRIPT_DIR/starter/nav.conf.example"; do
    if [ -f "$ref" ]; then
        name=$(basename "$ref")
        dst="$DOCROOT/lazysite/$name"
        if [ ! -f "$dst" ]; then
            install -m 644 "$ref" "$dst"
            echo "  Installed: lazysite/$name"
        fi
    fi
done

for ref in "$SCRIPT_DIR/starter/lazysite/auth/users.example" \
           "$SCRIPT_DIR/starter/lazysite/auth/groups.example"; do
    if [ -f "$ref" ]; then
        name=$(basename "$ref")
        dst="$DOCROOT/lazysite/auth/$name"
        if [ ! -f "$dst" ]; then
            install -m 640 "$ref" "$dst"
            echo "  Installed: lazysite/auth/$name"
        fi
    fi
done

# D022: seed auth users/groups from the .example files on fresh
# install. Operators can hand-edit afterwards or use the manager UI.
for f in users groups; do
    src="$DOCROOT/lazysite/auth/$f.example"
    dst="$DOCROOT/lazysite/auth/$f"
    if [ -f "$src" ] && [ ! -f "$dst" ]; then
        install -m 640 "$src" "$dst"
        echo "  Seeded lazysite/auth/$f from $f.example"
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

# Install docs if not already present (top-level docs)
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

# D022: also install the features subtree (SM025 catch-up).
if [ -d "$SCRIPT_DIR/starter/docs/features" ]; then
    find "$SCRIPT_DIR/starter/docs/features" -type f -name '*.md' | \
    while read -r src; do
        rel="${src#$SCRIPT_DIR/starter/docs/}"
        dst="$DOCROOT/docs/$rel"
        if [ ! -f "$dst" ]; then
            mkdir -p "$(dirname "$dst")"
            install -m 644 "$src" "$dst"
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

# Install registry templates (D022: source path moved to mirror
# install destination under starter/lazysite/templates/registries/)
for tmpl in "$SCRIPT_DIR/starter/lazysite/templates/registries/"*.tt; do
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
