---
id: SM978
title: "SM978: A PDF was made of pages the caller may not read"
subtitle: "page-pdf took no account of the caller's scope, and asked the content ACL of a composed document's parts but never of the page itself."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-10
raised-by: the developer agent, found during SM944 S29 (moving the page PDF area)
area: security
status-note: "SHIPPED (0.15.4): ruled 2026-10-10, Scope it + composed parts. page-pdf is path-scoped, as preview is; every page a PDF reads - the page and each part - is asked the caller's scope and the content ACL; a part outside the scope refuses the document, naming it. Lint 218 reads calls, not words. t/integration/122."
---

# What was wrong

`page-pdf` renders a page, or a composed document and its `parts:`, to a
branded PDF (SM732). Three ways it handed back pages the caller could not
otherwise read:

- **The caller's scope.** The action was declared `mutates => 1` with no
  `scoped`, so `_confine_scope` never saw its path, and nothing in
  `action_page_pdf` asked the domain rule. A cookie manager confined to
  content/clientA (manage_content, the test 31 fixture) got content/clientB's
  page as a PDF, where `read` of the same path answered "outside your assigned
  scope" (tmp/sm944-s29-scope-probe.pl, .out).
- **A composed document's parts** were asked the content ACL (`may_read`) and
  not the scope, so a document inside the caller's domain could pull in a page
  from another domain.
- **The page itself** was asked nothing. `may_read` reached only the parts, so
  any manage_content account got a page whose read rule named somebody else:
  `read` and `file-download` of it answered 403, `page-pdf` 200 and the PDF
  (tmp/q16b-acl-probe.pl, .out).

Lint 218 section 5 counted page-pdf as asking the domain rule. It did not: the
lint matched any word naming a sub that asks, and the package name in
`main->can('convert')` matched lazysite-dav.pl's `sub main`, which asks. Four
theme and layout subs passed the same way, on the string `'main'` and the file
name `main.css`.

# The ruling

Release manager, 2026-10-10, "Scope it + composed parts": declare page-pdf
path-scoped (`scoped => 1`, as preview is) so `_confine_scope` checks the
requested path; every page a composed PDF pulls in is checked against the
caller's scope as well as the content ACL (`may_read`). Fix lint 218 so
page-pdf is checked for real.

# The fix

- `page-pdf` is declared `scoped => 1` and `file_surface => 'read'` in
  `Lazysite::ControlApi::Actions`, as preview is (lint 14 holds every scoped
  verb to the file surface). The dispatcher refuses a page outside the caller's
  scope before the plugin is loaded, on both channels, with the refusal `read`
  gives.
- `action_page_pdf` asks the page's own read ACL before loading the plugin and
  answers `read`'s refusal (403, kind `permission`).
- The `may_read` it hands the plugin asks each part the scope first, then the
  ACL. **A part outside the scope refuses the whole document** (403, kind
  `forbidden`), naming the part: "This document includes 'X', which is outside
  your assigned scope (...). It is refused rather than built without that part,
  so what you get is never quietly incomplete." That is the fail-closed answer
  the page's own refusal gives, and the one the plugin already gives a part the
  ACL denies (SM706, "refused, not omitted"); leaving the part out would hand
  back a document that looks complete and is not.
- Lint 218 counts a sub as asking only when it CALLS one that asks (`name(` or
  `&name`), never a bare word. Its asking set lost exactly the six that matched
  `main`; page-pdf is held as path-confined and listed in %NO_NEW_BINDING (it
  writes a cached PDF, no page text).
- `page-pdf` is the one named exception to test 200's "no file-surface read
  mutates": it reads pages and is POST-only because it runs a converter and
  writes a cache.

# Evidence

t/integration/122: a confined manager gets its own page as a PDF and is refused
another domain's (403, "outside your assigned scope", nothing converted); a
composed document with one part outside the scope is refused naming the part,
one whose parts are all inside renders, and the unconfined operator gets both;
a page whose read rule names only the operator is refused to the confined
manager (403, kind `permission`) and rendered for the operator.

Sabotaged one at a time (tmp/q16b-sab-item1.sh, .out; restored with cp,
checked with cmp): without `scoped` the first subtest and lint 218 fail;
without the part scope check the second subtest fails; without the page's ACL
check the third fails; with lint 218 reading bare words again it fails
`calls()`, page-pdf's assertion and the %NO_NEW_BINDING staleness check.
