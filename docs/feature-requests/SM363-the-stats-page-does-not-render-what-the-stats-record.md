---
title: "SM363 - the Stats page does not render what the stats record"
subtitle: "Sessions, journeys, devices and search terms are all computed, stored per day, and carried in the payload the manager Stats page fetches. The page renders none of them. An operator who turns on the one setting that has a switch sees nothing happen."
brand: plain
status: candidate
status-note: "FILED 2026-08-17 while checking a claim I had just written. The CHANGELOG entry for SM336 items 6 and 7 said both fields reach the operator's Stats page; they reach its PAYLOAD. The page's own renderer has no sight of them, nor of the sessions and journeys shipped in the release before. Corrected the claim and filed this rather than leave a changelog asserting something a reader could check in one look."
---

# What is recorded, and what is shown

```datatable
columns: Field | Shipped | In the day rollup | In the page payload | Rendered
widths: 4.2cm | 2.2cm | X | X | 2.4cm
bold: 1
tone: medium
---
`sessions` | SM336 | yes | no | no
`journeys` (transitions, entry, exit, depth, dwell, landing, not_found_from) | SM336 | yes | no | no
`devices` | SM336 item 6 | yes | yes | no
`search_terms` | SM336 item 7 | yes | yes | no
---
```

The last column is the whole filing. Everything above it works.

# Why this matters more than a missing panel

**One of these has a switch.** `search_terms` is the only stats setting an
operator turns on deliberately, and it is off by default precisely because it is
the one carrying a privacy decision. So the sequence is: an operator reads a
setting, weighs it, decides to accept it, turns it on - and the page they turned
it on from shows them nothing.

The reasonable conclusion is that it does not work. The next reasonable step is
to turn it off again, or to report a defect that is not there. Neither is what
the setting was for.

**And it is the same shape as the defect class this project keeps finding**, from
the other end. A control that reports success without doing the work, and a
setting that does the work without reporting it, are both a gap between what the
system says and what it did.

# What it needs

Four blocks on `starter/manager/stats.md`, all reading fields the payload
already carries:

devices
: three counts. The smallest of the four and the one that answers a question a
  site owner asks unprompted.

sessions and depth
: a session count beside the pageview tile, and the depth histogram, which is
  what turns "60% bounced" into which page they bounced off.

journeys
: entry, exit and transitions. `exit` is the most actionable field a content
  owner can have: it names where the argument fails.

search terms
: top-N with counts. Absent from the payload when the switch is off, so the
  block should be absent from the page rather than empty - the page must not
  invite an operator to wonder whether nobody searched or nobody was asked.

## The thing to get right while doing it

**Search terms are attacker-controlled text.** They are whatever a visitor typed
into a query string, stored and then displayed to an operator - so they are the
first field on this page that a stranger chooses the content of.

`starter/manager/stats.md` already has `sesc()` and uses it for every key it
renders. The requirement is simply that the new block uses it too, and does not
follow `pageTable`'s pattern of also putting the key in an `href`: a search term
is not a URL and has no business in one.

# Prerequisites

None. The payload work landed with SM336 items 6 and 7 and this is presentation
only.

# Related

[[SM336]] (what is recorded, and why the search-term floor is a privacy property
rather than a reporting filter), [[SM335]] (the page and the export disagreeing
about a class - the same two-projection problem one level up, which is why both
payloads carry these fields), and `docs/manual-check-register.md`, where the
Stats chunk has never been walked.
