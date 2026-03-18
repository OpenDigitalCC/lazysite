#!/bin/bash
# lazysite uninstaller
# https://github.com/OpenDigitalCC/lazysite
#
# Removes Hestia template files only.
# Does not touch any deployed domain files.

set -e

TEMPLATE_DEST="/usr/local/hestia/data/templates/web/apache2/php-fpm"

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: uninstall.sh must be run as root" >&2
    exit 1
fi

echo "Removing lazysite Hestia templates..."

rm -f "$TEMPLATE_DEST/ssi-md.tpl"
rm -f "$TEMPLATE_DEST/ssi-md.stpl"
rm -f "$TEMPLATE_DEST/ssi-md.sh"
rm -rf "$TEMPLATE_DEST/files"

echo "Done. Deployed domain files have not been touched."
echo "To fully remove from a domain, switch it to a different web template and rebuild."
