---
title: "SM846: the cache page says 'invalidate' for what is a delete, hides which subdomain a page belongs to, and floats its button"
subtitle: "Release manager, 2026-09-11, on 0.13.12: three things on one page"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-11. All three. The button: .mg-row is SM819's three-column grid and a cache row built five cells, so the last two wrapped to an implicit second row and the button sat in the middle column; the row now builds three (path with its domain tag, status and age, the button). The domain: cache-list returns a domain on every entry - an alias copy its host, a primary copy the host its site_url names, or with the ${SERVER_NAME} placeholder the name the request arrived on unless that is an alias, when it says 'default site' rather than a wrong name. The word: Delete on the row and Delete all at the top, in the confirmation, the status messages, the page note and the manager guide; the wire action keeps its name cache-invalidate. Measured by cell count in the rendered row, not by a screenshot."
---

# As reported

1. The row button **floats in the middle** of the row; it should sit on the right.
2. Each listed page should show **the subdomain it belongs to**.
3. **"Invalidate" is the wrong word.** What the button does is delete the listed
   cached page, which as a result invalidates the cache - so it should say
   *Delete*, and the top button that acts on every entry should change to match.

Recorded as reported and not yet re-measured.

# Why the word matters

A button names its act (the house rule behind lint 97). *Invalidate* names a
consequence the operator has to infer from; *Delete* names what happens to the
thing in the row. On a multi-domain instance, a cache list that does not say which
domain each entry serves is a list an operator cannot act on safely.

# Related

[[SM845]] (row controls across the manager).
