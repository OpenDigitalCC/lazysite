---
title: "SM383: the release stage stamped one half of a pair"
subtitle: "SM375 taught release.sh to stamp VERSION and left NEXT_VERSION alone - so a stage cutting 0.10.15 carried both files saying 0.10.15, and the next release would have proposed a version already cut, which is never reused."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.10.15 (07879d3). RETROACTIVE FILING, written 2026-08-19 during the 0.10.16 post-release pass: this fix landed with a changelog entry and no feature-request doc, and t/lint/26 flagged the gap the moment the entry moved from Unreleased into its release section - which is the lint doing exactly its job, since a released item without a doc has no findable 'why'. The facts here are the commit's own, restated; nothing new is claimed. THE DEFECT: release.sh stamped VERSION in the staging clone and left NEXT_VERSION alone, in the very change (SM375) that existed because the pair had drifted - so the stage carried VERSION=0.10.15 AND NEXT_VERSION=0.10.15, and the next cut would have proposed a burned version (SM064: never reused). t/lint/63 caught it by failing the release gate, which is the gate working. Both halves now move together, as tools/bump-version.pl always did. TEST GOTCHA recorded in the commit: the test runs the real derivation line from a FILE rather than backticks, because it contains awk's $1/$2/$3 and Perl ate them as capture variables - producing an empty result indistinguishable from the shell failing."
---

# Why this filing exists after the fact

Every released item carries a feature-request doc so the "why" is findable
without an archaeology exercise. This one shipped with only its changelog
entry; the gap surfaced when the 0.10.16 post-release pass moved the entry into
the 0.10.15 section it belongs to and t/lint/26 refused. The status-note above
carries the complete record; the source of truth is commit 07879d3 and the
0.10.15 changelog section.

# The one-sentence lesson

A fix for drift that edits one half of a pair is the drift, one release later.
The pair (`VERSION`, `NEXT_VERSION`) moves together everywhere it moves at all.
