---
title: "SM597: the practice lint fails unrelated gates when an external file moves"
subtitle: "t/lint/89 compares the served briefing against sources the site agent edits continuously, on this host, outside the repository. Any branch's gate fails when they move."
brand: plain
standard-margins: true
status: candidate
status-note: "SHARPER DIAGNOSIS 2026-08-25, and it CORRECTS what is written below. The filing blames the coupling to the site agent's external working files, which was true of the first two failures. The 0.10.34 BETA build failed the same lint with the sources UNCHANGED: the served copy records `engine-version:` and the lint asserts it equals the version being built, so the version bump alone invalidates it. Content identical, twelve lines differing, all of them the stamp and the checksum derived from it. THAT MEANS THIS LINT FAILS ON EVERY RELEASE, forever, and the fix is always the same command producing a diff with no content in it - which is precisely the rubber-stamping pressure this filing was raised about, now arriving on a schedule rather than by chance. Re-importing IS the intended workflow (the doc ships stamped for the release it ships in), so the defect is not that a re-import is needed; it is that the need is discovered nine minutes into a release build rather than before one starts. THE FIX IS THEREFORE SMALLER THAN A GATE REDESIGN: the release script should re-import before it gates, or bump-version should, so the stamp is right by construction and the lint keeps its full strength. Recorded before the beta cut; done after it, because a change to the release script during a release is the one thing worse than the problem. OBSERVED 2026-08-25 while landing 0.10.33, twice within two hours. t/lint/89 makes two different assertions. The first is SELF-CONTAINED - the served copy matches the body checksum recorded in its own import marker - and belongs in a gate. The second compares /srv/projects/lazysite-sites/AUTHORING-PRACTICE.md and /srv/projects/lazysite-apps/APP-PRACTICE.md against the checksums recorded at import time, and those files are the site agent's working files, edited continuously while other work is in flight. It already skips gracefully where the sources are absent (a fresh clone, CI, a release tarball), so the coupling bites exactly one machine: this one, where every branch is gated. TWICE NOW a branch with nothing to do with the practice docs has failed its gate for this reason - the SM595 deploy work and the SM589/SM590/SM596 surface work - each costing a full five-minute gate re-run. THE SHARPER COST IS NOT THE TIME. A failure that is routine and always cleared the same way (re-run the importer) trains whoever clears it to stop reading the diff, and that diff is externally-authored content going into a document shipped to every site. It was reviewed both times here - three sections one time, seven the other, scanned for CDN references, credentials, addresses and IP literals - but the pressure of a mechanical fix is toward rubber-stamping, which is the failure mode that matters. NOT FIXED IN 0.10.33, deliberately: the fix is a redesign of what a gate asserts (the freshness question moving to release preparation, where the decision to ship is actually made), and doing that on my own judgement during a feature freeze, immediately before a cut, is the wrong time. Recorded so the decision is the operator's and is made when a gate change is cheap. RELATED: SM574 built the lint and is right that a stale copy must not ship - this is about WHERE that is enforced, not whether."
---

# The two questions the lint asks

| Assertion | Depends on | Belongs in |
|---|---|---|
| the served copy matches its own recorded body checksum | nothing outside the tree | a gate |
| the sources are unchanged since the import | two files this host's site agent edits continuously | release preparation |

The second is a real question - a release should not ship a briefing its
author has already corrected. It is not a question about the branch under
test, which is what a gate answers.

# Why it is not simply downgraded to a note

The staging tree a release builds from is a fresh checkout on this same
host, so the sources are readable there too and the check would still
run. Moving the question to release preparation means putting it
somewhere `tools/release.sh` actually enforces it, not merely removing
the assertion from the lint - otherwise a stale copy ships silently,
which is the thing SM574 built this to prevent.
