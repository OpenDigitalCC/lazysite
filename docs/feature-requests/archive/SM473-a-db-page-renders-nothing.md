---
title: "SM473: a db: page variable rendered nothing, silently"
subtitle: "The API returned three rows and the same table on a page returned none. The processor is module-free by design and carries no @INC bootstrap - the require failed, the eval caught it, and a visitor got an empty list."
brand: plain
standard-margins: true
status: shipped
status-note: "REPORTED 2026-08-22 from edge by the field agent, who ruled out the obvious first: same page, one request, scan:/docs/*.md -> 26 items, an unrecognised prefix -> the literal, db:paintings -> nothing. So the source resolved and came back empty rather than being unrecognised. CAUSE: resolve_db required Lazysite::Data::Tables WITHOUT locating the module tree. The processor is module-free by design and carries no global @INC bootstrap - every other lazy-loading site in it (_chrome, fetch_url) finds the tree itself before requiring, and this one did not. WHY EVERY TEST PASSED: `prove -l` puts lib/ on @INC, so the require succeeded in every test and failed on every real install. That is the whole lesson - a test harness that supplies something production does not is a harness testing itself. THE SILENCE IS THE DEFECT, not the require: the failure was caught, logged as a WARN, and returned an empty list, so a page rendered zero rows to a visitor and looked like a table with nothing in it. ALSO FIXED: a table that is declared and never migrated now logs too. read_rows answers ok with pending_schema in that case, which is an ordinary state and indistinguishable on the page from an empty table - both render nothing, and nothing renders the hardest failure to notice on a live site. NOT THE WAL: my own brief told the field to suspect the store directory's writability first, and that was wrong here - a checkpointed store reads fine from an unwritable directory, which I verified before looking further."
---

# What the field saw

```datatable
columns: Same page, one request | Result
widths: 8cm | X
bold: 1
tone: medium
---
`scan:/docs/*.md` | 26 items
`nonsense:paintings` | 1 - falls through to the literal
`db:paintings` | **0**
`data-rows&table=paintings` over the API | 3 rows
```

That is a clean bisection: the prefix was recognised, the source resolved, and
it returned nothing.

# Why the tests could not see it

`prove -l` puts `lib/` on `@INC`. The require therefore succeeded in every
test and failed on every real install -- and the failure was caught, so
nothing crashed and a page simply rendered nothing.

A harness that supplies something production does not is a harness testing
itself.
