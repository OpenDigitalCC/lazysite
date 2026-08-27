---
title: "SM620: the practice briefing names the engine version twelve times, so every release rewrites it - including two notes whose whole claim is that they do not depend on a version"
subtitle: "Found while re-importing the briefing for 0.11.1, which SM597's early refusal had just demanded. The re-import is correct; its SIZE is the finding"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.2 (2026-08-26) on the operator's ruling, applying SM609's settlement to the generator. A version bump now rewrites THREE lines - the machine header the lint reads, the body hash that follows from it, and one prose stamp where a reader meets the version before acting on anything. It was twelve. THE FIELD-SCAR NOTE WAS WRONG, NOT MERELY REPETITIVE: it read 'It held before engine X and holds after it', a sentence whose entire claim is that the version does not matter, anchored to whichever version was last cut - so on 0.11.5 a reader was told a version-independent scar held before 0.11.5. True, uninformative, and quietly narrower than the author meant. It names no version at all now. The version-DATED notes still tell a reader to check which engine the site runs, and point at the stamp rather than copying it; the provenance section does the same. THE TEST RUNS THE GENERATOR AT TWO VERSIONS AND DIFFS, rather than counting occurrences in the checked-in file: what matters is not how many times a number appears today but how much a BUMP rewrites, and the only way to see that is to bump. It also names WHICH three lines move, so a change that swaps them for different three is visible rather than merely staying under the count, and asserts the checked-in briefing is byte-identical afterwards - the generator writes in place, and a test that left it stamped 9.8.7 would fail the next release rather than this one. Three sabotages, all fail. ORIGINAL FINDING BELOW. OBSERVED 2026-08-26 during the 0.11.1 cut. The briefing records the engine version it was generated for and t/lint/89 requires it to match the version being built, so every release needs a re-import - SM597 made that refusal arrive in a second instead of nine minutes, which is right, and did not reduce how often it fires. THE DIFF FOR 0.11.1 WAS TWELVE LINES with the SOURCES BYTE-IDENTICAL: AUTHORING-PRACTICE.md and APP-PRACTICE.md carried the same sha256 as the previous import, so every changed line was the same stamp, 0.11.0 -> 0.11.1, plus the body hash that follows from them. TWO OF THOSE LINES ARE WRONG IN A WAY THE OTHERS ARE NOT. They read `Version-independent - a field scar. It held before engine 0.11.0 and holds after it, on any site you connect to.` Re-importing rewrites them to say 0.11.1. A sentence whose entire claim is that it does NOT depend on a version is re-anchored to the current one on every release, so the assurance decays into a statement about whatever was last cut. A reader on 0.11.5 sees a version-independent scar asserting it held before 0.11.5 - true, uninformative, and quietly narrower than what the author meant. THE SAME SHAPE AS SM609, which the operator settled in FEATURES.md by keeping ONE version reference in the subtitle rather than tolerating two that could disagree. Applying that here cuts the diff from twelve lines to two and stops the version-independent notes naming a version at all: the version-DATED notes still need one, and should carry the single stamp from the header rather than repeating it inline. NOT FIXED DURING THE CUT deliberately - a generator change is not a thing to make while a release is blocked on the file it generates."
---

# What re-importing for 0.11.1 changed

| Lines | What |
|---|---|
| 2 | the header stamp: `engine-version`, `body-sha256` |
| 8 | version-DATED notes, correctly naming the build |
| **2** | **version-INDEPENDENT notes, naming the build anyway** |

Sources unchanged - both `sha256` values identical to the previous import.

# The sentence that argues with itself

> *Version-independent - a field scar. It held before engine **0.11.0** and holds
> after it, on any site you connect to.*

The claim is that the version does not matter. The sentence then names one, and
a re-import moves it. Nothing is false at any single moment; the guarantee just
gets quietly re-scoped to the newest release each time.
