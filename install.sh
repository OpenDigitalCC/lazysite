#!/bin/bash
# lazysite installer
# https://github.com/OpenDigitalCC/lazysite

set -e

TEMPLATE_SRC="$(dirname "$0")/template"
TEMPLATE_DEST="/usr/local/hestia/data/templates/web/apache2/php-fpm"

# --- Checks ---

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: install.sh must be run as root" >&2
    exit 1
fi

if [ ! -d "$TEMPLATE_DEST" ]; then
    echo "Error: Hestia Apache php-fpm template directory not found at $TEMPLATE_DEST" >&2
    echo "Is HestiaCP installed with Apache + PHP-FPM?" >&2
    exit 1
fi

echo "Checking dependencies..."

MISSING=""
perl -e "use Text::MultiMarkdown" 2>/dev/null || MISSING="$MISSING libtext-multimarkdown-perl"
perl -e "use Template" 2>/dev/null            || MISSING="$MISSING libtemplate-perl"
perl -e "use LWP::UserAgent" 2>/dev/null      || MISSING="$MISSING libwww-perl"

if [ -n "$MISSING" ]; then
    echo "Installing missing Perl modules:$MISSING"
    apt-get install -y $MISSING
fi

# --- Install templates ---

echo "Installing Hestia web templates..."

install -m 644 "$TEMPLATE_SRC/ssi-md.tpl"  "$TEMPLATE_DEST/ssi-md.tpl"
install -m 644 "$TEMPLATE_SRC/ssi-md.stpl" "$TEMPLATE_DEST/ssi-md.stpl"
install -m 755 "$TEMPLATE_SRC/ssi-md.sh"   "$TEMPLATE_DEST/ssi-md.sh"

# Copy domain files alongside the .sh script
mkdir -p "$TEMPLATE_DEST/files"
install -m 644 "$TEMPLATE_SRC/files/md-processor.pl" "$TEMPLATE_DEST/files/md-processor.pl"
install -m 644 "$TEMPLATE_SRC/files/layout.tt"        "$TEMPLATE_DEST/files/layout.tt"
install -m 644 "$TEMPLATE_SRC/files/layout.vars"      "$TEMPLATE_DEST/files/layout.vars"
install -m 644 "$TEMPLATE_SRC/files/404.md"           "$TEMPLATE_DEST/files/404.md"
install -m 644 "$TEMPLATE_SRC/files/index.md"         "$TEMPLATE_DEST/files/index.md"

mkdir -p "$TEMPLATE_DEST/files/registries"
install -m 644 "$TEMPLATE_SRC/files/registries/llms.txt.tt"    "$TEMPLATE_DEST/files/registries/llms.txt.tt"
install -m 644 "$TEMPLATE_SRC/files/registries/sitemap.xml.tt" "$TEMPLATE_DEST/files/registries/sitemap.xml.tt"

echo ""
echo "lazysite installed successfully."
echo ""
echo "Next steps:"
echo "  1. In HestiaCP, edit your domain and set the web template to: ssi-md"
echo "  2. Rebuild the domain - the processor and starter files will be installed automatically"
echo "  3. Edit public_html/templates/layout.tt to apply your site design"
echo "  4. Replace public_html/index.md with your content"
echo ""
