---
title: "SM097 - nav editor: autocomplete URLs from existing pages"
subtitle: "Offer the pages that exist when typing a nav link"
brand: plain
---

## What

In the nav editor (`/manager/nav`), when adding or editing a nav item's URL, offer
an autocomplete of the site's existing pages (and their clean URLs), so the operator
picks a real target rather than typing a path that may not exist.

## Why

Raised 2026-06-26. A nav that points at a non-existent page is an easy mistake; the
manager already knows every page (the file manager / `list_pages`), so the URL field
should complete from that set.

## Shape

- On nav-editor load, fetch the page list (reuse the control API: a recursive file
  list filtered to `.md`/`.url`, or the same data the connector's `list_pages`
  returns) and map each to its **clean URL** (`about.md` -> `/about`,
  `index.md` -> `/`).
- Back each URL `<input>` with a `<datalist>` of those URLs (native, zero-dependency
  completion), or a small filtered dropdown.
- Keep free text allowed (external URLs, anchors, not-yet-created pages) - the
  datalist suggests, it does not restrict.
- Optional: flag a nav target that matches no existing page (a soft "no such page
  yet" hint), complementing `audit_site`'s broken-link check.

## Status

Queued. Small: a datalist populated from the existing page list in
`starter/manager/nav.md`.

## Status (reconciled)

**SHIPPED in v0.4.43.** Nav URL field backed by a datalist of the site page URLs (new manager-api `pages` action).
