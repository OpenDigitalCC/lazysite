#!/bin/bash
# build-static.sh - generate all pages as static HTML
# Usage: build-static.sh <scheme://hostname> [output-dir]
#
# Examples:
#   build-static.sh https://example.com
#   build-static.sh https://example.com ./dist

set -e

# --- Usage ---

usage() {
    cat << 'EOF'
build-static.sh - generate a complete static site from lazysite sources

Usage:
  build-static.sh <scheme://hostname> [output-dir]

Arguments:
  scheme://hostname   Base URL of the site. Sets SERVER_NAME and
                      REQUEST_SCHEME for correct site_url interpolation
                      in lazysite.conf and templates.
                      Example: https://example.com

  output-dir          Directory to write the generated site.
                      Defaults to ./public_html (in-place build).
                      If a separate directory is given, source files
                      (.md, .url, assets, templates) are copied there
                      first, then pages are generated.

Examples:
  # Build in-place (public_html is both source and output)
  build-static.sh https://example.com

  # Build to a separate output directory
  build-static.sh https://example.com ./dist

  # Build and rsync to static hosting
  build-static.sh https://example.com ./dist
  rsync -av --delete ./dist/ user@host:/var/www/html/

  # Build for GitHub Pages
  build-static.sh https://username.github.io ./docs

Notes:
  - Existing .html cache files are removed before building to ensure
    all pages are regenerated with the correct base URL.
  - Pages with remote .url sources will be fetched during the build.
  - The processor (cgi-bin/lazysite-processor.pl) must be present relative
    to the docroot.
  - Output directory will not contain .md or .url source files if a
    separate output directory is specified - only the generated .html,
    assets, and templates are included in the output.

EOF
    exit 1
}

# --- Arguments ---

if [ -z "$1" ]; then
    usage
fi

BASE_URL="$1"

# Parse scheme and hostname from base URL
if [[ "$BASE_URL" =~ ^(https?)://([^/]+) ]]; then
    export REQUEST_SCHEME="${BASH_REMATCH[1]}"
    export SERVER_NAME="${BASH_REMATCH[2]}"
else
    echo "Error: invalid base URL '$BASE_URL'" >&2
    echo "Expected format: scheme://hostname  e.g. https://example.com" >&2
    exit 1
fi

# Locate docroot - assume script is run from the site root or repo root
if [ -d "./public_html" ]; then
    DOCROOT="$(pwd)/public_html"
elif [ -f "./lazysite/templates/view.tt" ]; then
    DOCROOT="$(pwd)"
else
    echo "Error: cannot locate docroot." >&2
    echo "Run build-static.sh from the site root directory containing public_html/," >&2
    echo "or from the docroot itself." >&2
    exit 1
fi

PROCESSOR="$DOCROOT/../cgi-bin/lazysite-processor.pl"
if [ ! -f "$PROCESSOR" ]; then
    PROCESSOR="$DOCROOT/cgi-bin/lazysite-processor.pl"
fi
if [ ! -f "$PROCESSOR" ]; then
    echo "Error: lazysite-processor.pl not found." >&2
    echo "Expected at $DOCROOT/../cgi-bin/lazysite-processor.pl or $DOCROOT/cgi-bin/lazysite-processor.pl" >&2
    exit 1
fi

OUTPUT_DIR="${2:-}"

# --- Prepare output directory ---

if [ -n "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$(realpath "$OUTPUT_DIR")"
    mkdir -p "$OUTPUT_DIR"

    echo "Copying source files to $OUTPUT_DIR..."
    rsync -a \
        --exclude="*.html" \
        --exclude=".git" \
        "$DOCROOT/" "$OUTPUT_DIR/"

    BUILD_ROOT="$OUTPUT_DIR"
else
    BUILD_ROOT="$DOCROOT"
fi

export DOCUMENT_ROOT="$BUILD_ROOT"
export SERVER_PORT="443"
export HTTPS="on"

# --- Clear existing cache ---

echo "Clearing cached HTML files..."
find "$BUILD_ROOT" -name "*.html" \
    ! -path "*/lazysite/*" \
    -delete

# --- Build pages ---

echo "Building site for $REQUEST_SCHEME://$SERVER_NAME..."
echo ""

BUILT=0
FAILED=0

while IFS= read -r source; do
    # Derive page path relative to build root
    rel="${source#$BUILD_ROOT/}"
    base="${rel%.*}"

    # Normalise index pages
    if [[ "$base" == */index ]]; then
        page_uri="/${base%/index}/"
    else
        page_uri="/$base"
    fi

    # Skip lazysite system directory
    [[ "$rel" == lazysite/* ]] && continue

    # Run processor
    output=$(REDIRECT_URL="$page_uri" \
             DOCUMENT_ROOT="$BUILD_ROOT" \
             perl "$PROCESSOR" 2>&1)

    exit_code=$?

    # Check that an html file was written
    html_path="$BUILD_ROOT/$base.html"

    if [ -f "$html_path" ]; then
        echo "  OK  $page_uri"
        BUILT=$((BUILT + 1))
    else
        echo "  FAIL $page_uri"
        if [ -n "$output" ]; then
            echo "       $output"
        fi
        FAILED=$((FAILED + 1))
    fi

done < <(find "$BUILD_ROOT" \( -name "*.md" -o -name "*.url" \) \
    ! -path "*/lazysite/*" \
    | sort)

# --- Remove source files from output dir if separate ---

if [ -n "$OUTPUT_DIR" ]; then
    echo ""
    echo "Removing source files from output..."
    find "$OUTPUT_DIR" -name "*.md" -delete
    find "$OUTPUT_DIR" -name "*.url" -delete
fi

# --- Summary ---

echo ""
echo "Build complete."
echo "  Built:  $BUILT pages"
if [ "$FAILED" -gt 0 ]; then
    echo "  Failed: $FAILED pages"
    echo ""
    echo "Check output above for errors."
    exit 1
fi
echo ""
echo "Output: $BUILD_ROOT"
echo ""
echo "Deploy with rsync:"
echo "  rsync -av --delete $BUILD_ROOT/ user@host:/path/to/webroot/"
echo ""
