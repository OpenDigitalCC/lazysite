---
title: "SM609: the compliance check read FEATURES.md's version list and not the two places the document dates itself"
subtitle: "Subtitle said v0.9.14, closing note said v0.10.19, timeline reached 0.10.34 - and the check reported the file current throughout."
brand: plain
standard-margins: true
status: shipped
status-note: "FOUND BY THE OPERATOR 2026-08-26, reading the file rather than the check. FEATURES.md dates itself in three places: the timeline of releases, a subtitle ('as of v0.9.14') and a closing note ('current to v0.10.19', with a sentence describing that release's content). The compliance check cross-references the TIMELINE against the CHANGELOG's release headings and nothing else, so when the 0.11.0 prep brought the timeline from 0.10.19 to 0.10.34 the check said 'FEATURES.md current' while two stamps in the same document were fifteen and twenty-five versions behind. I WROTE THE TIMELINE ENTRIES AND DID NOT READ THE REST OF THE FILE, which is the actual failure - the check told me the file was current and I believed the check about a document I had just edited. THE PATTERN, and it is the fifth instance in this release: a check that examines one part of a thing reports on the whole thing, and the unexamined part is the one that rots. Here the maintained part was the part the check could see, which is the mechanism by which such a check keeps passing. FIXED both ways: the stamps say v0.11.0 and describe the stable line, and the check now reads any 'as of vX' or 'current to vX' in the file and warns when one is behind the version being cut. Advisory, like its neighbour - a stale stamp misleads a reader and blocks nothing. Sabotage-verified: restoring the v0.9.14 subtitle produces 'FEATURES.md still says it is current to v0.9.14, cutting 0.11.0'. WHAT IT STILL CANNOT SEE: the closing note also carries a SENTENCE describing the release it is current to, and no check can tell whether that prose still describes the right release. It was rewritten by hand for 0.11.0."
---

# Three dates, one document

| Where | Said | Timeline reached |
|---|---|---|
| Subtitle | v0.9.14 | 0.10.34 |
| Closing note | v0.10.19 | 0.10.34 |
| The check's verdict | **"FEATURES.md current"** | |

# Why the check could not see it

It cross-references the timeline's versions against the CHANGELOG's release
headings. That is a good rule for the timeline and says nothing about the
prose around it - so the one part of the document somebody had maintained
was the one part the check was reading.
