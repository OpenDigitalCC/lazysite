---
id: SM1246
title: "SM1246: a test child is run through run_child"
subtitle: "SM1245 moved 381 hand-rolled open2/open3 blocks in 232 files under t/ onto TestHelper::run_child. New t/lint/273 fails a test file that calls open2 or open3 itself, unless a comment says the test drives the child itself."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: "SM1245 (task #370: t/unit/dav/33 hung 95 minutes in the 2026-10-20 14:30 suite run)"
area: tests
status-note: "SHIPPED (0.16.1) on n726: t/lint/273 scans t/ (TestHelper.pm and t/vendor/ apart) and fails an undeclared open2/open3; it proves it still finds run_dav's old block. It fails on the tree before SM1245."
---

# What happened

t/unit/dav/33 hung in TestHelper::run_dav (SM1245). The block that hung was not
unusual: 232 files under t/ had their own copy of it, 381 in all. Fixing the
helper and leaving the copies, or fixing the copies and leaving nothing to stop
the next one, would leave the class in place.

# Cause

TestHelper's own helpers had the same block, so there was nothing better to copy,
and nothing refused a new copy.

# Change

t/lint/273 reads every .t, .pm and .pl file under t/ except t/lib/TestHelper.pm,
which holds run_child, and t/vendor/, which is vendored. It fails a line that calls
open2 or open3. The exception is a spawn with a comment within the six lines before
it saying the test drives the child itself, meaning it signals the child or reads
it while it runs and so needs the pid. Those tests bound themselves with
feed_child and reap_child: today, t/unit/dav/33's SIGTERM case and t/tools/200's
dev server.

The lint runs on run_dav's old block, an open2, a declared spawn, a comment and a
run_child call, to show it finds the first two and only those. On the tree before
SM1245 it fails on 381 sites in 232 files.
