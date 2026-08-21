---
title: "SM459: a page cannot read its own front matter"
subtitle: "A custom top-level key was visible to every page that scanned it, and invisible to the page that declared it. So an author wanting one fact in an index and in their own layout wrote it twice, and the copies drifted."
brand: plain
standard-margins: true
status: shipped
status-note: "FILED AND SHIPPED 2026-08-21 from the field, in 0.10.22 (5664bfb, with 90be150). BACKFILLED after t/lint/26 was widened to see qualified bullets and reported 0.10.22 claiming an item with no doc. THE ASYMMETRY: resolve_scan passes every non-reserved front-matter key through, so `accent`, `kind`, `order` are readable by any page that scans the file - while the page's OWN stash took only `tt_page_var` plus an explicit list. The same key was readable by every page except the one that declared it. WHY IT COSTS MORE THAN AN INCONVENIENCE: the workaround is to write the fact twice, top-level for the scan and again inside tt_page_var for the page, and nothing keeps the two in step. An author who later edits one has no signal that the other exists, so the index and the page disagree about the same fact and both look right in isolation. SHIPPED AS page_<key>, PREFIXED AND ESCAPED DELIBERATELY: SEC-2026-07 (H5) escapes author-controllable front matter at the single point it enters the stash, so every layout - including ones we do not ship and cannot edit - emits it safely without a `| html` filter; and a bare key could collide with a site variable and silently change what an author already depends on. Scalars only. THE RESERVED LIST IS NOW DECLARED ONCE and shared by the scan and the stash: two copies of one list drift, which is the same defect one level up and the third time in a week (SM435, SM457)."
---

# Readable by everyone except its own page

```datatable
columns: Reader | Sees `accent:`
widths: 7cm | X
bold: 1
tone: medium
---
Another page scanning this one | yes
An index built from a `scan:` | yes
**The page's own layout** | **no**
```

# Why the workaround is worse than the gap

Declaring the fact twice -- once top-level for the scan, once inside
`tt_page_var` for the page -- works, and nothing keeps the two in step. The
copies drift silently, the index and the page then disagree about the same
fact, and each looks correct on its own. The author has no signal that a
second copy exists until somebody notices the two answers.
