---
id: SM826
title: "SM826: OKF export, held until the format settles"
subtitle: "The knowledge-standards recommendation proposed a thin Open Knowledge Format export as its third item. The release manager has held it: the format is immature and not yet worth implementing, and this may change. Recorded rather than declined, because a held item with a stated reason can be revisited and a declined one gets re-proposed from scratch."
brand: plain
standard-margins: true
status: parked
raised: 2026-09-10
raised-by: release manager, from the knowledge-standards survey
area: discoverability
status-note: "HELD 2026-09-10 by the release manager: the format is immature and not yet worth implementation, although that may change at some future point. Not declined - the reasoning is recorded so a later review starts from here rather than re-surveying. The trigger for revisiting is adoption: OKF acquiring consumers that a lazysite site would actually be read by. Nothing in the engine needs to change to keep this option open, which is the point of holding rather than building."
---

# What was proposed

An export surface - a registry template or a `tools/` script - emitting a site
section as an Open Knowledge Format bundle: the markdown largely as-is, front
matter normalised at the export boundary to OKF's queryable fields (type, title,
description, resource, tags, timestamp), links intact, an `index.md` per
directory. The recommendation called it small and thin, and identified the
table-descriptor concepts as the showpiece half.

# Why it is held

**The format is immature and has no consumers a lazysite site would be read by.**
An export exists to be consumed; building one for a specification nothing yet
reads is work whose value is entirely deferred, and the deferral is not the
engine's to carry.

This is the same judgement the recommendation itself applies to EntityMap -
"watch, do not implement - community spec, unproven adoption; revisit only if it
gains consumers" - and it applies with the same force here. The recommendation
put OKF in a different bucket; the release manager has put it in this one.

# What would change the answer

Adoption. If OKF acquires consumers - readers that a site owner would actually
want their content reachable by - the case becomes the one the recommendation
made, and the design it sketched is still the right shape. Nothing needs to be
built now to keep that option open, which is why holding costs nothing.

The **import** follow-on the recommendation mentions, and the
`/docs/integrations/okf` document that would accompany it, are held with it.

# Provenance

`inbox/knowledge-standards.md`, Recommendation 2, held by the release manager
2026-09-10 with the reason recorded above.
