---
id: SM1116
title: "SM1116: everything a coverage run writes into the tree is classified"
subtitle: "A group's suite log, cover_db-<group>-suite.log, is excluded from the manifest, so the coverage run no longer refuses itself."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: lazysite developer agent, from the 2026-10-17 overnight coverage run
area: release
status-note: "SHIPPED on n619: dist/config/classification.json, .gitignore; t/tools/169."
---

# What happened

The release manager asked for a full coverage run overnight (2026-10-16). It
ran at 01:30 and measured no group:

    build-manifest: REFUSING - 1 unclassified file(s):
      cover_db-processor-suite.log
    coverage: group processor: FAILED (coverage.sh exit 3)
    coverage: GROUPS: 0 measured, 0 reused, 0 nothing gated; STOPPED at processor after 6101s

`t/integration/259` builds the release manifest, and the manifest refuses an
unclassified file. The per-group runner (`tools/coverage-parts.sh`) writes its
suite log at the tree root as `cover_db-<group>-suite.log`. The exclude list
knew `cover_db/`, `cover_db-<x>/` and the whole-suite `cover_db-suite.log`,
but not a group's log. So the coverage run wrote a file that made its own
suite fail. n594 (0.15.5) was the same defect for the group's DB folder.

# What shipped

- The exclude rule is `^cover_db(?:-[^/]+)?-suite\.log$`: the whole-suite log
  and every group's. `.gitignore` gains `cover_db-*-suite.log`.
- t/tools/169 reads the names from the tools that write them, lists the
  groups from the area map, and checks that each group's suite log and DB, and
  the whole-suite log and DB, match an exclude rule, and that no rule reaches
  engine files. A new name the tools start writing fails here in seconds,
  instead of two hours into a night run. It fails on the classification
  before this change.

# Not done

The overnight run is not repeated by this change. Coverage runs for a stable
cut or on demand (SM1083).
