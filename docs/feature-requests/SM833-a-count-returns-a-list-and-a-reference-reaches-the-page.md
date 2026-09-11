---
title: "SM833: db count returns a one-element list, and a Perl reference reaches the visitor"
subtitle: "Sites agent, 1311E-01, 2026-09-10: [% total %] prints ARRAY(0x564e492aa2d8) onto a public page, where the shipped documentation promises 'a number, not a list'"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-11. The reported defect was closed 2026-09-10: every failure path in resolve_db now answers in the binding's own shape, so a refused .count is '' rather than a list reference. The wider guard the filing proposed is built too: _strip_leaked_refs removes a stringified Perl reference - ARRAY(0x...), HASH(0x...), a blessed Class=HASH(0x...) - from every page the processor renders from .md or .url, before the page is cached, and logs the removal naming the source. A reference is recognised by its live heap address, which no author typed: a token that also appears in the page's own source is left as written, so a page about this very bug still shows it. Built as one net at the point every page passes rather than inside each render engine, which the note had flagged as the cost. Pinned by t/unit/processor/78, each rule seen to fail against its sabotage."
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
