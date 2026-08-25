---
title: "SM559: the walker returns its failures"
subtitle: "An unreadable layout directory is reported as unreadable site content under a layout-relative path, and the shared failure list is never drained between calls."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): @COPY_FAILED is gone - both walkers return their failures and the caller labels them. package_create keeps `unreadable` (content, site-relative) and manifest.unreadable_omitted exactly as SM484 shipped them and adds `unreadable_layout` (lazysite/layouts/<layout>/...) with manifest.layout_unreadable_omitted, a count; package_apply reports `copy_failed` (content/..., layout/...) and logs a WARN. t/unit/manager/110: an unreadable layout dir is reported as layout with the content count 0, an apply that cannot write names the file by tree, and the next create in the same process is clean. FOUND 2026-08-25 by the backups structural review, PROVEN by probe tmp/bp-probe-copy-failed-layout.t; class: correctness; recommended timing: later. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. @COPY_FAILED (SitePackage.pm 41) is one file-scoped list fed by every _copy_tree, and package_create copies the layout through it (240). The probe chmod 000 a theme assets dir and the result reported unreadable => themes/blue/assets/ - a layout-relative path with no layout prefix - with manifest.unreadable_omitted set. Code-visible corollary the report did not probe: package_apply copies through the same list (634, 728, 737) and never drains it, so under a persistent worker its failures surface in the next package_create result. Fix shape from the report: the walker returns its failures and the caller labels them."
---

# The finding

`Manager/SitePackage.pm 41` declares `@COPY_FAILED` as one file-scoped
list fed by every `_copy_tree`, and `package_create` copies the layout
through it (`SitePackage.pm 240`). The probe made a theme assets
directory unreadable with `chmod 000`: the result reported
`unreadable => ['themes/blue/assets/']` - a layout-relative path with no
layout prefix - and `manifest.unreadable_omitted => 1`, as though site
content had been omitted.

A code-visible corollary the report did not probe: `package_apply`
copies through the same list (`SitePackage.pm 634, 728, 737`) and never
drains it (354-355), so under a persistent worker its failures surface in
the next `package_create`'s result.

# Why it matters

Correctness: the report a package carries about what it omitted names
the wrong thing, and under a long-lived process it can name failures from
an earlier, unrelated call.

# The proving test

`bp-probe-copy-failed-layout.t` as a test: the walker returns its
failures, the caller labels them.

# Fix shape

The walker returns its failures; the caller labels them with the tree
they came from.
