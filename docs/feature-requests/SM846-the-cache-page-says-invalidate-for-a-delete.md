---
title: "SM846: the cache page says 'invalidate' for what is a delete, hides which subdomain a page belongs to, and floats its button"
subtitle: "Release manager, 2026-09-11, on 0.13.12: three things on one page"
brand: plain
standard-margins: true
status: candidate
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
