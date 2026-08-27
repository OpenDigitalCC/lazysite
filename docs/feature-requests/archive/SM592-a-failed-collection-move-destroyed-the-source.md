---
title: "SM592: a failed collection MOVE over WebDAV emptied the source and deleted the copy"
subtitle: "The client was told nothing had happened. The children were gone from the source, and the rollback had just removed the only complete copy."
brand: plain
standard-margins: true
status: shipped
status-note: "FOUND 2026-08-25 while writing SM582's coverage tests - the ones for a path nothing exercised - which is exactly what SM582 said it was for. SEQUENCE: on a cross-device MOVE, _move_bytes copies the tree, then removes the source; for a COLLECTION out of an unwritable parent, remove_tree deletes the CHILDREN and only then fails to unlink the now-empty directory, so the removal reports failure having already destroyed most of the source; the rollback then deleted the complete destination copy, because a failed MOVE must not leave an entry the caller never asked to create. Net effect: source emptied, copy gone, client answered 507 'nothing happened'. This is SM284's shape one turn worse - SM284 was told-it-moved-when-it-had-not; this is told-nothing-happened-when-the-content-was-destroyed. WHY NOTHING CAUGHT IT: t/integration/41 drives the FILE branch of the same failure but skip_all's as root, which the CI image is; the COLLECTION branch was never driven through a failure by anything at all. SHIPPED 0.10.33: the rollback restores the source FROM the destination copy BEFORE removing that copy, because at that instant the copy is the only whole thing on disk; the file case is unaffected (unlink either removes the entry or leaves it intact, and re-copying identical bytes is a no-op). t/unit/dav/25 drives a file and a collection MOVE out of a chmod-0555 parent and asserts 5xx, the source still present with its content intact, and no destination residue; each _remove_entry branch was sabotaged separately and both were caught. PRESENT IN SHIPPED RELEASES up to and including 0.10.32."
---

# The window, stated plainly

It needs a **cross-device** MOVE (the `rename` fast path must fail), of a
**collection**, out of a parent the CGI cannot write. On an ordinary
single-filesystem install the `rename` succeeds and none of this runs.
That is why it survived: rare, and invisible unless something makes the
removal fail on purpose.

# What it says about coverage

SM582 was filed as "an absence of evidence, not a defect". The absence
was hiding a defect, and only writing the test found it. A path nothing
exercises is not a path that works.
