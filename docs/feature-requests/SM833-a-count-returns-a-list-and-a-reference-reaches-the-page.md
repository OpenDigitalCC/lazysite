---
title: "SM833: db count returns a one-element list, and a Perl reference reaches the visitor"
subtitle: "Sites agent, 1311E-01, 2026-09-10: [% total %] prints ARRAY(0x564e492aa2d8) onto a public page, where the shipped documentation promises 'a number, not a list'"
brand: plain
standard-margins: true
status: partial
status-note: "PARTIAL 2026-09-10: THE REPORTED DEFECT IS CLOSED. Every failure path in resolve_db returned [], whatever shape the binding asked for, so a refused `.count` or `.field` reached the page as a Perl reference and rendered ARRAY(0x...) with a heap address in it. _db_empty now answers in the binding's own shape - '' for a scalar accessor, an empty list for a list binding, so a page's FOREACH is unaffected. The empty scalar is '' rather than 0 because a refused read is not zero rows: the table may hold thousands this visitor may not count, and 0 would state a number the engine never established. THE HAPPY PATH NEEDED NOTHING - resolve_db has answered .count with a value since SM511, and reading the code first pointed the wrong way; reproducing it found the real shape in one run. WHAT REMAINS: the wider guard this filing also proposed, that a value reaching the template layer as a reference is a defect the renderer could catch rather than pass through. That would cover the next member of this class rather than this one, it touches the render engines, and it is not built."
---

# The disagreement

`starter/docs/data-tables.md` line 124 documents:

> `db:tasks.count(done=false)` | a number, not a list

What arrives is a one-element list. So a page written from the shipped
documentation:

```
total: db:products.count()
...
[% total %]
```

renders `ARRAY(0x564e492aa2d8)` to whoever loads the page. `[% total.0 %]` is
the number.

# Two things wrong, and the order matters

1. **A raw Perl reference reaches a visitor.** That is the part to fix
   regardless of which side of the disagreement wins. It is ugly, it is
   confusing to a reader, and it publishes a heap address - not a serious
   disclosure on its own, and not a thing a page should ever emit either.
2. **The documentation and the accessor disagree.** The doc is the contract an
   author reads; it says number. The accessor says list.

# The shape

**Make `count()` return the number**, matching the shipped documentation, since
that is what every author following the docs has already written and what the
name means. The list form is an artefact of the resolver returning rows
uniformly.

The compatibility question is narrow and answerable: `[% total.0 %]` is what a
site that hit this would have written as a workaround. Making `count()` scalar
breaks `.0`. Worth checking whether any shipped example or site uses `.0` before
changing it - and if one does, the fix is still right and the note belongs in
the release entry.

Separately, and cheaply: **a scalar that is a reference should not render as
one**. Whatever the resolution, a value reaching the template layer as a
reference is a defect the renderer can catch rather than pass through.

# How it was found

A non-public table renders empty to a visitor - correctly, an anonymous fetch
got `rows.size = 0` where the signed-in fetch got 3. That correct behaviour is
what made the first probe look broken, and following it through is what surfaced
the count. Recorded because the same shape will confuse the next person.

# Related

[[SM786]] (db values escaped at the sink - the same path, and the same question
of what a db value is allowed to become on the way to a page).
