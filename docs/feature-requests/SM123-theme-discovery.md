---
title: "SM123 - theme discovery: list installed themes + asset-mirror lifecycle"
subtitle: "See what themes are installed without activating each in turn"
brand: plain
---

## From the field report (Low/Medium)

No theme listing
: "`whoami` reports `layouts.available` but `themes:[]` even with five installed, and I
  found no action to list installed themes per layout. I verified installs by activating
  each in turn - heavier than needed."

Asset-mirror lifecycle
: "`/lazysite-assets/L/T/` populates on activation, not on a WebDAV PUT, so a
  freshly-uploaded theme's assets 404 until first activated. Undocumented, and a source
  of confusion on a prior build."

## Shape

- A `themes-list` (or `list_themes`) action/tool returning the themes installed per
  layout (there is a `themes-for-layout` action for the active layout - expose it to
  connectors and surface installed themes in `whoami`/`get_permissions` so `themes:[]`
  is correct).
- Document the asset-mirror lifecycle (assets mirror to `/lazysite-assets/L/T/` on first
  activation), or populate the mirror on PUT so freshly-uploaded assets resolve
  immediately.

## Status

Queued. Two small items: expose the theme list to connectors + fix the whoami `themes`
field; document (or eager-populate) the asset mirror.
