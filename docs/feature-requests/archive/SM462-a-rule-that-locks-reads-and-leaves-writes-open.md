---
title: "SM462: a rule that locks reads and leaves writes open, and said nothing"
subtitle: "An empty write list means NO restriction. So the ordinary way of restricting a folder produced a rule that refused readers and admitted every writer - and the interface showed rw while the stored rule was read-only."
brand: plain
standard-margins: true
status: shipped
status-note: "FILED AND SHIPPED 2026-08-21 from the field. THE ASYMMETRY: an ACL entry with a read list restricts reading to that list, but an entry whose write list is EMPTY does not restrict writing at all - the shared predicate returns allowed unless the list is a non-empty array. Both readings are defensible in isolation and together they are a trap: the operator names the people who may read, and thereby names nobody who may write, which the store reads as everybody. TWO PARTS SHIPPED. First, the interface now SAYS SO: adding a principal grants read AND write, because too few people able to write is a nuisance and too many is the thing the feature exists to prevent, and a rule that locks reads while leaving writes open now warns in the manager where it is set. The per-chip toggles are untouched, so narrowing it back is one visible click. This changes what a click MEANS, not what a rule means - enforcement and every stored rule are unaffected. Second, Protected sections is scoped to the folder being viewed while still showing the rules that COVER it, so a rule inherited from an ancestor is visible where it applies rather than only where it was written. A WARNING THAT CRIES WOLF IS WORSE THAN NONE: it fires on a named GROUP only, because t/unit/manager/73 caught an earlier version firing on any named account - the second time that test has caught a warning change of mine, and the reason the fire condition is now asserted rather than described."
---

# The two readings

```datatable
columns: List | Empty means | Non-empty means
widths: 3cm | 5cm | X
bold: 1
tone: medium
---
`read` | no restriction | only these may read
`write` | **no restriction** | only these may write
```

Each row is defensible on its own. Together they mean that the ordinary act
of restricting a folder -- naming who may read it -- produces a rule that
admits every writer, and the operator is shown *rw* while the stored rule
says read-only.

# Why the fix is in the interface, not the predicate

Changing what an empty list means would change every stored rule on every
site at once, silently, in the direction of *more* restriction. Some of those
rules are load-bearing. The defect is that the interface did not say what it
was storing, so that is what was repaired: the default grants both, the
asymmetric case warns where it is set, and the rules that govern a folder are
visible from that folder.
