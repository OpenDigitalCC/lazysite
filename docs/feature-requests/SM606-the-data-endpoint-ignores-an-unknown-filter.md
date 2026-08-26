---
title: "SM606: the data endpoint ignores an unknown query parameter and returns an unfiltered result that looks filtered"
subtitle: "`?table=t&chunk=AAA` returns every row. A bad VALUE is a 400; an unknown PARAMETER is silence, and the reply is shaped exactly like a filtered one."
brand: plain
standard-margins: true
status: candidate
status-note: "DOCUMENTED, NOT FIXED, for 0.11.0, and the split is deliberate. Refusing an unknown query parameter would break any caller passing a harmless extra - a cache-buster is the obvious one - and that is a behaviour change that deserves its own release rather than a ride on a stable cut. /docs/data-tables now states the four parameters the endpoint reads and says the rest are IGNORED, NOT REFUSED, with the `chunk=AAA` example and where to filter instead. That closes the silence for a reader today; the code fix waits. FOUND 2026-08-26 while reviewing the site agent's practice notes before publication - they had documented it as a hazard to work around, which is the right instinct and the wrong resting place. VERIFIED FROM THE CODE: lazysite-data.pl assembles its binding from `order_by`, `order`, `limit` and `offset` and reads nothing else, so any other parameter is dropped without a word. The reply carries rows and `ok:1` and is indistinguishable from a filtered one. NOT A PRIVILEGE LEAK, and that distinction matters: the endpoint resolves as THE VISITOR with no operator bypass (SM476), so a caller still sees only rows their grant and the table's publication state allow. What it breaks is APP LOGIC - an app that scopes rows by a column, which is the natural way to give each user their own records inside one table, receives every row it is entitled to see rather than the subset it asked for, and displays them. THE FILE'S OWN PHILOSOPHY ARGUES FOR THE FIX: 'A BAD BINDING IS A 400, NOT A 404 - no such table for a limit that is not a number would send a caller looking for a table that is right there.' A bad VALUE is refused with a reason; an unknown NAME is ignored. The asymmetry is the defect. RECOMMENDED FIX: refuse any query parameter outside the known set with a 400 naming it and listing what is accepted, exactly as an out-of-range limit is refused. The alternative - supporting column filters here to match the page grammar - is a larger change with a real argument behind it (SM476 exists because the two doors applied different rules), and is a feature rather than a fix. SAME CLASS AS SM605: a parameter that is read by one route and silently dropped by another, where the caller's obvious next move cannot work."
---

# The two doors, still not agreeing

| Read path | `chunk=AAA` |
|---|---|
| `db:t(chunk=AAA)` in front matter | filters |
| `/cgi-bin/lazysite-data.pl?table=t&chunk=AAA` | **ignored - every row returned** |

SM476 exists because these two doors applied different rules. They still
do; the difference moved rather than closed.

# Why silence is the wrong answer here

The endpoint already refuses a bad value and says why:

```
?limit=abc   -> 400  limit must be a whole number
?order_by=1  -> 400  order_by must be a field name
?chunk=AAA   -> 200  { ok: 1, rows: [ ...everything... ] }
```

A caller who mistypes a value is told. A caller who uses a parameter that
does not exist is answered as though it did.
