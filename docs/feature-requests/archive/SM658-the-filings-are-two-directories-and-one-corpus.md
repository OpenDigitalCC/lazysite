---
title: "SM658: 544 filings in one flat directory, indexed by a hand-written file seven weeks stale"
subtitle: "Operator, 2026-08-27: 'what is an efficient way to understand what's there? should we have an index, searchable, json, can they be updated with metadata to mark what they relate to?'"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED. Raised by the operator 2026-08-27 and built the same day. WHAT WAS THERE: 544 filings in one directory, 90% of them terminal, and TWO indexes - tools/backlog.pl deriving status from each filing's own header (correct), and docs/feature-requests/BACKLOG.md, hand-written, last updated 2026-07-10, deriving status 'from the CHANGELOG ... not the per-doc text'. A second source of truth about 500+ documents, already drifted. The first move was to retire the stale one rather than add a third. THE 489 TERMINAL FILINGS (shipped + superseded) MOVED to docs/feature-requests/archive/, so the top level shows the 35 open items at a glance. Everything reading the corpus learned about both directories: t/lint/09, t/lint/26's CHANGELOG resolver, and backlog.pl - each globbed one directory NON-RECURSIVELY, so the move alone would have dropped 489 documents out of the status gate and reported every released CHANGELOG entry as missing. THE RELATION GRAPH IS DERIVED, NOT STORED, and this reverses what was originally proposed. 543 of 544 filings already name another SM in their prose - 3,572 references - so the graph existed and was simply not machine-readable. Writing a `relates:` field into 544 files would have made a second copy of a fact the body already carries, drifting the moment either was edited: the same defect SM654 filed against the hand-kept unlocks map, learned twice. It is computed by backlog.pl instead - 993 edges after dropping self-references and refs to numbers never filed. An author may still declare `relates:` for a relationship the prose does not state; it is unioned in. TWO NUMBERS CARRY TWO DOCUMENTS EACH - SM076 and SM270 - which a hash keyed by SM number silently collapsed. Keyed by path now, with both indexed and the collision reported on STDERR. Five sabotages, all fail. NOT DONE: the `area:` field. A closed vocabulary is what would make it group, and inventing one and applying it to 544 files by guesswork produces a confident wrong index - worse than none, because a reader trusts it. Left for the operator's taxonomy, to be filled on touch."
---

# What was there

| | |
|---|---|
| Filings | 544, one flat directory |
| Terminal (shipped or superseded) | 489 |
| Open | 35 |
| Indexes | two - one derived and correct, one hand-written and stale |

`BACKLOG.md` said it derived status "from the CHANGELOG ... not the per-doc
text". Every filing already carries its own `status:` header, enforced by
`t/lint/09`. So the project held two answers to "is this done", and the
hand-written one had been unmaintained since 2026-07-10.

# The move, and what had to learn about it

Terminal filings now live in `docs/feature-requests/archive/`. The top level is
the open set.

Three readers globbed that directory **non-recursively**, and each would have
failed silently or loudly on the day of the move:

- `t/lint/09` would have stopped checking 489 filings' status vocabulary -
  silently.
- `t/lint/26` resolves every CHANGELOG `SM` reference by globbing that
  directory. A released entry names an item that is by definition terminal, so
  it would have reported essentially all of them missing.
- `tools/backlog.pl --all` would have shown 35 items and called it everything.

All three read both directories now.

# The graph was already written, in prose

543 of 544 filings name another SM. There are 3,572 such references - about six
per filing. The relationships have been recorded all along, in sentences.

**Deriving that is better than storing it**, and this reverses what was first
proposed here. A `relates:` field written into each filing's frontmatter would
be a second copy of what the body says, and would drift from it the moment
either was edited. That is exactly what SM654 filed against the hand-kept
`unlocks` map, one day earlier. Making the same mistake in a new place while
holding the filing that describes it would have been hard to defend.

So `backlog.pl` computes it: 993 edges, after dropping self-references and
references to numbers that were never filed. `--json` publishes it.

An author who wants to assert a relationship the prose does not state may still
add `relates:` to the frontmatter, and it is unioned in. Nothing is required to.

# Two numbers, two documents

`SM076` names both `mcp-site-management` and `oauth`. `SM270` carries two takes
on the same permission fight. A hash keyed by SM number keeps one of each and
says nothing.

Keyed by path now, with both indexed and the collision reported on STDERR - so
a listing stays pipeable while the ambiguity is not something a reader has to
notice for themselves. An index that silently loses a document is worse than no
index, because a reader trusts it.

# What is deliberately not built

**`area:`.** Grouping needs a *closed* vocabulary - lint-enforced, the way
`status` already is - because open tags fragment rather than group. Inventing
that vocabulary and applying it to 544 filings by keyword guesswork produces an
index that is confidently wrong, which is worse than none.

The 35 open filings are a set small enough to judge by hand, and the shape
should come from them rather than from a blank page. Terminal filings can
acquire it on touch, or never.

# Using it

    perl tools/backlog.pl          # the 35 open items
    perl tools/backlog.pl --all    # all 524 documents, both directories
    perl tools/backlog.pl --json   # the same, with the relation graph
