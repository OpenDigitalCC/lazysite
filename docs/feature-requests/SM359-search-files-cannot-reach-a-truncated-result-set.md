---
title: "SM359 - search_files cannot reach a truncated result set"
subtitle: "`truncated: true` is honest and says so plainly - and there is no `limit`, `offset`, `page` or cursor, so match 201 is unreachable through the tool. `count` does not say whether it means matches returned or matches that exist, and once truncation is possible those differ."
brand: plain
status: candidate
---

# SM359 - honest about withholding, with no way to ask for the rest

## What was measured

edge 0.10.12, MCP:

```
search_files {"query":"lazysite"}
  -> { "query":"lazysite", "count":200, "truncated":true, "matches":[ ... 200 ... ] }
```

The tool's full input schema:

```
required: ["query"]
properties: ["path", "query"]
```

No `limit`, no `offset`, no `page`, no cursor, no `after`. So a caller that
sees `truncated: true` has no request it can make to see what was withheld.

## Credit where it is due

`truncated: true` is the good half and worth stating, because the common
version of this defect is a tool that returns a capped list and implies it
is complete. This one says it withheld results. That is the difference
between a caller that knows it has partial data and one that does not - and
it is the same property [[SM213]] built into the stats horizon fields, where
`data_from` and `sample:{from,to,count}` replaced a bare `events_capped`
precisely so a reader could tell what a number covered.

The gap is narrower than "search is broken". It is that the honesty has no
follow-up action attached.

## Why it matters

**The cap bites on ordinary sites, not large ones.** 200 matches for
`lazysite` on a 26-page instance. Any site with a common term - a product
name, the company name, a recurring heading - reaches it. This is not an
edge case reserved for big content sets.

**The available workaround is a guess.** A caller can narrow with `path`
and re-search. That helps when the caller already knows where to look,
which is the case where they needed search least. There is no way to
enumerate systematically, and no way to know when everything has been seen.

**It blocks the uses search exists for.** Finding every page that mentions a
retired product, every reference to a URL being changed, every page needing
a term updated - all of these need completeness, and all of them silently
stop at 200. An agent doing a site-wide content migration would sweep 200
matches, report success, and leave the remainder untouched.

## The `count` ambiguity, which is the part to settle first

`count: 200` alongside `truncated: true` does not say which of two things it
is:

matches returned
: then the caller knows it has 200 and has no idea how many exist.

matches that exist
: then 200 is the total, and `truncated` means something else entirely -
  perhaps that match *bodies* were trimmed.

Whichever it is, the schema should say. And if it means "returned", a
separate total is what turns `truncated: true` from honest into actionable:
*"200 of 1,431"* tells a caller how much it is missing and whether narrowing
is worth attempting.

This is the same class as [[SM330]]'s second question - an index row
reporting `pageviews` beside class counts measuring a different population -
where two numbers in one response invite the wrong arithmetic.

## The fix

Add paging. `limit` and `offset` is the smaller change and fits the existing
shape; a cursor is better if the index can shift between calls, since offset
paging over changing content silently skips and repeats.

Then either rename `count` to say what it counts, or add the total beside
it.

## Verification

- A truncated search can be paged to completion, and the final page reports
  itself as final.
- The response states how many matches exist, not only how many were
  returned.
- `count` is documented as returned-or-existing and the schema says which.
- A caller paging through a result set receives each match once - no skips,
  no repeats - or the response carries a cursor that guarantees it.
- Protected content stays excluded on every page, not only the first. This
  is the one that would be easy to get wrong while adding paging, and it is
  currently correct: a canary inside a protected folder returns zero
  matches.

## Related

[[SM213]] (self-describing horizons - `data_from` and `sample` replacing a
bare cap flag, the precedent for saying what a result covers), [[SM330]]
(two numbers in one response measuring different populations), and
`inbox/four-surface-residual-observations-2026-08-17.md`.
