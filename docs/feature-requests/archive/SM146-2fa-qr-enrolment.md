---
title: "SM146 - 2FA enrolment: QR, copyable secret, recovery codes"
subtitle: "Set up / Disable states and a scannable QR"
brand: plain
status: shipped
status-note: "delivered 2026-07-12; Set up 2FA / Disable 2FA states, client-side QR from the bundled qrcode-generator (SM147), copyable secret, collapsible recovery codes"
---

# SM146 - 2FA enrolment: QR, copyable secret, recovery codes

## Why

The 2FA control was a bare **Enable 2FA** button with no indication of whether
2FA was already on, and enrolment showed only the secret string and otpauth URI
- no QR to scan. Operators expect a QR and a clear enabled/disabled state.

## Shape

- The control now reflects state: **not set up** shows a *Set up 2FA* button;
  **enabled** shows an `enabled` tag and *Disable 2FA*.
- Setting up reveals, in the account editor sheet: a **QR code** to scan, the
  **copyable secret** beneath it (for manual entry when a QR can't be scanned),
  and the **recovery codes** behind a *Show recovery codes* disclosure. All
  shown once.

## Implementation

The TOTP backend already returned the secret, an `otpauth://` URI and recovery
codes (`mfa-enroll`); this is UI. The QR is rendered **client-side** from the
otpauth URI by the bundled `qrcode-generator` library (see [[SM147]] for the
SBOM/notices) - lazily loaded only when setup is invoked, and drawn as an inline
SVG from the library's `isDark()` matrix (the URI is never inserted as markup -
no injection surface). No CDN, no host dependency. `starter/manager/users.md`
(`setup2fa` / `renderQR` / `withQR`) + `manager.css` (`.mg-qr`).
