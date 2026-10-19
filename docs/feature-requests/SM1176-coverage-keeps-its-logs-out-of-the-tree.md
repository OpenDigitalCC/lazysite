---
id: SM1176
title: "SM1176: every file a coverage run writes at the tree root is classified"
subtitle: "Any cover_db-<name> file is excluded from the manifest, so the coverage run no longer refuses itself after its first group."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-18
raised-by: lazysite developer agent, from the 2026-10-18 overnight coverage run (n664)
area: release
status-note: "SHIPPED on n664: dist/config/classification.json, .gitignore; t/tools/181."
---

# What happened

In the 2026-10-18 coverage run group `manager` failed:

    build-manifest: REFUSING - 1 unclassified file(s):
      cover_db-processor-cover-stderr.txt

`t/integration/259` builds the release manifest. The earlier `processor` group
had left `cover_db-processor-cover-stderr.txt` at the tree root:
`tools/coverage.sh` keeps cover's stderr beside the suite log
(`COVER_ERR="${SUITE_LOG%-suite.*}-cover-stderr.txt"`). SM1116 classified the
suite log by name; this was the next name the same tools write.

# What shipped

- The class is excluded by one rule, `^cover_db-[^/]+$`: any file at the tree
  root whose name starts `cover_db-`, whatever the tools call it next. The
  folders (`cover_db/`, `cover_db-<group>/`) and suite logs keep their rules.
  `.gitignore` gains the two stderr names.
- The files stay at the root (the exclude, not a move): the run's closing
  message tells the operator where cover's stderr was kept, and that path is
  the one people open. Nothing else reads them elsewhere.
- t/tools/181 builds every name as the tools do (whole suite and each group, log
  and stderr file, DB folders) in a scratch tree and runs the real
  `build-manifest.pl --staged` over it: it must accept all and still refuse an
  unrelated file. It also checks that the two scripts build no path under
  `$ROOT` outside cover_db-named paths, `tools/`, `dist/` and the lock. It
  fails on the classification before this change.

# Not done

The coverage run itself is not repeated by this change (it takes hours on the
shared host).
