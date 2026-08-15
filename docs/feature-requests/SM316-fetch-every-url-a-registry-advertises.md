---
title: "SM316 - fetch every URL a generated registry advertises"
subtitle: "A registry is a list of promises about what retrieves. Nothing checked that they do, and SM299 was one of these for as long as the namespace existed."
brand: plain
status: shipped
status-note: "SHIPPED in 0.10.10 as t/integration/54. Generates all four registries, extracts every URL, fetches it, asserts 200. VERIFIED AGAINST THE REAL DEFECT rather than a description of it: reintroducing the pre-SM299 expression into the shipped template makes it fail with '/docs/.md -> 404'. Nomination 3 of four made by the site agent before stable. The fixture carries an ordinary page, a folder index AND a nested folder index, because the 0.10.9 fix was first written with a non-recursive glob and a single-level fixture would have passed against the half-fixed engine."
---

# What was missing

SM299: every site's `llms.txt` opened with a dead link, including lazysite's own
documentation. The template appended `.md` to the page URL - right for an
ordinary page, wrong for an INDEX page whose URL already ends in a slash, so it
produced `<dir>/.md`. The homepage is an index page, so the broken entry was the
first line of every site's `llms.txt` and the one an AI client is most likely to
follow.

The fix shipped in 0.10.9 and the check did not. `t/lint/46` was written instead,
and it asserts the registration *policy* by globbing source files - which pages
DECLARE `llms.txt`. It cannot establish that what the file advertises resolves,
which is the only thing SM299 was about.

# The shape it covers

A URL constructed by string manipulation from another URL. All four registries do
that, which is why all four are covered rather than the two that were reported: a
rule that holds for the common case and breaks on a trailing slash is exactly
what review does not catch and a fetch does.

# One thing worth recording about writing it

The extractor initially knew two of the four registry shapes, so both feeds
reported zero advertised URLs. That looked like a defect in the engine and was a
defect in the test. A check like this passes while asserting nothing if the
extraction is wrong, which is why the "advertises at least N" assertion is
load-bearing rather than decorative.

# Related

SM299 (the defect this would have caught), `t/lint/46` (the policy check this
complements rather than replaces).
