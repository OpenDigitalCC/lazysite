---
title: "SM298 - A compliance document should carry the version it describes"
subtitle: "Every claim in a compliance record is a claim about a version. The records now declare one by hand, in a field a human edits, which is the arrangement that has failed every other time this project has relied on it."
brand: plain
status: shipped
status-note: "SHIPPED 2026-08-18, WITHOUT the pandoc-wrapper dependency the filing proposed, because the insight does not need it. A compliance record now carries a `content_sha` of its own body, so `reviewed_at_version` stops being a promise and becomes an observation: the gate can say whether the document actually CHANGED for this release. The version check catches a record nobody updated; the hash catches a record whose version was bumped without anybody re-reading it - the same failure one level down, and the shape this project has found six times. It ADVISES rather than blocks, because a register can legitimately be unchanged and the reviewer is the one who decides; what it removes is the ability to claim a re-read that did not happen without the claim being visible. The hash covers the body BELOW the front matter and excludes the stamped fields INCLUDING content_sha itself - the first version hashed its own field, so stamping a value changed the value, and it reported "content changed" on a document whose only change was the stamp. Demonstrated by bumping covers_version without touching the document: the gate now says the version field moved and the document did not. FILED 2026-08-14 out of the eight-dimension review follow-up. Nothing started. Recorded rather than left as a remark in a session, because 'worth doing properly later' is how something never gets done. The dependency is external: pandoc-wrapper RECOMMENDATIONS.md item 3 (document versioning) is unimplemented, and this filing is the consumer that would justify it."
---

# SM298 - the version field is still hand-maintained

## Where this comes from

The 2026-08-14 eight-dimension review's central finding was that everything
defended by a mechanism had held and every hand-maintained record had rotted.
The response was `tools/lazysite-compliance.pl`, which refuses a release when a
compliance record is behind the version being cut.

It works by reading a field a human wrote:

```yaml
reviewed_at_version: 0.10.8   # docs/compliance/OBLIGATIONS.md
covers_version:      0.10.8   # docs/compliance/TECHNICAL-FILE.md
```

So the gate catches a record nobody *updated*. It cannot catch a record whose
version field was bumped without anybody re-reading the document - which is the
same failure one level down, and precisely the shape this project has now found
five times.

## What would close it

`pandoc-wrapper`'s `RECOMMENDATIONS.md` item 3 proposes document versioning: a
registry keyed by document identity, hashing the document sources, bumping a
version component and stamping a date when the content changes, and injecting
the result as `--metadata revision=...` for the template to consume - never
written back into the source.

That is exactly the missing half. With it:

- a compliance document's version becomes a function of its **content**, not of
  someone's diligence;
- `reviewed_at_version` stops being a promise and becomes an observation - the
  document either changed for this release or it did not, and the gate can say
  which;
- the same mechanism serves the rendered PDF, so a signed Declaration of
  Conformity carries a revision that identifies exactly the bytes signed. For a
  document whose entire purpose is to be signed, that is not a nicety.

## Why it is filed rather than done

The mechanism belongs in the document pipeline, not here. Implementing it inside
lazysite would produce a second, private notion of document version that the
pipeline knows nothing about - which is the duplication this project keeps
converting into derived data, not creating.

So the sequence is: pandoc-wrapper implements RECOMMENDATIONS item 3, then
lazysite's compliance gate reads the injected revision instead of a hand-written
field.

## Care needed

- **The gate must keep working meanwhile.** The hand-written field is weaker
  than a derived one and much stronger than nothing; it does not come out until
  the replacement is in place.
- **Content hashing must ignore the injected revision**, or every render changes
  the hash that produced it.
- **A signed document's revision must be immutable.** A Declaration of Conformity
  that silently re-versions after signature is worse than one with no version at
  all.

## Related

[[SM283]] (the review that produced the gate), `tools/lazysite-compliance.pl`,
`docs/compliance/OBLIGATIONS.md`, `docs/compliance/TECHNICAL-FILE.md`, and
`/srv/projects/pandoc/pandoc-wrapper/RECOMMENDATIONS.md` item 3.
