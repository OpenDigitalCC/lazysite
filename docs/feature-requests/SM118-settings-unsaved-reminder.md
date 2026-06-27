---
title: "SM118 - unsaved-changes reminder on the settings form"
subtitle: "The one place with an explicit Save should flag pending changes"
brand: plain
---

## What

The site-settings form (Config page) is the one manager surface that needs an explicit
**Save** (most others apply on toggle). Flag unsaved changes: when a field is edited,
show a "Unsaved changes - click Save" reminder by the Save button, and warn on leaving
the page (beforeunload) while dirty. Clear on a successful save.

**SHIPPED in v0.4.38.** Implemented in config.md: a form-level oninput/onchange sets a
dirty flag and reveals `#site-dirty`; `clearSiteDirty()` runs on save success;
`beforeunload` warns while dirty. Programmatic population (dropdown refresh) does not
fire the dirty flag.

## Status

Done (v0.4.38).
