---
id: SM1251
title: "SM1251: the starter contact page carries no style block"
subtitle: "The shipped /contact.md opened with a 60-line <style> that beat any theme's form rules on that page. The rules are in the fallback chrome now, and an upgrade refreshes an unmodified copy."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-21
raised-by: the theunited.community site agent, inbox 2026-10-21-starter-contact-inline-style-overrides-theme.md
area: starter
status-note: "SHIPPED (PENDING) on n728: the <style> block removed from starter/contact.md; the same rules under .lazysite-fallback in lazysite-chrome.css; t/tools/211 runs the upgrade; t/unit/processor/148."
---

# What happened

`starter/contact.md` (`provenance: lazysite-starter`) opened with a `<style>`
block styling `.lazysite-form`: hard-coded `#0056b3` buttons and focus ring,
`#ccc` borders, a right-aligned two-column label grid. In the page body it
comes after the theme's stylesheet, so on a site with a layout and theme the
contact page alone got blue buttons and the grid, whatever the theme said about
forms. Confirmed in the 0.16.0 tree: the block was in the shipped file, and
nothing scoped it.

# What shipped

- The `<style>` block is gone from `starter/contact.md`; the page is front
  matter and its `::: form` block.
- The same rules are in `starter/assets/lazysite-chrome.css`, each under
  `.lazysite-fallback .lazysite-form` (the fallback template's body class,
  SM1250). A site with no layout gets the same contact page as before; a site
  with a layout gets its theme's form styles, or the browser's if the theme has
  none.

# Existing sites

The page is a seed file (ADR 0004): an upgrade overwrites it when the copy on
disk matches the checksum the install state recorded, and preserves it
otherwise. Verified by running install.pl rather than assumed: a site holding
the 0.16.0 page byte for byte is upgraded to the new page, and a site whose
copy differs by one line keeps every byte and is told it was preserved. A site
that already removed the block by hand (theunited.community did) is a
customised copy and is left as it is.

# The suggested lint

Already there: `validate_page` (and the write tools that run it) warns
`style-block-in-page` on a `<style>` in page content (SM243,
lib/Lazysite/Validate.pm `_check_html_in_page`). Nothing was added.

Other shipped pages still carry inline `<style>`: `forgot.md`,
`search-results.md` and the system `login`, `forgot` and `claim` templates.
They were not in this report and are left for a separate ruling.

# Tests

- t/tools/211: the 0.16.0 page embedded verbatim (its sha256 asserted),
  provisioned, recorded in the install state as installed, and upgraded; the
  unmodified copy becomes the shipped page with no `<style>`, the customised
  copy is byte-identical and listed as preserved. With the old contact.md
  restored, the shipped-page and refreshed-page assertions fail.
- t/unit/processor/148: the form rules are in the chrome under the fallback
  class. They fail against the old stylesheet.
