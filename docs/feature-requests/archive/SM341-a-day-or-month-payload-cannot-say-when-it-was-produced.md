---
title: "SM341 - a day or month payload cannot say when it was produced"
subtitle: "The index carries `generated`. The single-day and single-month responses carry nothing, so a reader comparing one against an earlier copy has to rely on their own notes for when either was made."
brand: plain
status: shipped
status-note: "SHIPPED 2026-08-17 (ffb4204), with [[SM339]] and [[SM343]] as one change. The day and month payloads carry `generated`, so two rollups can be ordered from the artefacts rather than from the notes of whoever fetched them - which is the claim the partner agent could not make."
---

# What was found

`index.json` carries `generated`, an ISO timestamp. The single-day and
single-month responses carry no such field.

So an agent holding a day rollup from before an upgrade and one from after can
say what changed, but can only say *when* each was produced from its own notes.
The artefact is not self-evidencing.

# Why it is worth a line

The comparison it blocks is not exotic. It is what anyone does when a release
changes how a number is computed - which [[SM329]] just did, [[SM339]] proposes
doing deliberately, and [[SM340]] causes to happen accidentally on every call.

The partner agent hit it while staging exactly that capture, and was careful to
note that it does not weaken their matched pair: the day file is the invariant
half and byte-identity is the test. That is right. What it costs is the ability
to reconstruct the comparison later from the payloads alone, without the notes
of whoever ran it.

An artefact that records when it was made survives its author's context. One
that does not is only as good as the message that accompanied it.

# The case that made this concrete

Filed as an observation; a day later it cost a claim.

The partner agent holds a baseline payload for `2026-07-18` reading 848
pageviews, taken from the instrument before the upgrade. They initially said the
day file could not have been missing, because they hold it. Then corrected
themselves: what they hold is a **payload**, and under [[SM340]] every call
recomputed - so the payload proves the API returned data, not that a file
existed beforehand. If the file had been absent and the log retained, their own
baseline capture is exactly what would have created it.

They cannot distinguish *read it* from *made it* from outside. Nothing in the
response says which.

**The case was live rather than hypothetical**, and they established that too:
their event ring begins at 2026-07-22, so 07-18 is not in the 5,000-event
sample, and anything reconstructing that day would have had to come from
retained logs - which the index reaching back 34 days says exist for about that
age.

## What it costs, precisely

Not much, and the precision is the point. Byte-identity across the upgrade
stays valid however the file came to exist, because that test asks whether
0.10.12 rewrites it rather than where it came from.

What it costs is a different claim, now not made: that 848 is the figure the
engine recorded **on the day**. If the file was materialised by a later call it
is still basis 1 and still 848, but its provenance is the capture rather than
2026-07-18. It goes in their report as the pre-upgrade recorded value, not the
original one.

A `generated` field on the payload would have settled it outright. That is the
whole argument for this filing, arrived at by someone hitting the limitation
rather than by anyone anticipating it.

# What it is not

**Not a provenance mechanism.** `generated` on the index is a timestamp, not a
signature, and this would be the same. It answers "when was this produced",
which is the question actually being asked, and nothing about authenticity.

**Not a reason to touch these payloads on its own.** It should travel with the
next change that opens them - most plausibly [[SM339]], which rewrites day files
anyway and would want to record when it did. [[SM339]]'s stamp and this are the
same insertion point, and doing them together means a day file gains both the
basis it was counted under and the time it was written, which between them
answer every provenance question raised so far.

# Verification

- A single-day response says when it was produced.
- A single-month response does the same.
- The field matches the index's existing `generated` in name and format, so a
  reader does not have to learn two conventions.
- A day file already on disk is not rewritten merely to acquire one.

# Related

[[SM340]] (which makes cross-upgrade comparison routine rather than occasional),
[[SM339]] (the release that would naturally carry this), [[SM338]] (the
comparison that prompted it), and [[SM213]] (the durable store's shape).
