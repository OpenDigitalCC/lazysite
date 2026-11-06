---
id: SM1283
title: "SM1283: a system page serves when the engine tree is beside the docroot"
subtitle: "The engine's own sign-in and error pages (SM201) answered 404 on a site whose engine tree had moved beside the docroot (SM293) and whose docroot had no copy of its own. The fallback chose the engine's file and the content-root confinement then refused it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "found while designing n734 (engine-served docs), fix asked by the supervisor"
area: processor
status-note: "SHIPPED (0.16.3) on n734: the render path's confinement accepts a source the system-page fallback chose when its real path sits under the engine's page tree. t/integration/340."
---

# What was found

SM201 serves the sign-in and error pages (`login`, `claim`, `forgot`, `logout`,
`account`, `maintenance`, 402, 403, 404) from the engine's protected copy under
`lazysite/templates/system/` when the site has none. SM293 lets a site move its engine
tree beside the docroot (`<docroot>-lazysite`), which is the layout `lazysite check`
recommends.

On that layout, `/claim` and `/login` answered 404 when the docroot had no copy. A fresh
install seeds neither. The fallback picked `<docroot>-lazysite/templates/system/claim.md`.
The render path then checks the source's real path against the content root (SM151).
That path is outside the docroot, so the page was refused.

Measured before the fix: `/claim` was 200 with the tree inside the docroot and 404
with it moved beside it.

# What shipped

- **`_engine_page_real`** in `lazysite-processor.pl` says whether a real path sits under
  one of the engine's page trees. Each tree is resolved with `realpath`, so the check
  holds on both layouts.
- **The confinement** accepts a source only when the fallback itself chose it, and its
  real path is under one of those trees. Every other source is still confined to the
  content root and its private store. A page that is not a system page still 404s.
- The 404 page was not affected, because `not_found` renders without that check.

# Tests

- **t/integration/340** (new): with the tree inside the docroot, `/claim` serves. After
  the tree moves beside the docroot, `/claim` and `/login` serve the engine's pages, and
  a page that is not a system page still 404s. With the fix reverted, the two pages
  answer 404.
