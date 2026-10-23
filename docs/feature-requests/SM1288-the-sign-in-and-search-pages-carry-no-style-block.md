---
id: SM1288
title: "SM1288: the sign-in and search pages carry no style block"
subtitle: "The starter /forgot.md and /search-results.md, and the engine's login, forgot and claim pages, each opened with a <style> that beat any theme's rules on that page. The rules are in the fallback chrome now, and an upgrade refreshes an unmodified starter copy."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: the release manager, ruling 12 (rulings-2026-10-22), from the pages SM1251 named
area: starter
status-note: "SHIPPED (PENDING) on n735: the <style> blocks removed from five pages; the same rules under .lazysite-fallback in lazysite-chrome.css; t/unit/processor/160 renders each page with and without a layout and theme; t/tools/280 runs the upgrade."
---

# What happened

SM1251 took the inline `<style>` out of the starter `/contact.md` and named the
other shipped pages that still carried one: `starter/forgot.md`,
`starter/search-results.md`, and the engine's own login, forgot and claim pages
under `starter/lazysite/templates/system/`. A page's `<style>` comes after the
theme's stylesheet, so on a site with a layout and theme each of those pages
wore the engine's blue buttons, right-aligned label grid and `#eee` rules,
whatever the theme said. Ruling 12 moved them in this batch.

# What shipped

- The `<style>` block is gone from all five pages. Each page is now its front
  matter and its markup, and the classes it uses are unchanged.
- The same rules are in `starter/assets/lazysite-chrome.css`, each under
  `.lazysite-fallback` (the fallback template's body class, SM1250): the reset
  and claim forms, the login form and its context, error and URL boxes, and the
  search results. The two forgot pages had identical rules and share them. The
  login rules keep their `var(--theme-colours-*, fallback)` references, which
  resolve to their fallbacks here.
- A site with no layout gets the same pages as before. A site with a layout gets
  its theme's styles on them; where the theme has no form styles, the SM1289
  base rules give the sign-in forms readable spacing, full-width inputs and
  buttons.

# Existing sites

- The starter `/forgot.md` and `/search-results.md` are seed files (ADR 0004):
  an upgrade overwrites a copy that still matches the checksum the install state
  recorded and preserves one that differs. This was run rather than assumed: a
  site holding the 0.16.1 pages byte for byte is upgraded to the new pages, and
  a site whose copies differ by one line keeps every byte and is told they were
  preserved.
- The engine's login, forgot and claim pages are the code bucket (SM201) and are
  replaced on every upgrade. A site's own copy at its docroot is its content and
  is not touched.
- `t/integration/207` holds the two forgot pages equal, and they still are.

# Not moved

The manager's own pages (`manager/edit.md`, `manager/style-guide.md`) style the
manager and have `manager.css` for that; ruling 12 did not name them.
`starter/docs/features/index.md` carries a one-line `<style>` for its index
list, already written in theme tokens; it was not named either, and is left
for the briefings work (n734), which moves the docs tree.

# Tests

- t/unit/processor/160: none of the five shipped pages has a `<style>`; each
  rendered with no layout has none of its own, carries the fallback body class
  and links the chrome; each rendered under a layout with an active theme has no
  `<style>` and no fallback class; the moved rules are in the chrome under the
  class. With the old pages and stylesheet restored, 25 assertions fail.
- t/tools/280: the 0.16.1 pages embedded verbatim (sha256 asserted), provisioned,
  recorded as installed and upgraded; the unmodified copies become the shipped
  pages with no `<style>`, the customised copies are byte-identical and listed
  as preserved. With the old pages restored, the shipped-page and refreshed-page
  assertions fail.
