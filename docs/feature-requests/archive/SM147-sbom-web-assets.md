---
title: "SM147 - SBOM covers bundled web assets, and stays complete"
subtitle: "Every vendored JS/CSS in the release SBOM, enforced"
brand: plain
status: shipped
status-note: "web_assets channel + gate (2026-07-12): CodeMirror + qrcode-generator declared, t/lint/11 fails on any undeclared bundle. qrcode.js promoted to a shared PUBLIC asset (/assets/qrcode.js), used by both the manager 2FA and the built-in ::: qr content component. Ongoing: periodic re-scan for new bundle types (fonts, wasm) + version/VEX refresh at release time"
---

# SM147 - SBOM covers bundled web assets, and stays complete

## Why

The release SBOM was Perl-module focused; bundled third-party **web assets**
(CodeMirror, and now the 2FA `qrcode-generator`) appeared only in
THIRD-PARTY-NOTICES, not the SBOM. A bundled library that never reaches the
SBOM is a supply-chain blind spot.

## Delivered

- `dist/config/sbom-deps.json` gains a **`web_assets`** array (name, version,
  licence, purl, files glob, homepage, used_by). CodeMirror 5.65.16 and
  qrcode-generator 1.4.4 are declared.
- `tools/manifest-to-sbom.pl` emits each `web_assets` entry as a CycloneDX
  `library` component (category `web-asset`) with its real upstream identity
  and licence - distinct from the per-file `source` components.
- `t/lint/11-web-assets-sbom.t` **scans** the tree for vendored bundles
  (`*.min.js` / `*.min.css`, plus known plain-JS vendors) and fails the build
  if any is not covered by a `web_assets` files glob. So a new library cannot
  ship undeclared.

## Shared public asset + TT helper (delivered)

`qrcode.js` is now a shared **public** asset at `/assets/qrcode.js`
(`starter/assets/qrcode.js`, served from the docroot, no auth) - the manager
2FA QR loads it there, and so does a new **built-in `::: qr` content
component** (`starter/lazysite/templates/components/qr.tt`). The processor
gained a built-in-component fallback: `::: name` resolves against the active
layout's `components/` first, then `lazysite/templates/components/`, so `::: qr`
works on any layout. Authors write `::: qr data="https://..." size="180"`.

## Open

- Re-scan periodically for asset types the heuristic does not yet catch
  (bundled fonts, wasm, unminified vendored JS other than the known list) and
  broaden the gate's candidate set as needed.
- Refresh `version` fields (and any VEX/advisory data) at release time; the
  gate checks presence, not that the declared version matches upstream.
