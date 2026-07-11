#!/bin/bash
# Commit-side actions for the audit-completeness round. Idempotent.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
SBOM="$REPO/dist/config/sbom-deps.json"

# --- SBOM: new core-module deps introduced this round -----------------------
# Sys::Syslog - Lazysite::Util::forward_line (Logging & forwarding plugin).
# Errno       - Lazysite::Manager::Common's EACCES/EPERM permission hint.
# Both ship with core perl; no distro package metadata needed.
tmp="$SBOM.tmp.$$"

jq '.modules["Sys::Syslog"] //= {
      "core": true,
      "license": "Artistic-1.0-Perl",
      "used_by": "optional syslog forwarding of audit trail + diagnostics (Lazysite::Util::forward_line, the Logging & forwarding plugin)"
    }
    | .modules["Errno"] //= {
      "core": true,
      "license": "Artistic-1.0-Perl",
      "used_by": "EACCES/EPERM detection for the actionable permission hint on manager write failures (Lazysite::Manager::Common)"
    }' "$SBOM" > "$tmp"
mv "$tmp" "$SBOM"

echo "SBOM: Sys::Syslog + Errno present:"
jq -c '.modules["Sys::Syslog"], .modules["Errno"]' "$SBOM"
