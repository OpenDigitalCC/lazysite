---
title: "SM657: a brief can describe a page, and a data row - the object with no path, no descriptor and no comment field - has nowhere at all to record why"
subtitle: "Site agent, 2026-08-24: the prerequisite the brief insisted on has since shipped, so the sequencing it argued for is now available"
brand: plain
standard-margins: true
status: partial
status-note: "PARTIAL (PENDING). Parts 1 and 2a of three. Part 1 (2026-08-27) wrote down what already worked: a brief may describe any content object keyed by a path. PART 2a NOW SHIPS THE TYPED KEY for the object that had nowhere at all - `type=row`, `table=NAME`, `key=KEY` on brief-read and brief-append, in place of `path`. Typed entries live in the SAME store under a reserved `.typed/` prefix, deliberately: the filing's ordering condition was that briefs be listable and clearable BEFORE the key space widened, because rows are deleted constantly and each would otherwise leave an invisible orphan - keeping them in one tree means SM508's list and delete cover them the day they exist rather than being extended later. A typed entry is reported with its type and with orphan UNKNOWN rather than guessed, because the file test that decides orphanhood for a path would call every typed entry an orphan and invite an operator to clear briefs that are working. NOT DONE: `type=table` (part 2b - a table's intent already round-trips as descriptor comments, the weaker half by the filing's own reasoning), and part 3, whether a row brief follows its row through a key change - the same question the rename gap raises for pages. THE PRACTICE PAGE IS NOT UPDATED HERE: starter/docs/ai-briefing-practice.md is GENERATED from lazysite-sites/AUTHORING-PRACTICE.md, which is another tree's document. I edited the served copy, t/lint/89 caught it on the checksum, and it is reverted - the wording is filed to that tree's inbox for its owner to apply, because editing their source directly would have been the second mistake after editing a generated file."
---

# The one object with nowhere to put a why

| Object | Where its intent can live today |
|---|---|
| A page | a brief |
| A table | comments in its descriptor - verified to survive a round trip |
| A folder, asset, layout, theme, nav, site root | a brief, already - just undocumented |
| **A data row** | **nowhere** |

A row has no path, no descriptor and no comment field. On a data-driven site it
is the content object, and it is the only one in the list with no way to record
why it is as it is.

# Why the table half is the weaker half

Comments in a table descriptor round-trip verbatim. The agent tested it - two
`# WHY:` comments, one of them nested inside a field definition, both intact
through `data-table-source`.

So a table brief would gain dating and attribution and would be tidier, but the
underlying need is already met. Building it first would spend the work on the
half that has a workaround.

# The ordering, which was the brief's main argument

> Do not widen the key space until a brief can be listed and deleted.

The reasoning: pages are deleted occasionally; rows are deleted **constantly** -
every withdrawal, every import that supersedes a row, every correction.
Extending briefs to rows while orphans could not be listed or removed would
have produced one orphan per deleted row, invisible and unclearable.

**That prerequisite has shipped.** SM508 gave briefs a listing and a way to
clear an orphan. The condition the brief set has been met, which is why this
is now a proposal to schedule rather than one to hold.

# In order

1. **Write down what already works.** One line in the publishing briefing: a
   brief may describe a folder, an asset, a layout, a theme, the nav, or the
   site root - not only a page. Costs nothing and unlocks most of the request
   today.
2. **Add the typed key**, `type=row` first, `type=table` second - the two with
   no home, in the order of how badly they lack one.
3. **Decide whether a row brief follows its row through a key change**, which
   is the same question the rename gap raises for pages.

# Two smaller notes, recorded

The `type=` design would also give somewhere to hang a brief on things that
have no file and were never considered: a form handler, a redirect, an ACL
grant, a scheduled job.

`validate_path` refuses `/a/b/c.md` while accepting `/docs/deeper/never.md`.
That is worth a look on its own account, independent of briefs - it is a
confusing refusal for any caller creating a nested path.
