#!/bin/sh
# install.sh - thin wrapper around install.pl (D021c).
#
# install.pl is the real installer, upgrade-aware and
# manifest-driven. This wrapper preserves the historic
# "./install.sh" invocation so operator muscle memory and
# documentation links continue to work.
set -e
exec perl "$(dirname "$0")/install.pl" "$@"
