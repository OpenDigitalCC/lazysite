---
id: SM1210
title: "SM1210: a test never writes the tracked VERSION"
subtitle: "t/tools/52 wrote 99.0.0 into the checkout's VERSION for the length of its run, so every test that reads VERSION could see it under prove -j. It now works on a scratch tree, and a lint fails any test that writes VERSION, NEXT_VERSION, CHANGELOG.md or MANIFEST of the checkout."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "SM1208 (the nightly's t/tools/29 failure), which locked one reader and left the cause"
area: tests
status-note: "SHIPPED (0.15.15) on n698: t/tools/52 runs the compliance tool in a copied scratch tree; the checkout is never written. New t/lint/270 fails any test writing a tracked VERSION/CHANGELOG.md/MANIFEST; it fails on the old 52."
---

# What happened

SM1208 found t/tools/29 failing because t/tools/52 held VERSION at 99.0.0. It made
29 take the preserve lock 52 takes. Every other test that reads VERSION without
that lock had the same window: t/lint/210, t/lint/63, t/tools/28, and anything
that builds a manifest or tarball from the live tree.

# Cause

t/tools/52 (line 67) wrote 99.0.0 to the tracked VERSION, and edited
docs/compliance/SIGNOFF.md, in the shared checkout. preserve_tracked puts a file
back and serialises tests that ask for it. A reader that does not ask is not
serialised, and a lock added to one reader leaves the next.

# Change

lazysite-compliance.pl takes its root from its own location. t/tools/52 now copies
the tool and the dozen files it reads into a scratch tree (TestHelper::site_tempdir)
and writes VERSION and SIGNOFF.md there. The checkout is not touched.

t/lint/270 scans every .t file and fails one that opens, writes, removes, moves or
copies onto VERSION, NEXT_VERSION, CHANGELOG.md or MANIFEST of the repo root,
directly or through a variable holding the path. preserve_tracked is not an
excuse for those four. The lint checks that it still finds the old 52's shape.

VERSION had one writer, t/tools/52. t/tools/29's lock (SM1208) and t/tools/190
remain: the lock is harmless and 190 still holds 29 to it.
