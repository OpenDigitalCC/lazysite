---
id: SM970
title: "SM970: A value used as a whole link target keeps its URL scheme"
subtitle: "Escaping stops a value breaking out of an attribute; it does not stop `javascript:` being the attribute."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-07
raised-by: the SM869 adversarial review, second pass (n271)
area: security
status-note: "Filed 2026-10-07 from the SM869 adversarial review (second pass, n271). When an author places a query or data value as the WHOLE href/src, the value is HTML-escaped but its URL scheme is not checked, so javascript: or data: survives. Needs a decision on where scheme-checking belongs. WORK-PLAN-0153 Q12b."
---

# What the review recorded

Query and data values reach a page HTML-escaped (SM869, SM966), so a value cannot
leave the attribute it is placed in. But when an author writes the value as the
WHOLE target - `<a href="[% query.next %]">`, `<img src="[% i.url %]">` - escaping
does not change the scheme: `javascript:` and `data:` survive, and the link runs
script when followed. The shipped pages do not do this with visitor values
(login.md's `next` is checked server-side); a site author can.

# The decision needed

1. **A URL-safe accessor**: the engine offers a filter (`| url_safe` or similar)
   that passes `http`, `https`, `mailto`, `tel` and relative URLs and replaces
   anything else with `#`, and the authoring docs tell authors to use it in
   `href`/`src`. Explicit, opt-in, no surprises for existing pages.
2. **Checked by default**: the stash's escaped copy of a value that looks like a
   URL with a dangerous scheme is neutralised everywhere. Safer by default, but
   changes what every page receives and needs a definition of "looks like a URL".
3. **A lint for shipped pages only**, and documentation for authors.

Recommended: 1 with 3 - the filter plus a lint that shipped pages and layouts use
it wherever a template value is a whole `href`/`src`.

# Done when

Ruled and built; a test that a `javascript:` value placed as a whole href by the
recommended route renders inert.
